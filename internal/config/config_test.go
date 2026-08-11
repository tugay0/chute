package config

import (
	"path/filepath"
	"testing"
)

func TestLoadDefaultWhenMissing(t *testing.T) {
	t.Setenv("CHUTE_CONFIG_DIR", filepath.Join(t.TempDir(), "nope"))
	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Active != "inbox" || len(c.Targets) != 1 || c.Targets[0].Host != "remote-box" {
		t.Fatalf("unexpected default config: %+v", c)
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	t.Setenv("CHUTE_CONFIG_DIR", t.TempDir())
	c := Default()
	c.Targets = append(c.Targets, Target{Name: "staging", Host: "user@1.2.3.4", Folder: "~/up/"})
	c.Active = "staging"
	if err := c.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Active != "staging" || len(got.Targets) != 2 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	tgt, err := got.Resolve("")
	if err != nil {
		t.Fatalf("Resolve active: %v", err)
	}
	if tgt.Dest() != "user@1.2.3.4:~/up/" {
		t.Fatalf("Dest = %q", tgt.Dest())
	}
}

func TestResolveUnknown(t *testing.T) {
	c := Default()
	if _, err := c.Resolve("ghost"); err == nil {
		t.Fatal("expected error for unknown target")
	}
}

func TestValidateTarget(t *testing.T) {
	ok := []Target{
		{Host: "remote-box", Folder: "~/inbox/"},
		{Host: "user@1.2.3.4", Folder: "~/uploads/"},
		{Host: "my-host_1.example.com", Folder: "/srv/data/"},
	}
	for _, tg := range ok {
		if err := ValidateTarget(tg); err != nil {
			t.Errorf("ValidateTarget(%+v) = %v, want nil", tg, err)
		}
	}
	bad := []Target{
		{Host: "", Folder: "~/inbox/"},
		{Host: "-oProxyCommand=touch /tmp/pwned", Folder: "~/inbox/"}, // ssh option injection
		{Host: "box with space", Folder: "~/inbox/"},
		{Host: "box", Folder: "~/$(touch /tmp/x)/"}, // remote shell expansion
		{Host: "box", Folder: "~/a;rm -rf ~/"},
		{Host: "box", Folder: "~/../etc/"},
	}
	for _, tg := range bad {
		if err := ValidateTarget(tg); err == nil {
			t.Errorf("ValidateTarget(%+v) = nil, want error", tg)
		}
	}
}

func TestNormalizeFolder(t *testing.T) {
	cases := map[string]string{"": "~/inbox/", "x": "x/", "x/": "x/", "  y  ": "y/"}
	for in, want := range cases {
		if got := NormalizeFolder(in); got != want {
			t.Errorf("NormalizeFolder(%q) = %q, want %q", in, got, want)
		}
	}
}
