#!/usr/bin/env bash
# Builds CIDeck.app from the SwiftPM package.
#
#   ./scripts/build-app.sh              # release build into ./build/CIDeck.app
#   ./scripts/build-app.sh --install    # also copy into /Applications
#
# Requires Xcode or the Xcode Command Line Tools (macOS 13+).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/CIDeck.app"
CONFIG="release"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: CIDeck chỉ build được trên macOS." >&2
  exit 1
fi

echo "==> swift build -c $CONFIG"
swift build --package-path "$ROOT" -c "$CONFIG"

BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/CIDeck"
if [[ ! -x "$BIN" ]]; then
  echo "error: không tìm thấy binary tại $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CIDeck"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/CIDeck.app"
  cp -R "$APP" "/Applications/CIDeck.app"
  echo "Done. Mở bằng: open -a CIDeck"
else
  echo "Done: $APP"
  echo "Chạy thử: open \"$APP\""
fi
