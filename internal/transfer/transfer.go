// Package transfer runs the actual file movement by shelling out to rsync over
// ssh. Everything is a thin wrapper so behavior matches what you'd get typing
// rsync yourself — no magic, easy to audit.
package transfer

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/tugay0/chute/internal/config"
	"github.com/tugay0/chute/internal/term"
)

// rsyncOpts returns the base rsync flags. Override with CHUTE_RSYNC_OPTS if the
// defaults don't suit your rsync flavor (macOS may ship openrsync).
func rsyncOpts() []string {
	if v := os.Getenv("CHUTE_RSYNC_OPTS"); v != "" {
		return strings.Fields(v)
	}
	return []string{"-az", "--progress"}
}

// sshCmd is the ssh command rsync uses (rsync's -e value) and that we use for
// remote mkdir. Override with CHUTE_SSH, e.g. "ssh -p 2222".
func sshCmd() string {
	if v := os.Getenv("CHUTE_SSH"); v != "" {
		return v
	}
	return "ssh"
}

func sshArgv() []string { return strings.Fields(sshCmd()) }

// ensureRemoteDir makes the target folder on the remote host so a first push to
// a fresh box doesn't fail. The '~' is expanded by the remote login shell.
func ensureRemoteDir(t config.Target) error {
	argv := sshArgv()
	argv = append(argv, t.Host, "mkdir -p "+shellSafe(t.Folder))
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("could not reach %s (ssh %s): %w", t.Host, t.Host, err)
	}
	return nil
}

// Push copies local paths up to the target and returns the resulting remote
// paths (folder + basename), suitable for the clipboard.
func Push(t config.Target, paths []string, dryRun bool) ([]string, error) {
	if !dryRun {
		if err := ensureRemoteDir(t); err != nil {
			return nil, err
		}
	}
	args := rsyncOpts()
	if dryRun {
		args = append(args, "--dry-run")
	}
	args = append(args, "-e", sshCmd(), "--")
	for _, p := range paths {
		// Trim any trailing slash so a directory always creates its own level
		// on the remote (rsync's "dir/" copies contents instead) — this keeps
		// the reported remote path below accurate for `chute push ./dist/`.
		args = append(args, strings.TrimRight(p, "/"))
	}
	args = append(args, t.Dest())
	if err := runRsync(args); err != nil {
		return nil, err
	}
	folder := strings.TrimSuffix(t.Folder, "/")
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		out = append(out, folder+"/"+filepath.Base(strings.TrimRight(p, "/")))
	}
	return out, nil
}

// Pull copies remote paths down into dest (default "."). A remote path without
// a leading / or ~ is taken relative to the target folder.
func Pull(t config.Target, remotePaths []string, dest string) error {
	if dest == "" {
		dest = "."
	}
	args := rsyncOpts()
	args = append(args, "-e", sshCmd(), "--")
	folder := strings.TrimSuffix(t.Folder, "/")
	for _, rp := range remotePaths {
		full := rp
		if !strings.HasPrefix(rp, "/") && !strings.HasPrefix(rp, "~") {
			full = folder + "/" + rp
		}
		args = append(args, t.Host+":"+full)
	}
	args = append(args, dest)
	return runRsync(args)
}

// Watch mirrors a local directory up to the target whenever its contents
// change. It polls (no native dependency) so it works anywhere. Blocks until
// interrupted.
func Watch(t config.Target, dir string, interval time.Duration, del bool) error {
	if err := ensureRemoteDir(t); err != nil {
		return err
	}
	sync := func() error {
		args := rsyncOpts()
		if del {
			args = append(args, "--delete")
		}
		// Trailing slash: copy the *contents* of dir into the remote folder.
		args = append(args, "-e", sshCmd(), "--", strings.TrimSuffix(dir, "/")+"/", t.Dest())
		return runRsync(args)
	}
	last := ""
	first := true // always sync once up front, even if the tree is empty
	for {
		fp, err := fingerprint(dir)
		if err != nil {
			return err
		}
		if first || fp != last {
			if err := sync(); err != nil {
				// Don't advance state on failure — retry the same change on the
				// next tick until it lands, so a transient blip can't silently
				// drop the edit.
				term.Err("sync failed (will retry): %v", err)
			} else {
				term.Ok("synced at %s", time.Now().Format("15:04:05"))
				last = fp
				first = false
			}
		}
		time.Sleep(interval)
	}
}

func runRsync(args []string) error {
	cmd := exec.Command("rsync", args...)
	// rsync's own progress output is diagnostic — send it to stderr so chute's
	// stdout carries only the paste-ready remote paths (keeps `chute push f |
	// pbcopy` and `p=$(chute push f)` clean).
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("rsync: %w", err)
	}
	return nil
}

// fingerprint is a cheap snapshot of a tree: path|size|mtime per file.
func fingerprint(dir string) (string, error) {
	var b strings.Builder
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			// A file vanished mid-walk or a subdir is unreadable — skip it and
			// keep watching rather than killing the whole long-running watcher.
			if errors.Is(err, fs.ErrNotExist) || errors.Is(err, fs.ErrPermission) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		fmt.Fprintf(&b, "%s|%d|%d\n", p, info.Size(), info.ModTime().UnixNano())
		return nil
	})
	if err != nil {
		return "", err
	}
	return b.String(), nil
}

// shellSafe rejects folder values that could break out of the remote mkdir
// command. Real folder names never contain these.
func shellSafe(s string) string {
	if strings.ContainsAny(s, "$`;&|<>()\n\"'\\ ") {
		// Fall back to a quoted literal; ~ won't expand but the value is odd
		// enough that safety wins over convenience.
		return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
	}
	return s
}
