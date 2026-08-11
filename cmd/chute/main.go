// Command chute shoots files between your Mac and your VPS over plain SSH.
//
// It is a thin, zero-dependency wrapper around ssh + rsync: push files up,
// pull them down, keep a folder in sync, and always land the remote path on
// your clipboard so you can paste it straight into the box's shell.
package main

import (
	"os"

	"github.com/tugay0/chute/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:]))
}
