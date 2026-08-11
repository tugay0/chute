# Chute — spec

A tiny always-on macOS agent app that lives under the notch. Drop or paste a
file and it's instantly on the VPS, with a status light confirming sync — so you
never have to babysit `/push` for screenshots again.

> Name is a placeholder codename (a file goes "down the chute" to the server).
> Trivial to rename — see *Renaming* below.

## Problem

Coding happens on a remote VPS via a terminal + a server-side Claude instance.
Pasting a screenshot into that remote session is impossible. The current
workaround is: save the file locally → run the `/push` skill → it rsyncs to
`remote-box:~/inbox`. Works, but it's a manual, multi-step ritual.

## Solution

A **drop zone + paste target** that hides in the notch. At rest it's invisible;
hovering the notch — or dragging a file toward it — springs a card down. Files
land in `remote-box:~/inbox`, exactly where the server-side Claude already looks,
using the *same* transport as `/push`. The persistent "green light" lives in the
menu bar so nothing hangs on screen when idle.

## Core interactions

| Action | How |
|---|---|
| **⌥⌘4 (capture)** | Global Carbon hotkey: `screencapture -i` region snip → upload → remote path copied. One gesture from screen to server-with-path-in-hand. Needs Screen Recording. |
| **Drop** | Drag one or more files (or an image straight from a browser/Preview) onto the pill. It expands + glows, then queues and pushes each. Drops it can't read are rejected (no false "accepted" highlight). |
| **Click** | Click the revealed card to send whatever's on the clipboard. The permission-free paste path. |
| **⌘V (hover)** | Move the pointer onto the notch (card drops), press **⌘V**. Chute *consumes* the keystroke via a `CGEventTap` so it doesn't also paste into the focused app; autorepeat is ignored so a held key doesn't duplicate. Needs Accessibility. |
| **Menu bar** | A status glyph with: *Capture region → send*, *Send clipboard now (⌘V)*, *Clipboard history ▸*, *Open outbox folder*, *Check server*, *Preferences…*, *Quit*. Guarantees control even if the notch UI is finicky. |

**Every successful send copies the remote path** (`~/inbox/<file>`, newline-joined
for batches) to the clipboard — so it can be pasted straight into the box's shell
or Claude session. This is what makes ⌥⌘4 a full loop: snip → upload → path in hand.

Clipboard/dragged **files** are sent verbatim. Clipboard **image data** is saved
to the outbox in its original flavour (`pdf`/`jpg`/`png`/`tiff`, timestamped to
the millisecond) — only truly format-less bitmaps fall back to PNG.

## Sync light (the "green light")

The always-on indicator is the **menu-bar dot** (the notch card is hidden at
rest). While hidden, a subtle colored **sliver** also peeks under the notch —
but only while sending or after a failure, never when idle. When the card is
revealed it shows the same dot plus text:

| State | Colour | Meaning |
|---|---|---|
| Synced | 🟢 green | Server reachable, queue empty, last transfer OK |
| Sending | 🟠 amber | One or more transfers in flight (`Sending N…`) |
| Failed | 🔴 red | Last transfer returned non-zero (message shows the tail of stderr) |
| Offline | ⚪ grey | Server unreachable (heartbeat failed) |

A lightweight `ssh -o BatchMode -o ConnectTimeout=5 remote-box true` heartbeat
runs every **25 s** so the light is honest even when idle.

## Transport

- Primary: shells out to `~/.claude/skills/push/push.sh <paths…>` — byte-for-byte
  the same path as the `/push` skill (`rsync -avz` → `remote-box:inbox/`). If you
  ever repoint `push.sh`, Chute follows automatically.
- Fallback (if the helper is missing): `rsync -avz <paths…> remote-box:inbox/`.
- Child processes get an explicit `PATH` + `HOME` so `ssh`/`rsync` resolve
  `~/.ssh/config` and the key even when launched from Finder (sparse launchd env).

## Preferences (menu bar → *Preferences…*)

A SwiftUI window (`SMAppService` for launch-at-login):
- **Destination** — SSH host + remote folder. Stock `remote-box:inbox/` uses
  `push.sh`; anything else uses a direct `rsync -avz host:folder`.
- **Copy format** — the template copied on each send (`{name}`/`{folder}`/`{host}`),
  default `~/inbox/{name}`.
- **Sound on send**, **remappable capture hotkey** (record a new combo),
  **Launch at login**.

## Offline queue + auto-resend

If the box is unreachable, a send is buffered (persisted to UserDefaults) instead
of failing red; the status goes `Offline — N queued`. The 25s heartbeat flushes
the buffer automatically on reconnect (or via *Check server*). A genuine rsync
error (server reachable, transfer failed) still shows red and is not auto-retried.

## Clipboard history + favorites

**History** (menu bar → *Clipboard history ▸*) polls the pasteboard and keeps the
**last 10** items (text/image/file). Per item: click **copies** it back,
**⌥-click sends** it to the box, **⌃-click pins** it to Favorites. Our own
path-copies are suppressed so they don't flood the list.

**Favorites** (menu bar → *Favorites ▸*) are pinned and **persist across restarts**
(JSON in UserDefaults; file payloads copied into a favorites dir that's never
purged). Click = copy, ⌥-click = send. In **Preferences → Favorites** each one can
be given a **global hotkey** (records a combo; the hotkey copies that item to the
clipboard) or removed.

## Local folder sync (2-way mirror)

Opt-in (Preferences → *Local folder sync*): keeps a local folder (`~/Chute`)
mirrored to `remote-box:~/inbox`, so you open it in Finder and interact natively —
open, QuickLook, rename, drag out, delete. A 6s cycle:

1. **Scan** both sides — local via a `FileManager` enumerator, remote via
   `ssh … find -printf`. A failed/offline scan **aborts the cycle** (never act on
   missing data).
2. **3-way diff** against a saved base snapshot (`syncstate.json`): each path is
   classified as download / upload / delete-local / delete-remote / in-sync.
   Crucially a file *in the base but missing on one side* is a **deletion**, not a
   re-transfer — so deletes are never resurrected by a blanket rsync.
3. **Apply**: transfer only the diff (`rsync --from0 --files-from`); deletions go
   to the **Trash** (local) / a `.chute-trash/` folder (remote) — recoverable,
   never `rm`. Conflicts (edited both sides) → newer mtime wins.

Safety rails: abort on any failed scan, a **circuit breaker** that pauses a cycle
which would delete more than half the base (catches a glitchy scan), non-
destructive trashed deletes, and serialized cycles (no overlap). Menu bar →
*Open Chute folder* / *Sync now*; the menu shows live sync status.

## Architecture

Pure AppKit + a SwiftUI preferences window, compiled with the system `swiftc`
into a signed `.app` bundle (no Xcode project required).

```
Sources/
  FileStrip.swift       in-notch recent-files grid (thumbnails, drag-out, trash zone)
  Status.swift          sync state machine + presentation (colour/headline/glyph)
  Uploader.swift        transfer queue, push.sh/rsync, ssh heartbeat, offline resend, copy-path
  NotchView.swift       drawn card, drag-drop, click-to-send, height-driven drawing
  NotchController.swift  non-activating NSPanel, in-notch placement, hover polling + spring, ⌘V tap
  ClipboardHistory.swift last-10 pasteboard history (copy / send / pin)
  Favorites.swift       pinned persistent items + per-item global hotkeys
  FolderSync.swift      2-way ~/Chute ↔ inbox mirror (diff-based, trashed deletes)
  Settings.swift        UserDefaults config (Config enum)
  SettingsWindow.swift  SwiftUI prefs (destination/sound/hotkey/favorites/login), recorder
  HotKeyManager.swift   Carbon global hotkeys (remappable capture + per-favorite)
  main.swift            AppDelegate, menu-bar item + history submenu, run loop
Resources/Info.plist    LSUIElement (no dock icon), bundle id com.github.tugay0.chute
build.sh                swiftc → build/Chute.app → ad-hoc codesign
```

- **Window**: borderless `.nonactivatingPanel` at `.statusBar` level, `canJoinAllSpaces`,
  anchored to the screen top on the display that actually has a notch (not
  focus-following `NSScreen.main`); the card is wider than the notch so it reads as
  the notch unfurling. Hover is **cursor polling with hysteresis**: it opens only
  when the pointer is **in the notch** (`revealZone` = exact notch bounds from
  `safeAreaInsets` + the auxiliary ears) and closes once the pointer leaves the
  card+26pt (`hideZone` ⊃ `revealZone`, so no open/close vibration). Spring reveal
  (`0.36s` overshoot down, `0.22s` ease up); drawing is height-driven so content
  fades with the motion. At rest it's an invisible strip (nothing drawn).
- **Paste**: a `CGEventTap` (`.cgSessionEventTap`) gated on `isHovering` intercepts
  ⌘V and returns `nil` to *consume* it — so the focused app doesn't also paste —
  acting only when the clipboard holds an image/file (a normal text ⌘V passes
  through). Autorepeat is filtered. Requires **Accessibility**; the app polls for
  the grant and arms the tap without needing a relaunch. Click-to-send and drag
  work with no permission.

## Permissions

- **Accessibility** — for the hover-⌘V global key monitor. Prompted on first
  launch. Without it, use *Send clipboard now* from the menu bar.
- SSH — reuses the existing `remote-box` host + `~/.ssh/id_ed25519`. Nothing new.

## Non-goals (v0.1)

- Per-file progress bars, transfer history UI, retries UI.
- A packaged installer / notarized distribution (self-signed, build-it-yourself).

## Renaming

Change `CFBundleName`/`CFBundleDisplayName`/`CFBundleIdentifier` in
`Resources/Info.plist`, the output name in `build.sh`, and rebuild.
