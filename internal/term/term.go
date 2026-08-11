// Package term is a tiny, dependency-free helper for colored status output.
// Color is disabled automatically when stdout is not a terminal or when
// NO_COLOR / CHUTE_NO_COLOR is set.
package term

import (
	"fmt"
	"os"
)

var enabled = colorEnabled()

func colorEnabled() bool {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("CHUTE_NO_COLOR") != "" {
		return false
	}
	// Require BOTH streams to be terminals: status lines go to stderr and the
	// styled listings go to stdout, so if either is redirected we must stay
	// plain or ANSI escapes leak into the redirected file/pipe.
	return isTTY(os.Stdout) && isTTY(os.Stderr)
}

func isTTY(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

func wrap(code, s string) string {
	if !enabled {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

// Bold, Dim, and the colors return styled copies of s (no-op when disabled).
func Bold(s string) string   { return wrap("1", s) }
func Dim(s string) string    { return wrap("2", s) }
func Green(s string) string  { return wrap("32", s) }
func Red(s string) string    { return wrap("31", s) }
func Cyan(s string) string   { return wrap("36", s) }
func Yellow(s string) string { return wrap("33", s) }

// Status lines go to stderr so stdout stays clean for machine-readable output
// (e.g. the remote paths printed by 'chute push').
func Ok(format string, a ...any)  { fmt.Fprintln(os.Stderr, Green("✓")+" "+fmt.Sprintf(format, a...)) }
func Err(format string, a ...any) { fmt.Fprintln(os.Stderr, Red("✗")+" "+fmt.Sprintf(format, a...)) }
func Info(format string, a ...any) {
	fmt.Fprintln(os.Stderr, Cyan("→")+" "+fmt.Sprintf(format, a...))
}
func Warn(format string, a ...any) {
	fmt.Fprintln(os.Stderr, Yellow("!")+" "+fmt.Sprintf(format, a...))
}
