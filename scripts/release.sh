#!/usr/bin/env bash
# Publishes a new BrumlikAI version on GitHub Releases, where the app's built-in updater finds it.
#
#   scripts/release.sh 0.3.0 "What's new in this version"
#
# Needs the GitHub CLI (logged in) and the update signing key (~/.brumlikai/update-signing-key, or
# BRUMLIK_UPDATE_KEY). Set SIGN_IDENTITY to a stable code-signing certificate so that users keep
# their macOS permissions after updating — see "Releasing" in the README.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-BrumlikAI $VERSION}"
KEY="${BRUMLIK_UPDATE_KEY:-$HOME/.brumlikai/update-signing-key}"
PLIST="Resources/Info.plist"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh X.Y.Z [notes]"; exit 1; }
command -v gh >/dev/null || { echo "✗ GitHub CLI (gh) is required"; exit 1; }
[[ -f "$KEY" ]] || { echo "✗ update signing key not found at $KEY"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ commit or stash your changes first"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "✗ tag v$VERSION already exists"; exit 1
fi

EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :BrumlikUpdatePublicKey' "$PLIST")"
ACTUAL_KEY="$(swift scripts/update-keys.swift public "$KEY")"
[[ "$EXPECTED_KEY" == "$ACTUAL_KEY" ]] || { echo "✗ $KEY doesn't match BrumlikUpdatePublicKey in $PLIST"; exit 1; }
[[ -n "${SIGN_IDENTITY:-}" ]] || echo "! SIGN_IDENTITY isn't set — signing ad hoc, so users will have to allow permissions again after this update."

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"

./build-app.sh --universal
rm -rf dist
mkdir dist
ditto -c -k --sequesterRsrc --keepParent build/BrumlikAI.app dist/BrumlikAI.zip
swift scripts/update-keys.swift sign dist/BrumlikAI.zip "$KEY" > dist/BrumlikAI.zip.sig

git commit -q -m "Release $VERSION" "$PLIST"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" dist/BrumlikAI.zip dist/BrumlikAI.zip.sig --title "BrumlikAI $VERSION" --notes "$NOTES"
echo "✓ released $VERSION"
