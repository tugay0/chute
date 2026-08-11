// Package config reads and writes chute's on-disk configuration: a list of
// named SSH targets (host + remote folder) and which one is active.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Target is a place to send files: a friendly name, an SSH host (an alias from
// ~/.ssh/config or a user@host), and a remote folder the files land in.
type Target struct {
	Name   string `json:"name"`
	Host   string `json:"host"`
	Folder string `json:"folder"`
}

// Dest is the rsync-style "host:folder" destination string.
func (t Target) Dest() string { return t.Host + ":" + t.Folder }

// Config is the whole config file.
type Config struct {
	Active  string   `json:"active"`
	Targets []Target `json:"targets"`
}

// Default is what you get before you've configured anything — it matches the
// Chute menu-bar app's out-of-the-box destination.
func Default() Config {
	return Config{
		Active:  "inbox",
		Targets: []Target{{Name: "inbox", Host: "remote-box", Folder: "~/inbox/"}},
	}
}

// Dir is the config directory, honoring CHUTE_CONFIG_DIR and XDG_CONFIG_HOME.
func Dir() string {
	if x := os.Getenv("CHUTE_CONFIG_DIR"); x != "" {
		return x
	}
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "chute")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "chute")
}

// Path is the config file path.
func Path() string { return filepath.Join(Dir(), "config.json") }

// Load returns the saved config, or the built-in default if none exists yet.
func Load() (*Config, error) {
	b, err := os.ReadFile(Path())
	if errors.Is(err, os.ErrNotExist) {
		c := Default()
		return &c, nil
	}
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, errors.New("config file is not valid JSON (" + Path() + "): " + err.Error())
	}
	if len(c.Targets) == 0 {
		c.Targets = Default().Targets
	}
	if c.Active == "" {
		c.Active = c.Targets[0].Name
	}
	return &c, nil
}

// Save writes the config to disk, creating the directory if needed.
func (c *Config) Save() error {
	if err := os.MkdirAll(Dir(), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(Path(), append(b, '\n'), 0o600)
}

// Find returns a pointer to the named target, or false.
func (c *Config) Find(name string) (*Target, bool) {
	for i := range c.Targets {
		if c.Targets[i].Name == name {
			return &c.Targets[i], true
		}
	}
	return nil, false
}

// Resolve returns the named target, or the active one when name is empty.
func (c *Config) Resolve(name string) (Target, error) {
	if name == "" {
		name = c.Active
	}
	if t, ok := c.Find(name); ok {
		return *t, nil
	}
	if len(c.Targets) > 0 && name == c.Active {
		return c.Targets[0], nil
	}
	return Target{}, errors.New("no such target: " + name + " (see 'chute targets')")
}

// ValidateTarget rejects hosts and folders that ssh or the remote shell could
// misread. A host beginning with "-" would be parsed by ssh as an option (e.g.
// "-oProxyCommand=…" → local code execution), and a folder with shell
// metacharacters is expanded by the remote login shell because rsync's
// openrsync (default on recent macOS) doesn't protect remote args.
func ValidateTarget(t Target) error {
	h := strings.TrimSpace(t.Host)
	switch {
	case h == "":
		return errors.New("host is empty")
	case strings.HasPrefix(h, "-"):
		return fmt.Errorf("host %q must not start with '-'", h)
	case strings.ContainsAny(h, " \t\r\n"):
		return fmt.Errorf("host %q must not contain whitespace", h)
	}
	if strings.ContainsAny(t.Folder, "$`;&|<>()\n\r\"'\\*?[]{}! \t") {
		return fmt.Errorf("folder %q contains characters that aren't allowed (shell metacharacters/whitespace)", t.Folder)
	}
	if strings.Contains(t.Folder, "..") {
		return fmt.Errorf("folder %q must not contain '..'", t.Folder)
	}
	return nil
}

// NormalizeFolder trims a folder and guarantees a trailing slash so rsync
// treats it as a directory.
func NormalizeFolder(f string) string {
	f = strings.TrimSpace(f)
	if f == "" {
		f = "~/inbox/"
	}
	if !strings.HasSuffix(f, "/") {
		f += "/"
	}
	return f
}
