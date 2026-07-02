#!/bin/sh
# Copy the canonical contracts into both add-ons. Run after editing contracts/.
set -e
cd "$(dirname "$0")/.."
cp contracts/*.json blender_addon/rigport/contracts/
cp contracts/*.json godot_addon/addons/rigport/contracts/
echo "Contracts synced."
