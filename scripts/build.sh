#!/bin/bash
# Build "iMessage Bridge.app" into ./build.
#
# Signing: uses $SIGN_IDENTITY if set, otherwise the first "Developer ID
# Application" identity in your keychain, otherwise ad hoc. With ad hoc
# signing, macOS forgets the Full Disk Access grant after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="iMessage Bridge"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
APP="$ROOT/build/$APP_NAME.app"

echo "==> Compiling (release)"
swift build -c release --product IMessageBridgeApp
swift build -c release --product imessage-bridge
BIN="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/AgentBubbleMenuTemplate.png Resources/AgentBubbleMenuTemplate@2x.png \
    "$APP/Contents/Resources/"
cp "$BIN/IMessageBridgeApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN/imessage-bridge" "$APP/Contents/MacOS/imessage-bridge"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sparkle (auto-updates). The app isn't sandboxed, so Sparkle's XPC services
# aren't needed; dropping them leaves fewer things to sign.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
    "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi

if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing with: $IDENTITY"
    SIGN=(--force --options runtime --timestamp --sign "$IDENTITY")
else
    echo "==> Signing ad hoc (no Developer ID found; set SIGN_IDENTITY to override)"
    SIGN=(--force --options runtime --sign -)
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN[@]}" "$SPARKLE"
codesign "${SIGN[@]}" --identifier "$BUNDLE_ID.cli" "$APP/Contents/MacOS/imessage-bridge"
codesign "${SIGN[@]}" --identifier "$BUNDLE_ID" \
    --entitlements Resources/IMessageBridge.entitlements "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Built $APP"
