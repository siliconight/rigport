#!/bin/sh
# Build the installable Blender add-on zip (rigport/ folder at zip root).
set -e
cd "$(dirname "$0")/../blender_addon"
rm -f ../rigport_blender_addon.zip
zip -qr ../rigport_blender_addon.zip rigport -x "*__pycache__*"
echo "Wrote rigport_blender_addon.zip"
