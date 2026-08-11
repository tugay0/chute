// Package cli implements chute's command-line surface: push, pull, watch,
// config, targets, and doctor.
package cli

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/tugay0/chute/internal/clip"
	"github.com/tugay0/chute/internal/config"
	"github.com/tugay0/chute/internal/term"
	"github.com/tugay0/chute/internal/transfer"
)

// Version is overridden at build time via -ldflags "-X ...cli.Version=...".
var Version = "0.1.0"

// Run dispatches a command and returns the process exit code.
func Run(args []string) int {
	if len(args) == 0 {
		usage()
		return 0
	}
	switch args[0] {
	case "init", "setup":
		return cmdInit(args[1:])
	case "push", "up":
		return cmdPush(args[1:])
	case "pull", "down":
		return cmdPull(args[1:])
	case "watch":
		return cmdWatch(args[1:])
	case "config":
		return cmdConfig(args[1:])
	case "targets", "target":
		return cmdTargets(args[1:])
	case "doctor":
		return cmdDoctor(args[1:])
	case "version", "--version", "-v":
		fmt.Println("chute " + Version)
		return 0
	case "help", "--help", "-h":
		usage()
		return 0
	default:
		term.Err("unknown command %q — run %s", args[0], term.Bold("chute help"))
		return 2
	}
}

// ---- init ----------------------------------------------------------------

func cmdInit(args []string) int {
	// Non-interactive: `chute init <name> <host> <folder>` behaves like add.
	if len(args) == 3 {
		return targetsAdd(args)
	}
	if len(args) != 0 {
		term.Err("usage: %s   (interactive)   |   %s", term.Bold("chute init"), term.Bold("chute init <name> <host> <folder>"))
		return 2
	}

	in := bufio.NewScanner(os.Stdin)
	ask := func(prompt, def string) string {
		if def != "" {
			fmt.Fprintf(os.Stderr, "%s %s: ", prompt, term.Dim("["+def+"]"))
		} else {
			fmt.Fprintf(os.Stderr, "%s: ", prompt)
		}
		if !in.Scan() {
			return def
		}
		if v := strings.TrimSpace(in.Text()); v != "" {
			return v
		}
		return def
	}

	fmt.Fprintln(os.Stderr, term.Bold("chute init")+" — point Chute at your VPS.")
	fmt.Fprintln(os.Stderr, term.Dim("  The host is an ~/.ssh/config alias or user@host; SSH to it should already work."))
	host := ask("SSH host (e.g. user@1.2.3.4 or an ssh alias)", "")
	if host == "" {
		term.Err("a host is required")
		return 2
	}
	folder := config.NormalizeFolder(ask("Remote folder", "~/inbox/"))
	name := ask("Name for this target", "box")

	t := config.Target{Name: name, Host: host, Folder: folder}
	if err := config.ValidateTarget(t); err != nil {
		term.Err("%v", err)
		return 1
	}
	cfg, code := load()
	if cfg == nil {
		return code
	}
	if existing, ok := cfg.Find(name); ok {
		existing.Host, existing.Folder = host, folder
	} else {
		cfg.Targets = append(cfg.Targets, t)
	}
	cfg.Active = name
	if err := cfg.Save(); err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Ok("saved %s → %s (active)", term.Bold(name), t.Dest())

	fmt.Fprint(os.Stderr, term.Cyan("→")+" testing connection… ")
	if reachable(t) {
		fmt.Fprintln(os.Stderr, term.Green("reachable ✓"))
	} else {
		fmt.Fprintln(os.Stderr, term.Yellow("couldn't connect"))
		term.Warn("make sure `ssh %s` works (accept the host key once), then run `chute doctor`", host)
	}
	fmt.Fprintln(os.Stderr, term.Dim("next: ")+term.Bold("chute push somefile"))
	return 0
}

// ---- push ----------------------------------------------------------------

func cmdPush(args []string) int {
	fs := flag.NewFlagSet("push", flag.ContinueOnError)
	to := fs.String("to", "", "target name (defaults to the active target)")
	dry := fs.Bool("dry-run", false, "show what would transfer without sending")
	noCopy := fs.Bool("no-copy", false, "don't copy the remote path to the clipboard")
	fs.Usage = func() { fmt.Fprint(os.Stderr, pushHelp) }
	paths, err := parseFlags(fs, args)
	if err != nil {
		return errCode(err)
	}
	if len(paths) == 0 {
		term.Err("nothing to push — usage: %s", term.Bold("chute push <file|dir>... [--to name]"))
		return 2
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			term.Err("no such file or directory: %s", p)
			return 1
		}
	}
	cfg, code := load()
	if cfg == nil {
		return code
	}
	t, err := resolve(cfg, *to)
	if err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Info("pushing %d item(s) → %s", len(paths), term.Bold(t.Dest()))
	remote, err := transfer.Push(t, paths, *dry)
	if err != nil {
		term.Err("push failed: %v", err)
		return 1
	}
	if *dry {
		term.Ok("dry run complete — nothing was sent")
		return 0
	}
	joined := strings.Join(remote, "\n")
	if *noCopy {
		term.Ok("sent:")
	} else if err := clip.Copy(joined); err == nil {
		term.Ok("sent — remote path%s copied to clipboard:", plural(len(remote)))
	} else {
		term.Ok("sent:")
	}
	for _, r := range remote {
		fmt.Println("  " + r) // stdout: the paste-ready remote path(s)
	}
	return 0
}

// ---- pull ----------------------------------------------------------------

func cmdPull(args []string) int {
	fs := flag.NewFlagSet("pull", flag.ContinueOnError)
	from := fs.String("from", "", "target name (defaults to the active target)")
	dest := fs.String("dest", ".", "local directory to download into")
	fs.Usage = func() { fmt.Fprint(os.Stderr, pullHelp) }
	remotePaths, err := parseFlags(fs, args)
	if err != nil {
		return errCode(err)
	}
	if len(remotePaths) == 0 {
		term.Err("nothing to pull — usage: %s", term.Bold("chute pull <remote-path>... [--dest dir]"))
		return 2
	}
	cfg, code := load()
	if cfg == nil {
		return code
	}
	t, err := resolve(cfg, *from)
	if err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Info("pulling %d item(s) from %s → %s", len(remotePaths), term.Bold(t.Host), *dest)
	if err := transfer.Pull(t, remotePaths, *dest); err != nil {
		term.Err("pull failed: %v", err)
		return 1
	}
	term.Ok("downloaded into %s", *dest)
	return 0
}

// ---- watch ---------------------------------------------------------------

func cmdWatch(args []string) int {
	fs := flag.NewFlagSet("watch", flag.ContinueOnError)
	to := fs.String("to", "", "target name (defaults to the active target)")
	interval := fs.Duration("interval", 2*time.Second, "how often to check for changes")
	del := fs.Bool("delete", false, "propagate local deletions to the remote")
	fs.Usage = func() { fmt.Fprint(os.Stderr, watchHelp) }
	pos, err := parseFlags(fs, args)
	if err != nil {
		return errCode(err)
	}
	dir := "."
	if len(pos) > 0 {
		dir = pos[0]
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		term.Err("not a directory: %s", dir)
		return 1
	}
	cfg, code := load()
	if cfg == nil {
		return code
	}
	t, err := resolve(cfg, *to)
	if err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Info("watching %s → %s (every %s) — Ctrl-C to stop", term.Bold(dir), term.Bold(t.Dest()), *interval)
	if *del {
		term.Warn("--delete is on: files removed locally will be removed on the remote too")
	}
	if err := transfer.Watch(t, dir, *interval, *del); err != nil {
		term.Err("watch stopped: %v", err)
		return 1
	}
	return 0
}

// ---- config --------------------------------------------------------------

func cmdConfig(args []string) int {
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "", "show":
		cfg, code := load()
		if cfg == nil {
			return code
		}
		fmt.Println(term.Dim("config: ") + config.Path())
		if len(cfg.Targets) == 0 {
			term.Warn("no targets yet — run %s to point Chute at your VPS", term.Bold("chute init"))
			return 0
		}
		fmt.Println(term.Dim("active: ") + term.Bold(cfg.Active))
		fmt.Println()
		printTargets(cfg)
		return 0
	case "path":
		fmt.Println(config.Path())
		return 0
	case "edit":
		return editConfig()
	default:
		term.Err("unknown 'config' subcommand %q (try: show, path, edit)", sub)
		return 2
	}
}

func editConfig() int {
	cfg, code := load()
	if cfg == nil {
		return code
	}
	if _, err := os.Stat(config.Path()); os.IsNotExist(err) {
		if err := cfg.Save(); err != nil { // materialize the default so there's something to edit
			term.Err("could not create config: %v", err)
			return 1
		}
	}
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "vi"
	}
	cmd := exec.Command(editor, config.Path())
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		term.Err("editor exited: %v", err)
		return 1
	}
	if _, err := config.Load(); err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Ok("config saved")
	return 0
}

// ---- targets -------------------------------------------------------------

func cmdTargets(args []string) int {
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "", "list":
		cfg, code := load()
		if cfg == nil {
			return code
		}
		printTargets(cfg)
		return 0
	case "add":
		return targetsAdd(args[1:])
	case "use":
		return targetsUse(args[1:])
	case "rm", "remove":
		return targetsRemove(args[1:])
	default:
		term.Err("unknown 'targets' subcommand %q (try: list, add, use, rm)", sub)
		return 2
	}
}

func targetsAdd(args []string) int {
	if len(args) != 3 {
		term.Err("usage: %s", term.Bold("chute targets add <name> <host> <folder>"))
		return 2
	}
	name, host, folder := args[0], args[1], config.NormalizeFolder(args[2])
	if err := config.ValidateTarget(config.Target{Name: name, Host: host, Folder: folder}); err != nil {
		term.Err("%v", err)
		return 2
	}
	cfg, code := load()
	if cfg == nil {
		return code
	}
	if t, ok := cfg.Find(name); ok {
		t.Host, t.Folder = host, folder // overwrite in place
	} else {
		cfg.Targets = append(cfg.Targets, config.Target{Name: name, Host: host, Folder: folder})
	}
	cfg.Active = name // the target you just added is the one you want to use
	if err := cfg.Save(); err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Ok("target %s → %s (now active)", term.Bold(name), host+":"+folder)
	return 0
}

func targetsUse(args []string) int {
	if len(args) != 1 {
		term.Err("usage: %s", term.Bold("chute targets use <name>"))
		return 2
	}
	cfg, code := load()
	if cfg == nil {
		return code
	}
	if _, ok := cfg.Find(args[0]); !ok {
		term.Err("no such target: %s", args[0])
		return 1
	}
	cfg.Active = args[0]
	if err := cfg.Save(); err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Ok("active target is now %s", term.Bold(args[0]))
	return 0
}

func targetsRemove(args []string) int {
	if len(args) != 1 {
		term.Err("usage: %s", term.Bold("chute targets rm <name>"))
		return 2
	}
	cfg, code := load()
	if cfg == nil {
		return code
	}
	if _, ok := cfg.Find(args[0]); !ok {
		term.Err("no such target: %s", args[0])
		return 1
	}
	kept := cfg.Targets[:0]
	for _, t := range cfg.Targets {
		if t.Name != args[0] {
			kept = append(kept, t)
		}
	}
	cfg.Targets = kept
	if cfg.Active == args[0] {
		cfg.Active = ""
		if len(cfg.Targets) > 0 {
			cfg.Active = cfg.Targets[0].Name
		}
	}
	if err := cfg.Save(); err != nil {
		term.Err("%v", err)
		return 1
	}
	term.Ok("removed target %s", term.Bold(args[0]))
	return 0
}

// ---- doctor --------------------------------------------------------------

func cmdDoctor(args []string) int {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	to := fs.String("to", "", "target to test (defaults to the active target)")
	if _, err := parseFlags(fs, args); err != nil {
		return errCode(err)
	}
	ok := true
	check := func(label string, pass bool, detail string) {
		if pass {
			term.Ok("%s %s", label, term.Dim(detail))
		} else {
			term.Err("%s %s", label, detail)
			ok = false
		}
	}

	if p, err := exec.LookPath("ssh"); err == nil {
		check("ssh", true, p)
	} else {
		check("ssh", false, "not found in PATH")
	}
	if p, err := exec.LookPath("rsync"); err == nil {
		check("rsync", true, p+" "+rsyncVersion())
	} else {
		check("rsync", false, "not found in PATH — install with: brew install rsync")
	}
	check("clipboard", clip.Available(), "pbcopy") // check presence without clobbering the clipboard

	cfg, code := load()
	if cfg == nil {
		return code
	}
	t, err := cfg.Resolve(*to)
	if err != nil {
		term.Err("%v", err)
		return 1
	}
	fmt.Println()
	fmt.Println(term.Dim("target: ") + term.Bold(t.Name) + " → " + t.Dest())
	if verr := config.ValidateTarget(t); verr != nil {
		check("target", false, verr.Error()) // never probe an unsafe host/folder
	} else if reachable(t) {
		check("ssh "+t.Host, true, "reachable")
	} else {
		check("ssh "+t.Host, false, "could not connect (check ~/.ssh/config and that the host is up)")
	}

	if ok {
		return 0
	}
	return 1
}

func reachable(t config.Target) bool {
	argv := strings.Fields(sshCmdEnv())
	argv = append(argv, "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", t.Host, "true")
	cmd := exec.Command(argv[0], argv[1:]...)
	return cmd.Run() == nil
}

func sshCmdEnv() string {
	if v := os.Getenv("CHUTE_SSH"); v != "" {
		return v
	}
	return "ssh"
}

func rsyncVersion() string {
	out, err := exec.Command("rsync", "--version").Output()
	if err != nil {
		return ""
	}
	line := strings.SplitN(string(out), "\n", 2)[0]
	return strings.TrimSpace(line)
}

// ---- helpers -------------------------------------------------------------

// parseFlags parses fs while allowing flags and positional arguments to be
// interspersed — Go's flag package otherwise stops at the first positional, so
// "chute push file.png --to staging" would treat --to as a filename. Returns
// the positional arguments. A literal "--" ends flag parsing.
func parseFlags(fs *flag.FlagSet, args []string) ([]string, error) {
	var flags, positional []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}
		if len(a) > 1 && a[0] == '-' {
			flags = append(flags, a)
			// If it's a non-bool flag written as "--to value" (no '='), pull
			// the following token along as its value.
			if !strings.Contains(a, "=") {
				name := strings.TrimLeft(a, "-")
				if f := fs.Lookup(name); f != nil && !isBoolFlag(f) && i+1 < len(args) {
					i++
					flags = append(flags, args[i])
				}
			}
			continue
		}
		positional = append(positional, a)
	}
	if err := fs.Parse(flags); err != nil {
		return nil, err
	}
	return positional, nil
}

func isBoolFlag(f *flag.Flag) bool {
	bf, ok := f.Value.(interface{ IsBoolFlag() bool })
	return ok && bf.IsBoolFlag()
}

// errCode maps a flag-parse error to an exit code: 0 for -h/--help (already
// printed usage), 2 otherwise.
func errCode(err error) int {
	if err == flag.ErrHelp {
		return 0
	}
	return 2
}

func load() (*config.Config, int) {
	cfg, err := config.Load()
	if err != nil {
		term.Err("%v", err)
		return nil, 1
	}
	return cfg, 0
}

// resolve returns the requested (or active) target after validating it, so no
// command ever hands an unsafe host/folder to ssh or rsync.
func resolve(cfg *config.Config, name string) (config.Target, error) {
	t, err := cfg.Resolve(name)
	if err != nil {
		return t, err
	}
	if err := config.ValidateTarget(t); err != nil {
		return t, err
	}
	return t, nil
}

func printTargets(cfg *config.Config) {
	if len(cfg.Targets) == 0 {
		term.Warn("no targets yet — run %s (or: chute targets add <name> <user@host> '<folder>')", term.Bold("chute init"))
		return
	}
	for _, t := range cfg.Targets {
		marker := "  "
		name := t.Name
		if t.Name == cfg.Active {
			marker = term.Green("● ")
			name = term.Bold(name)
		}
		fmt.Printf("%s%-12s %s\n", marker, name, term.Dim(t.Dest()))
	}
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
