#!/bin/bash
# Infra B: assemble a distributable CleanMac.app from the SwiftPM build.
#
# Default (no env vars): ad-hoc signed with the hardened runtime — runs on
# this Mac, and TCC/Full Disk Access grants stick to the bundle (FR-PERM).
#
# For real distribution:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="your-notarytool-keychain-profile" \
#   scripts/package.sh
#
# NOTARY_PROFILE is optional; when set, the app is zipped, submitted with
# `xcrun notarytool submit --wait`, and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP="dist/CleanMac.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons"

cp ".build/release/CleanMac" "$APP/Contents/MacOS/CleanMac"
# Infra A: the privileged daemon rides inside the bundle; SMAppService
# registers it from Contents/Library/LaunchDaemons.
cp ".build/release/CleanHelper" "$APP/Contents/MacOS/CleanHelper"
cp "Packaging/com.cleanmac.helper.plist" "$APP/Contents/Library/LaunchDaemons/"
# CleanCore's FR-DEFS rules bundle — Bundle.module resolves it via the app's
# Resources directory once it lives here.
cp -R ".build/release/CleanMac_CleanCore.bundle" "$APP/Contents/Resources/"
cp "Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}" # "-" = ad-hoc
echo "==> codesign (identity: ${IDENTITY})"
# Sign the helper first (nested code), with the identifier the FR-SEC-1
# requirement pins; then seal the app around it.
codesign --force --options runtime \
    --identifier "com.cleanmac.CleanHelper" \
    --sign "$IDENTITY" "$APP/Contents/MacOS/CleanHelper"
codesign --force --options runtime \
    --entitlements "Packaging/CleanMac.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> notarizing"
    ditto -c -k --keepParent "$APP" "dist/CleanMac.zip"
    xcrun notarytool submit "dist/CleanMac.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "==> built $APP"
