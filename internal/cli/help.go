package cli

import (
	"fmt"
	"os"

	"github.com/tugay0/chute/internal/term"
)

func usage() {
	fmt.Fprint(os.Stderr, ``+
		term.Bold("chute")+" — shoot files between your Mac and your VPS.\n\n"+
		term.Bold("USAGE\n")+
		"  chute <command> [args]\n\n"+
		term.Bold("COMMANDS\n")+
		"  init               point Chute at your VPS (guided one-time setup)\n"+
		"  push <path>...     send files or folders up to the remote (path lands on your clipboard)\n"+
		"  pull <path>...     bring files down from the remote\n"+
		"  watch [dir]        keep a local folder mirrored up to the remote\n"+
		"  targets            list, add, switch, or remove send targets\n"+
		"  config             show config, print its path, or open it in $EDITOR\n"+
		"  doctor             check ssh/rsync and test the connection\n"+
		"  version            print the version\n\n"+
		term.Bold("EXAMPLES\n")+
		"  chute init                             # one-time: point Chute at your box\n"+
		"  chute push screenshot.png              # → your box:~/inbox/, path copied\n"+
		"  chute push ./dist --to staging         # send a folder to a named target\n"+
		"  chute pull logs/app.log --dest ~/tmp   # grab a file off the box\n"+
		"  chute watch ./out                      # auto-sync a build folder\n"+
		"  chute targets add staging user@1.2.3.4 '~/uploads/'\n\n"+
		term.Dim("Config lives at ~/.config/chute/config.json. Hosts are ~/.ssh/config aliases or user@host.\n"))
}

const pushHelp = `chute push — send files or folders up to the remote.

USAGE
  chute push <path>... [--to name] [--dry-run] [--no-copy]

FLAGS
  --to name     send to a named target instead of the active one
  --dry-run     show what rsync would transfer, send nothing
  --no-copy     don't copy the resulting remote path to the clipboard

On success the remote path(s) are printed to stdout and copied to your
clipboard, ready to paste into the box's shell.
`

const pullHelp = `chute pull — bring files down from the remote.

USAGE
  chute pull <remote-path>... [--from name] [--dest dir]

FLAGS
  --from name   pull from a named target instead of the active one
  --dest dir    local directory to download into (default: current dir)

A remote path without a leading / or ~ is taken relative to the target folder,
so 'chute pull app.log' fetches <folder>/app.log.
`

const watchHelp = `chute watch — mirror a local folder up to the remote on change.

USAGE
  chute watch [dir] [--to name] [--interval 2s] [--delete]

FLAGS
  --to name        send to a named target instead of the active one
  --interval dur   how often to poll for changes (default: 2s)
  --delete         also remove files on the remote that you delete locally

Runs until interrupted (Ctrl-C). Uses polling, so it needs no extra tools.
`
