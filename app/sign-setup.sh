#!/usr/bin/env bash
# One-time setup: create a stable self-signed code-signing identity ("Chute Dev").
#
# Why: an ad-hoc-signed app gets a new code identity on every rebuild, so macOS
# forgets its Accessibility / Screen Recording grants each time. Signing every
# build with the SAME self-signed cert keeps the identity (and thus the grants)
# stable. Chute never needs sudo/root — only these two TCC permissions.
#
# Run once, then rebuild with ./build.sh. You'll grant the two permissions one
# final time; they persist from then on.
set -e
NAME="Chute Dev"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "'$NAME' identity already exists — nothing to do. Just ./build.sh."
  exit 0
fi

D=$(mktemp -d); cd "$D"
cat > cfg.conf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Chute Dev
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -config cfg.conf >/dev/null 2>&1
# Ephemeral password: the .p12 lives only in this temp dir (removed below) and
# wraps a locally-generated, self-signed, trust-less cert — but keep it random
# so there's no hardcoded password anywhere.
P12PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey key.pem -in cert.pem -out chute.p12 \
  -name "$NAME" -passout "pass:$P12PASS" >/dev/null 2>&1
security import chute.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$P12PASS" -T /usr/bin/codesign

cd /; rm -rf "$D"
echo "Created '$NAME'."
echo "Next: ./build.sh, then grant Accessibility + Screen Recording once (they'll stick)."
