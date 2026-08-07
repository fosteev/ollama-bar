#!/usr/bin/env bash
#
# Builds OllamaBar in Release and installs it into /Applications.
#
# The signature is ad-hoc: without a Developer ID there is nothing to notarize with, and Gatekeeper
# will ask once on first launch. See docs/TODO.md for what a real release needs.

set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED=".build/xcode"
DESTINATION="${1:-/Applications}"

command -v tuist >/dev/null || { echo "tuist is not installed: brew install tuist" >&2; exit 1; }

echo "==> generating the project"
tuist generate --no-open

echo "==> building Release"
xcodebuild \
    -workspace OllamaBar.xcworkspace \
    -scheme OllamaBar \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    build

APP="$DERIVED/Build/Products/Release/OllamaBar.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> installing $VERSION into $DESTINATION"
# The running copy holds its own bundle open; replacing it under a live process is how you get a
# half-updated app.
pkill -x OllamaBar 2>/dev/null || true
rm -rf "$DESTINATION/OllamaBar.app"
cp -R "$APP" "$DESTINATION/OllamaBar.app"

echo "==> done: $DESTINATION/OllamaBar.app ($VERSION)"
echo "    open -a OllamaBar"
