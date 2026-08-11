#!/usr/bin/env bash
# Chute installer — downloads the latest release binary for your OS/arch.
#
#   curl -fsSL https://raw.githubusercontent.com/tugay0/chute/main/install.sh | bash
#
# Overrides:
#   CHUTE_VERSION=v0.1.0   install a specific tag
#   CHUTE_INSTALL_DIR=...  install location (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

REPO="tugay0/chute"
BIN="chute"

info() { printf '\033[36m→\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# --- platform detection ---------------------------------------------------
os="$(uname -s)"
case "$os" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *) die "unsupported OS: $os (Chute supports macOS and Linux)" ;;
esac

arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="amd64" ;;
  *) die "unsupported architecture: $arch" ;;
esac

command -v rsync >/dev/null 2>&1 || info "note: rsync not found — install it before using chute (macOS ships it; Linux: apt/dnf install rsync)"
command -v ssh   >/dev/null 2>&1 || info "note: ssh not found — install openssh before using chute"

# --- resolve version ------------------------------------------------------
version="${CHUTE_VERSION:-}"
if [ -z "$version" ]; then
  info "finding latest release…"
  # '|| true' so a rate-limited/404 API response doesn't abort under pipefail
  # before the friendly hint below can fire.
  version="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')" || true
  [ -n "$version" ] || die "could not determine latest version (GitHub API may be rate-limited; set CHUTE_VERSION=vX.Y.Z to override)"
fi
ver_no_v="${version#v}"
tag="v${ver_no_v}"   # tolerate CHUTE_VERSION given with or without a leading 'v'

asset="${BIN}_${ver_no_v}_${os}_${arch}.tar.gz"
url="https://github.com/${REPO}/releases/download/${tag}/${asset}"

# --- download + verify ----------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "downloading ${asset}"
curl -fSL --proto '=https' "$url" -o "$tmp/$asset" || die "download failed: $url"

# checksum (best-effort: only if checksums.txt is published)
if curl -fsSL "https://github.com/${REPO}/releases/download/${tag}/checksums.txt" -o "$tmp/checksums.txt" 2>/dev/null; then
  sha="shasum -a 256"; command -v sha256sum >/dev/null 2>&1 && sha="sha256sum"
  want="$(grep " ${asset}\$" "$tmp/checksums.txt" | awk '{print $1}')"
  if [ -n "$want" ]; then
    got="$($sha "$tmp/$asset" | awk '{print $1}')"
    [ "$want" = "$got" ] || die "checksum mismatch for ${asset}"
    ok "checksum verified"
  fi
fi

tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/$BIN" ] || die "archive did not contain the '$BIN' binary"
chmod +x "$tmp/$BIN"

# --- install --------------------------------------------------------------
dir="${CHUTE_INSTALL_DIR:-}"
if [ -z "$dir" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null; then dir="/usr/local/bin"
  else dir="$HOME/.local/bin"; fi
fi
mkdir -p "$dir" 2>/dev/null || sudo mkdir -p "$dir"

if mv "$tmp/$BIN" "$dir/$BIN" 2>/dev/null; then :
elif command -v sudo >/dev/null 2>&1; then
  info "writing to $dir needs sudo"
  sudo mv "$tmp/$BIN" "$dir/$BIN"
else
  die "cannot write to $dir (set CHUTE_INSTALL_DIR to a writable path)"
fi

ok "installed $BIN $version → $dir/$BIN"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) rc="$HOME/.zshrc"; case "${SHELL:-}" in *bash) rc="$HOME/.bashrc" ;; esac
     info "add $dir to your PATH:  echo 'export PATH=\"$dir:\$PATH\"' >> $rc" ;;
esac
info "next: chute targets add box user@host '~/inbox/'  &&  chute push somefile"
