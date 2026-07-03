"""RigPort sidebar panel. The panel is the wizard: run the steps top to bottom."""

import bpy

from . import contracts

_STATUS_ICON = {"PASS": "CHECKMARK", "WARN": "ERROR", "FAIL": "CANCEL", "INFO": "INFO"}


class RIGPORT_UL_results(bpy.types.UIList):
    def draw_item(self, context, layout, data, item, icon, active_data, active_propname):
        layout.label(text=item.message, icon=_STATUS_ICON.get(item.status, "DOT"))


class RIGPORT_PT_main(bpy.types.Panel):
    bl_label = "RigPort"
    bl_idname = "RIGPORT_PT_main"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "RigPort"

    def draw(self, context):
        layout = self.layout
        rp = context.scene.rigport

        col = layout.column()
        col.label(text="Rig it. Test it. Ship it to Godot.", icon="ARMATURE_DATA")
        col.prop(rp, "preset")

        box = layout.box()
        box.label(text="1. Prepare", icon="MESH_DATA")
        box.operator("rigport.prep_meshes")

        box = layout.box()
        box.label(text="2. Fit Skeleton Markers", icon="EMPTY_AXIS")
        row = box.row(align=True)
        row.operator("rigport.auto_markers")
        row.operator("rigport.mirror_markers", text="Mirror L>R")

        box = layout.box()
        box.label(text="3. Rig + Skin", icon="OUTLINER_OB_ARMATURE")
        box.operator("rigport.generate_rig")
        box.operator("rigport.auto_skin")

        box = layout.box()
        box.label(text="4. Gameplay Sockets", icon="EMPTY_ARROWS")
        box.prop(rp, "include_optional_sockets")
        box.operator("rigport.add_sockets")

        box = layout.box()
        box.label(text="5. VO Mouth", icon="OUTLINER_DATA_SPEAKER")
        box.prop(rp, "create_visemes")
        box.operator("rigport.create_mouth_shapes")
        row = box.row(align=True)
        op = row.operator("rigport.preview_mouth", text="Preview Flap")
        op.mode = "FLAP"
        op = row.operator("rigport.preview_mouth", text="Viseme Cycle")
        op.mode = "VISEME"

        box = layout.box()
        box.label(text="6. Pose Tests", icon="POSE_HLT")
        box.operator("rigport.add_test_poses")

        box = layout.box()
        box.label(text="7. Damage Reactions", icon="FORCE_FORCE")
        box.prop(rp, "hitreact_enabled")
        if rp.hitreact_enabled:
            box.prop(rp, "hitreact_include_limbs")
            box.operator("rigport.generate_hitreact_profile")
            row = box.row(align=True)
            row.prop(rp, "hitreact_preview_zone", text="")
            row.prop(rp, "hitreact_preview_direction", text="")
            row = box.row(align=True)
            row.prop(rp, "hitreact_impulse_class", text="")
            row.prop(rp, "hitreact_seed")
            box.operator("rigport.preview_hitreact")
            box.operator("rigport.generate_hitreact_clips")
            box.operator("rigport.validate_hitreact_clips")
            box.operator("rigport.validate_hitreact")
            box.prop(rp, "hitreact_export_path")
            box.operator("rigport.export_hitreact_profile")

        box = layout.box()
        box.label(text="8. Validate + Export", icon="EXPORT")
        box.operator("rigport.validate")
        box.prop(rp, "export_path")
        row = box.row(align=True)
        row.prop(rp, "export_animations")
        row.prop(rp, "export_apply_modifiers")
        box.operator("rigport.export_glb")

        if rp.results:
            box = layout.box()
            box.label(text="Results", icon="PRESET")
            box.template_list("RIGPORT_UL_results", "", rp, "results", rp, "results_index", rows=6)


CLASSES = (RIGPORT_UL_results, RIGPORT_PT_main)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
