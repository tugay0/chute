#!/usr/bin/env bash
# Build Chute.app from the Swift sources — no Xcode project needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Chute.app"
BIN="$APP/Contents/MacOS/Chute"

echo "→ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "→ compiling"
xcrun swiftc \
  -swift-version 5 \
  -O \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework Carbon \
  -framework SwiftUI \
  -framework ServiceManagement \
  -framework ImageIO \
  -o "$BIN" \
  "$ROOT"/Sources/*.swift

echo "→ signing"
SIGN_ID="Chute Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
    && echo "  signed with '$SIGN_ID' — stable identity, so macOS keeps your Accessibility/Screen-Recording grants across rebuilds" \
    || { codesign --force --sign - "$APP" >/dev/null 2>&1; echo "  (sign failed → ad-hoc)"; }
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "  ad-hoc signed — run ./sign-setup.sh once so permission grants persist across rebuilds"
fi

echo "✓ built $APP"
