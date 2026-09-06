#!/bin/zsh
# Store-style build: Xcode project (from project.yml), sandboxed, hardened runtime.
# Output: build/xcode/SnapRescale.app. Use Scripts/build-app.sh for the fast,
# unsandboxed dev build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${1:-Debug}
cd "$ROOT"
[ -f SnapRescale/AppIcon.icns ] || Scripts/make-icns.sh >/dev/null   # fills the catalog's AppIcon set too
xcodegen generate --quiet
xcodebuild -project SnapRescale.xcodeproj -scheme SnapRescale -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -quiet build
APP="$ROOT/build/xcode/SnapRescale.app"
rm -rf "$APP"; mkdir -p "$ROOT/build/xcode"
cp -R "build/DerivedData/Build/Products/$CONFIG/SnapRescale.app" "$APP"
codesign -dv --entitlements - "$APP" 2>&1 | grep -E "app-sandbox|user-selected" | sed 's/^/  /'
echo "built $APP"
