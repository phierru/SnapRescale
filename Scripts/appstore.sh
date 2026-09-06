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
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=7XVA74UJHL \
  -allowProvisioningUpdates archive
# destination "upload" validates and uploads through the Apple ID Xcode is
# signed in with — no API key needed. Without UPLOAD it only exports the .pkg.
DEST=$([ -n "${UPLOAD:-}" ] && echo upload || echo export)
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>7XVA74UJHL</string>
  <key>destination</key><string>$DEST</string>
  <key>uploadSymbols</key><true/>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/SnapRescale.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates 2>&1 | grep -v -E "^\s*$" | tail -15
[ "$DEST" = upload ] && echo "uploaded to App Store Connect — it appears under the app's Builds after processing (a few minutes)" || echo "package exported to $OUT/export"
