#!/usr/bin/env bash
# Builds build/BrumlikAI.app from the Swift package (release configuration).
#
#   ./build-app.sh               build for this Mac
#   ./build-app.sh --universal   build for Apple silicon and Intel
#   ./build-app.sh --run         build and launch
#
# SIGN_IDENTITY="BrumlikAI Signing" ./build-app.sh signs with a stable (e.g. self-signed) certificate,
# so macOS keeps the app's permissions across builds. Without it the app is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
APP_NAME="BrumlikAI"
APP_DIR="build/$APP_NAME.app"
IDENTITY="${SIGN_IDENTITY:--}"
ARCH_FLAGS=()
[[ " $* " == *" --universal "* ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "→ swift build -c $CONFIG ${ARCH_FLAGS[*]:-}"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$APP_NAME"
[[ -f "$BIN_PATH" ]] || { echo "✗ Binary not found at $BIN_PATH"; exit 1; }

echo "→ assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

if [[ "$IDENTITY" == "-" ]]; then
    echo "→ signing ad hoc"
else
    echo "→ signing with \"$IDENTITY\""
fi
codesign --force --sign "$IDENTITY" --entitlements Resources/BrumlikAI.entitlements "$APP_DIR"

echo "✓ built $APP_DIR"
if [[ " $* " == *" --run "* ]]; then
    open "$APP_DIR"
fi
