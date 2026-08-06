#!/usr/bin/env bash
# Builds CIDeck.app from the SwiftPM package.
#
#   ./scripts/build-app.sh              # release build into ./build/CIDeck.app
#   ./scripts/build-app.sh --install    # also copy into /Applications
#
# The default ad-hoc signature changes its cdhash after every build, so Keychain
# treats each build as a different app and asks for the login password again.
# Use a self-signed code-signing certificate to keep the signature stable:
#
#   CODESIGN_IDENTITY="CIDeck Dev" ./scripts/build-app.sh --install
#
# Requires Xcode or the Xcode Command Line Tools (macOS 13+).
set -euo pipefail

IDENTITY="${CODESIGN_IDENTITY:--}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/CIDeck.app"
CONFIG="release"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: CIDeck can only be built on macOS." >&2
  exit 1
fi

echo "==> swift build -c $CONFIG"
swift build --package-path "$ROOT" -c "$CONFIG"

BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/CIDeck"
if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CIDeck"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for locale in en vi; do
  mkdir -p "$APP/Contents/Resources/$locale.lproj"
  cp "$ROOT/Sources/CIDeck/Resources/$locale.lproj/Localizable.strings" \
     "$APP/Contents/Resources/$locale.lproj/Localizable.strings"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "$IDENTITY" == "-" ]]; then
  echo "==> codesign (ad-hoc)"
  echo "    Note: the ad-hoc signature changes after every build, so Keychain will ask for the password again."
  echo "    Set CODESIGN_IDENTITY=<certificate name> to keep the signature stable."
else
  echo "==> codesign ($IDENTITY)"
fi
codesign --force --deep --identifier com.vt.cideck --sign "$IDENTITY" "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/CIDeck.app"
  cp -R "$APP" "/Applications/CIDeck.app"
  echo "Done. Open with: open -a CIDeck"
else
  echo "Done: $APP"
  echo "Run with: open \"$APP\""
fi
