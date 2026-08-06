#!/usr/bin/env bash
# Creates a self-signed code-signing certificate that signs CIDeck.app with a
# stable identity. An ad-hoc signature changes its cdhash after every build, so
# Keychain treats every build as a different app and asks for the login password
# again. A certificate keeps the designated requirement stable.
#
#   ./scripts/make-signing-cert.sh              # create the "CIDeck Dev" identity
#   ./scripts/make-signing-cert.sh "Other Name" # use a different name
#
# Run once, then build with:
#   CODESIGN_IDENTITY="CIDeck Dev" ./scripts/build-app.sh --install
set -euo pipefail

NAME="${1:-CIDeck Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script can only run on macOS." >&2
  exit 1
fi

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
  echo "==> identity \"$NAME\" already exists; nothing to create."
  echo "Build with: CODESIGN_IDENTITY=\"$NAME\" ./scripts/build-app.sh --install"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Older LibreSSL versions do not support -addext, so use a config file.
cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $NAME

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> creating certificate \"$NAME\" (valid for 10 years)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1

openssl pkcs12 -export -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:cideck >/dev/null 2>&1

echo "==> importing into the login keychain"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P cideck -T /usr/bin/codesign

# Without trust settings, codesign reports "unable to build chain to self-signed
# root". -p codeSign limits trust to code signing rather than TLS.
echo "==> trusting the certificate for code signing (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

# Without this step, codesign asks to use the private key on every build.
echo "==> allowing codesign to use the private key without asking again"
echo -n "Login keychain password (leave empty to skip): "
read -rs KCPASS
echo
if [[ -n "$KCPASS" ]]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KCPASS" "$KEYCHAIN" >/dev/null
else
  echo "    Skipped. codesign will request key access on the first build; click Always Allow."
fi

echo
echo "Done. Build again with:"
echo "  CODESIGN_IDENTITY=\"$NAME\" ./scripts/build-app.sh --install"
