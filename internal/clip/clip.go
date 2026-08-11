// Package clip copies text to the system clipboard. On macOS it uses pbcopy;
// elsewhere it degrades gracefully (Copy returns an error the caller ignores).
package clip

import (
	"os/exec"
	"strings"
)

// Copy places s on the clipboard. Returns an error if no clipboard tool is
// available (e.g. running over SSH on a headless Linux box).
func Copy(s string) error {
	var name string
	var args []string
	switch {
	case have("pbcopy"):
		name = "pbcopy"
	case have("wl-copy"):
		name = "wl-copy"
	case have("xclip"):
		name, args = "xclip", []string{"-selection", "clipboard"}
	case have("xsel"):
		name, args = "xsel", []string{"--clipboard", "--input"}
	default:
		return exec.ErrNotFound
	}
	cmd := exec.Command(name, args...)
	cmd.Stdin = strings.NewReader(s)
	return cmd.Run()
}

// Available reports whether a clipboard tool exists, without touching the
// clipboard (so diagnostics like `chute doctor` don't clobber its contents).
func Available() bool {
	return have("pbcopy") || have("wl-copy") || have("xclip") || have("xsel")
}

func have(bin string) bool {
	_, err := exec.LookPath(bin)
	return err == nil
}
