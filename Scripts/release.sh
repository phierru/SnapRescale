#!/bin/zsh
# Release build for the GitHub download: Developer ID signed, notarised, in a DMG.
# Without a Developer ID certificate it still produces an ad-hoc signed DMG for
# local testing (Gatekeeper will refuse it on other Macs).
#
#   Scripts/release.sh                 # build/release/SnapRescale-<version>.dmg
#   NOTARY_PROFILE=snaprescale Scripts/release.sh   # + notarise & staple
#
# One-time setup for notarisation (needs the paid Developer Program):
#   xcrun notarytool store-credentials snaprescale --apple-id <id> --team-id 7XVA74UJHL
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(grep -A1 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
OUT="$ROOT/build/release"; rm -rf "$OUT"; mkdir -p "$OUT"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
  echo "signing with: $IDENTITY"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=7XVA74UJHL)
else
  echo "no Developer ID certificate — ad-hoc signing (local testing only)"
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi

[ -f SnapRescale/AppIcon.icns ] || Scripts/make-icns.sh >/dev/null
xcodegen generate --quiet
xcodebuild -project SnapRescale.xcodeproj -scheme SnapRescale -configuration Release \
  -derivedDataPath build/DerivedData -quiet "${SIGN_ARGS[@]}" OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" build
APP="$OUT/SnapRescale.app"
cp -R build/DerivedData/Build/Products/Release/SnapRescale.app "$APP"
codesign --verify --deep --strict "$APP" && echo "signature verified"

DMG="$OUT/SnapRescale-$VERSION.dmg"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SnapRescale" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
[ -n "$IDENTITY" ] && codesign --sign "$IDENTITY" --timestamp "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "$IDENTITY" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "notarised and stapled"
fi
echo "release: $DMG"
