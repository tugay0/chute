# Chute — macOS menu-bar companion

The hands-free half of [Chute](../). A tiny AppKit app that lives under your notch:
drag a file onto the pill, hover + **⌘V** to paste, or **⌥⌘4** to snip a screen region —
it lands on your VPS and copies the remote path, using the same `ssh` + `rsync` transport
as the CLI.

See [SPEC.md](SPEC.md) for the full design.

## Build

No Xcode project — it builds with the system `swiftc`:

```bash
./sign-setup.sh   # once: a stable "Chute Dev" self-signed identity so macOS
                  # keeps its permission grants across rebuilds
./build.sh        # compiles + signs → build/Chute.app
open build/Chute.app
```

There's no dock icon — look for the status glyph in the menu bar and the pill under your
notch. It expects an SSH host alias (default `remote-box`) in `~/.ssh/config`; change the
destination in **Preferences**.

## Permissions (one-time)

- **Accessibility** — for hover + **⌘V** paste. Prompted on launch.
- **Screen Recording** — for **⌥⌘4** region capture. Prompted on first use.

Both persist across rebuilds thanks to the stable signing identity.
