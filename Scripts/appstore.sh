#!/bin/zsh
# Mac App Store archive + upload. Needs the paid Developer Program on the personal
# team (7XVA74UJHL), an App Store Connect record for com.phierru.SnapRescale, and
# Xcode signed in to the Apple ID (Xcode ▸ Settings ▸ Accounts).
#
#   Scripts/appstore.sh            # archive + validate
#   UPLOAD=1 Scripts/appstore.sh   # archive + upload to App Store Connect
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT="$ROOT/build/appstore"; rm -rf "$OUT"; mkdir -p "$OUT"
[ -f SnapRescale/AppIcon.icns ] || Scripts/make-icns.sh >/dev/null
xcodegen generate --quiet
xcodebuild -project SnapRescale.xcodeproj -scheme SnapRescale -configuration Release \
  -archivePath "$OUT/SnapRescale.xcarchive" -quiet \
  CODE_SIGN_IDENTITY="Apple Distribution" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=7XVA74UJHL \
  -allowProvisioningUpdates archive
cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>7XVA74UJHL</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/SnapRescale.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet
PKG=$(ls "$OUT"/export/*.pkg | head -1)
if [ -n "${UPLOAD:-}" ]; then
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey "${ASC_KEY_ID:?set ASC_KEY_ID}" --apiIssuer "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
else
  xcrun altool --validate-app -f "$PKG" -t macos --apiKey "${ASC_KEY_ID:?set ASC_KEY_ID}" --apiIssuer "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
fi
echo "package: $PKG"
