package cli

import (
	"flag"
	"reflect"
	"testing"
)

// TestParseFlagsInterspersed guards the bug where Go's flag package stops at the
// first positional, so "push file --to staging" swallowed the flag as a path.
func TestParseFlagsInterspersed(t *testing.T) {
	newFS := func() (*flag.FlagSet, *string, *bool) {
		fs := flag.NewFlagSet("t", flag.ContinueOnError)
		to := fs.String("to", "", "")
		noCopy := fs.Bool("no-copy", false, "")
		return fs, to, noCopy
	}

	tests := []struct {
		name     string
		args     []string
		wantPos  []string
		wantTo   string
		wantBool bool
	}{
		{"flags after positionals", []string{"a.png", "b.png", "--to", "staging", "--no-copy"},
			[]string{"a.png", "b.png"}, "staging", true},
		{"flags before positionals", []string{"--to", "staging", "a.png"},
			[]string{"a.png"}, "staging", false},
		{"equals form", []string{"file", "--to=prod"},
			[]string{"file"}, "prod", false},
		{"double dash stops parsing", []string{"--to", "x", "--", "--weird-name.png"},
			[]string{"--weird-name.png"}, "x", false},
		{"bool then positional", []string{"--no-copy", "only.txt"},
			[]string{"only.txt"}, "", true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fs, to, noCopy := newFS()
			pos, err := parseFlags(fs, tc.args)
			if err != nil {
				t.Fatalf("parseFlags: %v", err)
			}
			if !reflect.DeepEqual(pos, tc.wantPos) {
				t.Errorf("positional = %v, want %v", pos, tc.wantPos)
			}
			if *to != tc.wantTo {
				t.Errorf("--to = %q, want %q", *to, tc.wantTo)
			}
			if *noCopy != tc.wantBool {
				t.Errorf("--no-copy = %v, want %v", *noCopy, tc.wantBool)
			}
		})
	}
}
