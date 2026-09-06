#!/bin/zsh
# Build SnapRescale.app from the SwiftPM executable. Ad-hoc signed; no Xcode project needed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${1:-release}
cd "$ROOT/SnapRescale"
swift build -c "$CONFIG" --disable-build-manifest-caching
APP="$ROOT/build/SnapRescale.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/SnapRescale" "$APP/Contents/MacOS/"
sed -e 's/\$(MARKETING_VERSION)/1.0/' -e 's/\$(CURRENT_PROJECT_VERSION)/1/' Info.plist > "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] || "$ROOT/Scripts/make-icns.sh" >/dev/null
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
/System/Library/CoreServices/pbs -update 2>/dev/null || true   # refresh the Services menu
echo "built $APP"
