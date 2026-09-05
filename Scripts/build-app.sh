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
cp Info.plist "$APP/Contents/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "built $APP"
