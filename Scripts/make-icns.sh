#!/bin/zsh
# Rasterise the flat icon into AppIcon.icns (dev build, older-OS fallback) and
# fill the asset catalog's AppIcon set. The Liquid Glass icon is AppIcon.icon.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/SnapRescale/IconSource/AppIcon-flat.svg"
SET="$ROOT/SnapRescale/AppIcon.iconset"
CAT="$ROOT/SnapRescale/Assets.xcassets/AppIcon.appiconset"
rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s "$SRC" -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) "$SRC" -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$ROOT/SnapRescale/AppIcon.icns"
for s in 16 32 128 256 512; do
  cp "$SET/icon_${s}x${s}.png" "$CAT/icon_${s}x${s}.png"
  cp "$SET/icon_${s}x${s}@2x.png" "$CAT/icon_${s}x${s}@2x.png"
done
python3 - "$CAT" <<'PY'
import json, sys, os
cat = sys.argv[1]
images = []
for s in (16, 32, 128, 256, 512):
    images.append({"idiom": "mac", "scale": "1x", "size": f"{s}x{s}", "filename": f"icon_{s}x{s}.png"})
    images.append({"idiom": "mac", "scale": "2x", "size": f"{s}x{s}", "filename": f"icon_{s}x{s}@2x.png"})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(cat, "Contents.json"), "w"), indent=2)
PY
rm -rf "$SET"
echo "wrote $ROOT/SnapRescale/AppIcon.icns and the AppIcon asset set"
