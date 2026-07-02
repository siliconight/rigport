"""Load the RigPort JSON data contracts and define the marker layout.

The JSON files in ./contracts are the single source of truth shared with the
Godot add-on. Keep them byte-identical across both add-ons.
"""

import json
import os

_DIR = os.path.join(os.path.dirname(__file__), "contracts")


def _load(filename):
    with open(os.path.join(_DIR, filename), "r", encoding="utf-8") as f:
        return json.load(f)


BONES = _load("bone_contract.json")
SOCKETS = _load("socket_contract.json")
MOUTH = _load("mouth_shape_contract.json")
MOUTH_LOD = _load("mouth_lod_contract.json")
PRESETS = _load("presets.json")["presets"]

MARKER_PREFIX = "RP_"
MARKER_COLLECTION = "RigPort Markers"
RIG_NAME = "RigPort_Rig"
TEST_POSE_ACTION = "RigPort_TestPoses"

# Marker layout as fractions of character height, character facing -Y,
# character's left = +X (Blender convention that maps to Godot -Z forward
# through the glTF exporter's +Y-up conversion).
# name: (x_frac, y_frac, z_frac)
MARKER_LAYOUT = {
    "Root": (0.0, 0.0, 0.0),
    "Hips": (0.0, 0.0, 0.530),
    "Spine": (0.0, 0.0, 0.620),
    "Chest": (0.0, 0.0, 0.730),
    "Neck": (0.0, 0.0, 0.860),
    "Head": (0.0, 0.0, 0.910),
    "LeftShoulder": (0.090, 0.0, 0.835),
    "LeftElbow": (0.240, 0.0, 0.835),
    "LeftWrist": (0.380, 0.0, 0.835),
    "LeftHand": (0.435, 0.0, 0.835),
    "RightShoulder": (-0.090, 0.0, 0.835),
    "RightElbow": (-0.240, 0.0, 0.835),
    "RightWrist": (-0.380, 0.0, 0.835),
    "RightHand": (-0.435, 0.0, 0.835),
    "LeftKnee": (0.060, 0.0, 0.280),
    "LeftAnkle": (0.065, 0.0, 0.060),
    "LeftFoot": (0.065, -0.100, 0.020),
    "RightKnee": (-0.060, 0.0, 0.280),
    "RightAnkle": (-0.065, 0.0, 0.060),
    "RightFoot": (-0.065, -0.100, 0.020),
}

CENTERLINE_MARKERS = ("Root", "Hips", "Spine", "Chest", "Neck", "Head")

# Deform bones whose vertex groups must carry weight after auto-skin.
KEY_DEFORM_BONES = (
    "Hips", "Spine", "Chest", "Head",
    "LeftUpperArm", "LeftHand", "RightUpperArm", "RightHand",
    "LeftUpperLeg", "LeftFoot", "RightUpperLeg", "RightFoot",
)


def preset(preset_id):
    return PRESETS[preset_id]


def preset_items():
    """EnumProperty items, stable order."""
    return [(pid, p["name"], p["name"]) for pid, p in PRESETS.items()]


def required_bones(preset_id):
    p = PRESETS[preset_id]
    return list(p.get("required_bones_override", BONES["required_bones"]))


def required_sockets(preset_id):
    return list(PRESETS[preset_id].get("required_sockets", []))


def recommended_sockets(preset_id):
    return list(PRESETS[preset_id].get("recommended_sockets", []))


def socket_parent(socket_name):
    return SOCKETS["socket_parents"].get(socket_name)


def lod_entry(lod):
    for entry in MOUTH_LOD["lods"]:
        if entry["lod"] == lod:
            return entry
    return None
