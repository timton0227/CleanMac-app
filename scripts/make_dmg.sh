#!/bin/bash
# Wrap dist/CleanMac.app in a drag-to-install .dmg for sharing with testers.
# Runs scripts/package.sh first if the app hasn't been built yet. Honors the
# same CODESIGN_IDENTITY / NOTARY_PROFILE env vars as package.sh — set them to
# also sign and notarize the disk image itself (recommended for anyone outside
# your own Mac; see the Gatekeeper note printed at the end).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/CleanMac.app"
if [[ ! -d "$APP" ]]; then
    echo "==> $APP not found — running scripts/package.sh first"
    scripts/package.sh
fi

DMG="dist/CleanMac.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications" # lets testers drag-install

rm -f "$DMG"
echo "==> hdiutil create"
hdiutil create -volname "CleanMac" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "==> codesign dmg"
    codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> notarizing dmg"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "==> built $DMG"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "==> NOT notarized: testers on OTHER Macs will need to bypass Gatekeeper"
    echo "    (right-click the app -> Open, or: xattr -cr /Applications/CleanMac.app)"
fi
