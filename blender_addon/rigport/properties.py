"""Scene-level RigPort state: chosen preset, export options, validation results."""

import bpy

from . import contracts


def _preset_enum_items(self, context):
    # Keep a module-level reference: Blender requires enum item strings to stay alive.
    global _PRESET_ITEMS
    _PRESET_ITEMS = contracts.preset_items()
    return _PRESET_ITEMS


_PRESET_ITEMS = []

STATUS_ITEMS = [
    ("PASS", "Pass", "", "CHECKMARK", 0),
    ("WARN", "Warn", "", "ERROR", 1),
    ("FAIL", "Fail", "", "CANCEL", 2),
    ("INFO", "Info", "", "INFO", 3),
]


class RigPortResult(bpy.types.PropertyGroup):
    status: bpy.props.EnumProperty(items=STATUS_ITEMS, default="INFO")
    message: bpy.props.StringProperty(default="")


class RigPortSettings(bpy.types.PropertyGroup):
    preset: bpy.props.EnumProperty(
        name="Character Type",
        description="Character preset. Defines required bones, sockets, and VO mouth support",
        items=_preset_enum_items,
    )
    character_height: bpy.props.FloatProperty(
        name="Character Height",
        description="Measured height of the selected meshes, set by Prepare Selected Meshes",
        default=1.8,
        min=0.01,
        unit="LENGTH",
    )
    create_visemes: bpy.props.BoolProperty(
        name="Include Viseme Shapes",
        description="Also create the seven recommended viseme shape keys (needed for Mouth LOD 0 / Mission NPCs)",
        default=False,
    )
    include_optional_sockets: bpy.props.BoolProperty(
        name="Include Recommended Sockets",
        description="Also add the preset's recommended (non-required) sockets",
        default=True,
    )
    export_path: bpy.props.StringProperty(
        name="GLB Path",
        description="Output GLB path. Use a versioned name, e.g. player_michael_v001.glb",
        subtype="FILE_PATH",
        default="//export/character_v001.glb",
    )
    export_animations: bpy.props.BoolProperty(
        name="Include Animations",
        description="Export actions (including RigPort test poses) with the character",
        default=False,
    )
    export_apply_modifiers: bpy.props.BoolProperty(
        name="Apply Modifiers",
        description=(
            "Apply non-armature modifiers on export. Leave off for meshes with "
            "shape keys: the glTF exporter cannot apply modifiers to shape-keyed meshes"
        ),
        default=False,
    )
    hitreact_enabled: bpy.props.BoolProperty(
        name="Enable HitReact",
        description="Generate procedural gunshot hit reaction data for this character",
        default=False,
    )
    hitreact_include_limbs: bpy.props.BoolProperty(
        name="Include Optional Limb Zones",
        description="Also generate arm and leg hit zones (head/chest/pelvis are always included)",
        default=False,
    )
    hitreact_preview_zone: bpy.props.EnumProperty(
        name="Zone",
        description="Hit zone to preview",
        items=[
            ("head", "Head", ""), ("chest", "Chest", ""), ("pelvis", "Pelvis", ""),
            ("left_arm", "Left Arm", ""), ("right_arm", "Right Arm", ""),
            ("left_leg", "Left Leg", ""), ("right_leg", "Right Leg", ""),
        ],
        default="chest",
    )
    hitreact_preview_direction: bpy.props.EnumProperty(
        name="Direction",
        description="Incoming hit direction to preview (the body moves away from it)",
        items=[
            ("front", "Front", ""), ("back", "Back", ""),
            ("left", "Left", ""), ("right", "Right", ""),
            ("front_left", "Front-Left", ""), ("front_right", "Front-Right", ""),
            ("back_left", "Back-Left", ""), ("back_right", "Back-Right", ""),
        ],
        default="front",
    )
    hitreact_impulse_class: bpy.props.EnumProperty(
        name="Impulse",
        description="Impulse class to preview",
        items=[("small", "Small", ""), ("medium", "Medium", ""), ("heavy", "Heavy", "")],
        default="medium",
    )
    hitreact_seed: bpy.props.IntProperty(
        name="Seed",
        description="Variation seed. Same seed reproduces the same reaction (preview re-seeds each loop from here)",
        default=0,
        min=0,
        max=9999,
    )
    hitreact_export_path: bpy.props.StringProperty(
        name="Profile Path",
        description="Output .hitreact.json path. Keep it next to the GLB with the same versioned base name",
        subtype="FILE_PATH",
        default="//export/character_v001.hitreact.json",
    )
    results: bpy.props.CollectionProperty(type=RigPortResult)
    results_index: bpy.props.IntProperty(default=0)


def clear_results(scene):
    scene.rigport.results.clear()


def add_result(scene, status, message):
    item = scene.rigport.results.add()
    item.status = status
    item.message = message


CLASSES = (RigPortResult, RigPortSettings)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    bpy.types.Scene.rigport = bpy.props.PointerProperty(type=RigPortSettings)


def unregister():
    del bpy.types.Scene.rigport
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
