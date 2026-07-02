"""RigPort Blender operators.

Workflow order (mirrors the wizard):
  prep -> markers -> mirror -> rig -> skin -> sockets -> mouth -> poses -> validate -> export
"""

import math
import os

import bpy
from mathutils import Vector

from . import contracts
from .properties import add_result, clear_results

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _selected_meshes(context):
    return [o for o in context.selected_objects if o.type == "MESH"]


def _world_bounds(objects):
    """Combined world-space AABB of the given objects. Returns (min, max) or None."""
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    found = False
    for obj in objects:
        for corner in obj.bound_box:
            p = obj.matrix_world @ Vector(corner)
            lo = Vector(map(min, lo, p))
            hi = Vector(map(max, hi, p))
            found = True
    return (lo, hi) if found else None


def _marker_name(name):
    return contracts.MARKER_PREFIX + name


def _marker_collection(context, create=False):
    coll = bpy.data.collections.get(contracts.MARKER_COLLECTION)
    if coll is None and create:
        coll = bpy.data.collections.new(contracts.MARKER_COLLECTION)
        context.scene.collection.children.link(coll)
    return coll


def _marker(name):
    return bpy.data.objects.get(_marker_name(name))


def _marker_pos(name):
    obj = _marker(name)
    return obj.matrix_world.translation.copy() if obj else None


def _find_rig(context):
    rig = bpy.data.objects.get(contracts.RIG_NAME)
    if rig and rig.type == "ARMATURE":
        return rig
    if context.active_object and context.active_object.type == "ARMATURE":
        return context.active_object
    return None


def _bound_meshes(rig):
    out = []
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        for mod in obj.modifiers:
            if mod.type == "ARMATURE" and mod.object == rig:
                out.append(obj)
                break
    return out


def _ensure_object_mode(context):
    if context.mode != "OBJECT" and context.active_object:
        bpy.ops.object.mode_set(mode="OBJECT")


def _shape_keys(mesh_obj):
    sk = mesh_obj.data.shape_keys
    return sk.key_blocks if sk else None


def _mouth_mesh(rig):
    """First mesh bound to the rig that carries a RigPort mouth shape key."""
    names = set(contracts.MOUTH["required_mvp_shapes"]) | set(contracts.MOUTH["recommended_visemes"])
    for obj in _bound_meshes(rig):
        keys = _shape_keys(obj)
        if keys and any(n in keys for n in names):
            return obj
    return None


# --------------------------------------------------------------------------
# Step 1: prep
# --------------------------------------------------------------------------


class RIGPORT_OT_prep_meshes(bpy.types.Operator):
    """Check selected meshes for common import problems before rigging"""

    bl_idname = "rigport.prep_meshes"
    bl_label = "Prepare Selected Meshes"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        scene = context.scene
        clear_results(scene)
        meshes = _selected_meshes(context)
        if not meshes:
            add_result(scene, "FAIL", "No mesh objects selected.")
            return {"CANCELLED"}

        bounds = _world_bounds(meshes)
        lo, hi = bounds
        size = hi - lo
        height = size.z
        scene.rigport.character_height = max(height, 0.01)

        if height <= 0.001:
            add_result(scene, "FAIL", "Selection has no vertical extent — is the mesh visible?")
            return {"CANCELLED"}
        if height < 0.3:
            add_result(scene, "WARN", f"Character is only {height:.2f}m tall. Model may be at the wrong scale.")
        elif height > 4.0:
            add_result(scene, "WARN", f"Character is {height:.1f}m tall. Model may be at the wrong scale.")
        else:
            add_result(scene, "PASS", f"Character height {height:.2f}m looks plausible.")

        center = (lo + hi) * 0.5
        if Vector((center.x, center.y, 0.0)).length > height * 0.5:
            add_result(scene, "WARN", "Mesh is far from the world origin. Consider recentering.")
        if abs(lo.z) > height * 0.1:
            add_result(scene, "WARN", f"Feet are {lo.z:.2f}m from the ground plane (Z=0).")

        for obj in meshes:
            if any(abs(s - 1.0) > 1e-4 for s in obj.scale):
                add_result(scene, "WARN", f"'{obj.name}' has unapplied scale. Apply it (Ctrl+A) before rigging.")
            if any(abs(r) > 1e-4 for r in obj.rotation_euler):
                add_result(scene, "WARN", f"'{obj.name}' has unapplied rotation. Apply it (Ctrl+A) before rigging.")

        add_result(scene, "INFO", "Expected orientation: upright, facing -Y, in T- or A-pose.")
        add_result(scene, "PASS", f"Prep check finished on {len(meshes)} mesh object(s).")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 2/3: markers
# --------------------------------------------------------------------------


class RIGPORT_OT_auto_markers(bpy.types.Operator):
    """Auto-place skeleton fit markers from the bounds of the selected meshes"""

    bl_idname = "rigport.auto_markers"
    bl_label = "Auto-Place Markers"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        meshes = _selected_meshes(context)
        if not meshes:
            self.report({"ERROR"}, "Select the character meshes first.")
            return {"CANCELLED"}

        lo, hi = _world_bounds(meshes)
        height = hi.z - lo.z
        if height <= 0.001:
            self.report({"ERROR"}, "Selection has no height.")
            return {"CANCELLED"}
        context.scene.rigport.character_height = height
        cx = (lo.x + hi.x) * 0.5
        cy = (lo.y + hi.y) * 0.5
        base_z = lo.z

        coll = _marker_collection(context, create=True)
        for name, (xf, yf, zf) in contracts.MARKER_LAYOUT.items():
            mname = _marker_name(name)
            obj = bpy.data.objects.get(mname)
            if obj is None:
                obj = bpy.data.objects.new(mname, None)
                coll.objects.link(obj)
            obj.empty_display_type = "SPHERE" if name in contracts.CENTERLINE_MARKERS else "PLAIN_AXES"
            obj.empty_display_size = height * 0.02
            obj.location = (cx + xf * height, cy + yf * height, base_z + zf * height)
            obj.show_in_front = True
            if name in contracts.CENTERLINE_MARKERS:
                obj.lock_location[0] = True  # lock centerline to the X of auto-placement
        self.report({"INFO"}, "Markers placed. Drag them to match the character, then generate the rig.")
        return {"FINISHED"}


class RIGPORT_OT_mirror_markers(bpy.types.Operator):
    """Mirror the Left-side markers onto the Right side across the Root marker"""

    bl_idname = "rigport.mirror_markers"
    bl_label = "Mirror Markers (L to R)"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        root = _marker("Root")
        if root is None:
            self.report({"ERROR"}, "No markers found. Run Auto-Place Markers first.")
            return {"CANCELLED"}
        cx = root.location.x
        count = 0
        for name in contracts.MARKER_LAYOUT:
            if not name.startswith("Left"):
                continue
            left = _marker(name)
            right = _marker("Right" + name[4:])
            if left and right:
                right.location = (2.0 * cx - left.location.x, left.location.y, left.location.z)
                count += 1
        self.report({"INFO"}, f"Mirrored {count} markers.")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 4: rig generation
# --------------------------------------------------------------------------


class RIGPORT_OT_generate_rig(bpy.types.Operator):
    """Generate the game export rig from the fitted markers"""

    bl_idname = "rigport.generate_rig"
    bl_label = "Generate Game Export Rig"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        needed = [n for n in contracts.MARKER_LAYOUT if _marker(n) is None]
        if needed:
            self.report({"ERROR"}, f"Missing markers: {', '.join(needed[:5])}… Run Auto-Place Markers.")
            return {"CANCELLED"}

        _ensure_object_mode(context)
        h = context.scene.rigport.character_height

        old = bpy.data.objects.get(contracts.RIG_NAME)
        if old is not None:
            bpy.data.objects.remove(old, do_unlink=True)

        arm = bpy.data.armatures.new(contracts.RIG_NAME)
        rig = bpy.data.objects.new(contracts.RIG_NAME, arm)
        context.scene.collection.objects.link(rig)
        rig.show_in_front = True
        arm.display_type = "OCTAHEDRAL"

        for obj in context.selected_objects:
            obj.select_set(False)
        context.view_layer.objects.active = rig
        rig.select_set(True)
        bpy.ops.object.mode_set(mode="EDIT")
        eb = arm.edit_bones

        m = {name: _marker_pos(name) for name in contracts.MARKER_LAYOUT}

        def bone(name, head, tail, parent=None, connect=False, deform=True):
            b = eb.new(name)
            b.head, b.tail = head, tail
            b.use_deform = deform
            if parent is not None:
                b.parent = eb[parent]
                b.use_connect = connect
            return b

        root_head = Vector((m["Root"].x, m["Root"].y, 0.0))
        bone("Root", root_head, root_head + Vector((0, 0.18 * h, 0)), deform=False)
        bone("Hips", m["Hips"], m["Spine"], parent="Root")
        bone("Spine", m["Spine"], m["Chest"], parent="Hips", connect=True)
        bone("Chest", m["Chest"], m["Neck"], parent="Spine", connect=True)
        bone("Neck", m["Neck"], m["Head"], parent="Chest", connect=True)
        bone("Head", m["Head"], m["Head"] + Vector((0, 0, 0.10 * h)), parent="Neck", connect=True)

        for side in ("Left", "Right"):
            bone(f"{side}UpperArm", m[f"{side}Shoulder"], m[f"{side}Elbow"], parent="Chest")
            bone(f"{side}LowerArm", m[f"{side}Elbow"], m[f"{side}Wrist"], parent=f"{side}UpperArm", connect=True)
            bone(f"{side}Hand", m[f"{side}Wrist"], m[f"{side}Hand"], parent=f"{side}LowerArm", connect=True)

            up_head = Vector((m[f"{side}Knee"].x, m["Hips"].y, m["Hips"].z * 0.97))
            bone(f"{side}UpperLeg", up_head, m[f"{side}Knee"], parent="Hips")
            bone(f"{side}LowerLeg", m[f"{side}Knee"], m[f"{side}Ankle"], parent=f"{side}UpperLeg", connect=True)
            bone(f"{side}Foot", m[f"{side}Ankle"], m[f"{side}Foot"], parent=f"{side}LowerLeg", connect=True)

        bpy.ops.object.mode_set(mode="OBJECT")
        self.report({"INFO"}, "Game export rig generated. Review bone placement, then Auto-Skin.")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 5: auto-skin
# --------------------------------------------------------------------------


class RIGPORT_OT_auto_skin(bpy.types.Operator):
    """Parent the selected meshes to the RigPort rig with automatic weights.
    Automatic weights are a first pass — inspect deformation before final art approval"""

    bl_idname = "rigport.auto_skin"
    bl_label = "Auto-Skin Selected Meshes"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        scene = context.scene
        rig = _find_rig(context)
        meshes = _selected_meshes(context)
        if rig is None:
            self.report({"ERROR"}, "No RigPort rig found. Generate the rig first.")
            return {"CANCELLED"}
        if not meshes:
            self.report({"ERROR"}, "Select the character meshes to skin.")
            return {"CANCELLED"}

        _ensure_object_mode(context)
        for obj in context.selected_objects:
            obj.select_set(False)
        for obj in meshes:
            obj.select_set(True)
        rig.select_set(True)
        context.view_layer.objects.active = rig
        try:
            bpy.ops.object.parent_set(type="ARMATURE_AUTO")
        except RuntimeError as exc:
            self.report({"ERROR"}, f"Automatic weights failed: {exc}")
            return {"CANCELLED"}

        clear_results(scene)
        for obj in meshes:
            used = set()
            for v in obj.data.vertices:
                for g in v.groups:
                    if g.weight > 1e-4:
                        used.add(g.group)
            weighted = {obj.vertex_groups[i].name for i in used if i < len(obj.vertex_groups)}
            missing = [b for b in contracts.KEY_DEFORM_BONES if b in rig.data.bones and b not in weighted]
            if missing:
                add_result(scene, "WARN", f"'{obj.name}': no weights on {', '.join(missing)}.")
            unweighted = len(obj.data.vertices) - sum(
                1 for v in obj.data.vertices if any(g.weight > 1e-4 for g in v.groups)
            )
            if unweighted:
                add_result(scene, "WARN", f"'{obj.name}': {unweighted} vertices carry no weight.")
        add_result(scene, "INFO", "Automatic weights are a first pass. Inspect and clean up deformation before final art approval.")
        add_result(scene, "PASS", f"Skinned {len(meshes)} mesh object(s) to {rig.name}.")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 6: gameplay sockets
# --------------------------------------------------------------------------


def _socket_offset(name, m, h):
    """World position for a socket, given marker positions m and height h."""
    parents = {
        "WeaponSocket_R": m["RightHand"],
        "WeaponSocket_L": m["LeftHand"],
        "ThrowableSocket_R": m["RightHand"],
        "ThrowableSocket_L": m["LeftHand"],
        "RightHandCosmeticSocket": m["RightHand"],
        "LeftHandCosmeticSocket": m["LeftHand"],
        "BackWeaponSocket": m["Chest"] + Vector((0, 0.14 * h, 0.02 * h)),
        "BackpackSocket": m["Chest"] + Vector((0, 0.15 * h, -0.02 * h)),
        "ChestCosmeticSocket": m["Chest"] + Vector((0, -0.10 * h, 0)),
        "HeadCosmeticSocket": m["Head"] + Vector((0, 0, 0.10 * h)),
        "MaskSocket": m["Head"] + Vector((0, -0.09 * h, 0.03 * h)),
        "HatSocket": m["Head"] + Vector((0, 0, 0.11 * h)),
        "HairSocket": m["Head"] + Vector((0, 0, 0.09 * h)),
        "GlassesSocket": m["Head"] + Vector((0, -0.09 * h, 0.05 * h)),
        "CameraAnchor_FP": m["Head"] + Vector((0, -0.10 * h, 0.03 * h)),
        "CameraAnchor_TP": Vector((m["Root"].x, m["Root"].y + 0.9 * h, 0.85 * h)),
        "LeftFootstepSocket": Vector((m["LeftFoot"].x, m["LeftFoot"].y, 0.0)),
        "RightFootstepSocket": Vector((m["RightFoot"].x, m["RightFoot"].y, 0.0)),
        "Hitbox_Head": m["Head"] + Vector((0, 0, 0.05 * h)),
        "Hitbox_Chest": m["Chest"],
        "Hitbox_Pelvis": m["Hips"],
        "HolsterSocket_R": Vector((m["RightKnee"].x * 1.6, m["Hips"].y, m["Hips"].z * 0.92)),
        "HolsterSocket_L": Vector((m["LeftKnee"].x * 1.6, m["Hips"].y, m["Hips"].z * 0.92)),
        "MuzzleSocket": m["RightHand"] + Vector((0, -0.20 * h, 0)),
    }
    return parents.get(name)


class RIGPORT_OT_add_sockets(bpy.types.Operator):
    """Add the preset's gameplay sockets as non-deforming bones on the rig"""

    bl_idname = "rigport.add_sockets"
    bl_label = "Add Gameplay Sockets"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        scene = context.scene
        rig = _find_rig(context)
        if rig is None:
            self.report({"ERROR"}, "No RigPort rig found. Generate the rig first.")
            return {"CANCELLED"}

        pid = scene.rigport.preset
        wanted = contracts.required_sockets(pid)
        if scene.rigport.include_optional_sockets:
            wanted += [s for s in contracts.recommended_sockets(pid) if s not in wanted]
        if not wanted:
            self.report({"INFO"}, "This preset requires no sockets.")
            return {"FINISHED"}

        m = {name: _marker_pos(name) for name in contracts.MARKER_LAYOUT}
        if any(v is None for v in m.values()):
            # Markers were deleted after rig generation — rebuild positions from bones.
            fallback = {
                "Root": ("Root", "head"), "Hips": ("Hips", "head"), "Spine": ("Spine", "head"),
                "Chest": ("Chest", "head"), "Neck": ("Neck", "head"), "Head": ("Head", "head"),
                "LeftShoulder": ("LeftUpperArm", "head"), "LeftElbow": ("LeftLowerArm", "head"),
                "LeftWrist": ("LeftHand", "head"), "LeftHand": ("LeftHand", "tail"),
                "RightShoulder": ("RightUpperArm", "head"), "RightElbow": ("RightLowerArm", "head"),
                "RightWrist": ("RightHand", "head"), "RightHand": ("RightHand", "tail"),
                "LeftKnee": ("LeftLowerLeg", "head"), "LeftAnkle": ("LeftFoot", "head"),
                "LeftFoot": ("LeftFoot", "tail"),
                "RightKnee": ("RightLowerLeg", "head"), "RightAnkle": ("RightFoot", "head"),
                "RightFoot": ("RightFoot", "tail"),
            }
            for name in contracts.MARKER_LAYOUT:
                if m[name] is not None:
                    continue
                bname, end = fallback[name]
                b = rig.data.bones.get(bname)
                if b is not None:
                    local = b.head_local if end == "head" else b.tail_local
                    m[name] = rig.matrix_world @ local
            if any(v is None for v in m.values()):
                self.report({"ERROR"}, "Markers are gone and bones can't substitute. Re-run Auto-Place Markers.")
                return {"CANCELLED"}

        h = scene.rigport.character_height
        _ensure_object_mode(context)
        context.view_layer.objects.active = rig
        rig.select_set(True)
        bpy.ops.object.mode_set(mode="EDIT")
        eb = rig.data.edit_bones

        created, pending = [], list(wanted)
        for _ in range(3):  # resolve dependency order (MuzzleSocket -> WeaponSocket_R)
            for name in list(pending):
                parent = contracts.socket_parent(name)
                if parent is None or parent not in eb:
                    continue
                pending.remove(name)
                if name in eb:
                    continue
                pos = _socket_offset(name, m, h)
                if pos is None:
                    continue
                b = eb.new(name)
                b.head = pos
                b.tail = pos + Vector((0, -0.05 * h, 0))
                b.parent = eb[parent]
                b.use_deform = False
                created.append(name)
            if not pending:
                break

        bpy.ops.object.mode_set(mode="OBJECT")
        if pending:
            self.report({"WARNING"}, f"Could not place: {', '.join(pending)} (missing parent bone).")
        self.report({"INFO"}, f"Added {len(created)} socket(s) for preset '{contracts.preset(pid)['name']}'.")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 7: VO mouth shapes
# --------------------------------------------------------------------------


class RIGPORT_OT_create_mouth_shapes(bpy.types.Operator):
    """Create the RigPort mouth shape keys on the active mesh (sculpt each one afterwards).
    Skip this step for characters that never speak"""

    bl_idname = "rigport.create_mouth_shapes"
    bl_label = "Create Mouth Shape Keys"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        obj = context.active_object
        if obj is None or obj.type != "MESH":
            self.report({"ERROR"}, "Make the head/face mesh the active object first.")
            return {"CANCELLED"}

        if obj.data.shape_keys is None:
            obj.shape_key_add(name="Basis", from_mix=False)

        names = list(contracts.MOUTH["required_mvp_shapes"])
        if context.scene.rigport.create_visemes:
            names += contracts.MOUTH["recommended_visemes"]

        keys = obj.data.shape_keys.key_blocks
        added = [n for n in names if n not in keys]
        for n in added:
            obj.shape_key_add(name=n, from_mix=False)

        skipped = len(names) - len(added)
        msg = f"Added {len(added)} shape key(s) on '{obj.name}'"
        if skipped:
            msg += f" ({skipped} already existed)"
        self.report({"INFO"}, msg + ". Sculpt each key — they start as copies of Basis.")
        return {"FINISHED"}


class RIGPORT_OT_preview_mouth(bpy.types.Operator):
    """Preview mouth movement on the active mesh (Esc or right-click to stop)"""

    bl_idname = "rigport.preview_mouth"
    bl_label = "Preview Mouth"
    bl_options = {"REGISTER"}

    mode: bpy.props.EnumProperty(
        items=[
            ("FLAP", "Amplitude Flap", "Oscillate Mouth_Open like gameplay VO"),
            ("VISEME", "Viseme Cycle", "Step through each viseme shape"),
        ],
        default="FLAP",
    )

    _timer = None
    _t = 0.0
    _viseme_idx = 0
    _driven = ()

    def _mesh_keys(self, context):
        obj = context.active_object
        if obj is None or obj.type != "MESH":
            return None
        return _shape_keys(obj)

    def invoke(self, context, event):
        keys = self._mesh_keys(context)
        if keys is None:
            self.report({"ERROR"}, "Active object has no shape keys. Create mouth shapes first.")
            return {"CANCELLED"}
        if self.mode == "FLAP":
            if "Mouth_Open" not in keys:
                self.report({"ERROR"}, "Mouth_Open shape key not found.")
                return {"CANCELLED"}
            self._driven = ("Mouth_Open",)
        else:
            visemes = [n for n in contracts.MOUTH["recommended_visemes"] if n in keys]
            if not visemes:
                self.report({"ERROR"}, "No viseme shape keys found. Enable 'Include Viseme Shapes' and re-create.")
                return {"CANCELLED"}
            self._driven = tuple(visemes)
        self._t = 0.0
        self._viseme_idx = 0
        wm = context.window_manager
        self._timer = wm.event_timer_add(1.0 / 30.0, window=context.window)
        wm.modal_handler_add(self)
        return {"RUNNING_MODAL"}

    def modal(self, context, event):
        keys = self._mesh_keys(context)
        if event.type in {"ESC", "RIGHTMOUSE"} or keys is None:
            return self._finish(context, keys)
        if event.type == "TIMER":
            self._t += 1.0 / 30.0
            if self.mode == "FLAP":
                # Cheap speech-like envelope: fast flap under a slow loudness wave.
                value = abs(math.sin(self._t * 7.3)) * (0.35 + 0.65 * abs(math.sin(self._t * 1.9)))
                keys["Mouth_Open"].value = min(1.0, value)
            else:
                idx = int(self._t / 0.4) % len(self._driven)
                for i, name in enumerate(self._driven):
                    keys[name].value = 1.0 if i == idx else 0.0
            context.area.tag_redraw()
        return {"RUNNING_MODAL"}

    def _finish(self, context, keys):
        if self._timer:
            context.window_manager.event_timer_remove(self._timer)
            self._timer = None
        if keys:
            for name in self._driven:
                keys[name].value = 0.0
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 8: deformation test poses
# --------------------------------------------------------------------------

# Rotations are degrees on pose-bone local XYZ, tuned for the rig this add-on
# generates (T-pose, facing -Y, roll 0). Poses are deliberately aggressive and
# approximate — their job is to expose bad weights, not to look good.
_BODY_POSES = [
    ("Rest Pose", {}),
    ("Arms Forward", {"LeftUpperArm": (0, 0, -90), "RightUpperArm": (0, 0, 90)}),
    ("Arms Up", {"LeftUpperArm": (90, 0, 0), "RightUpperArm": (90, 0, 0)}),
    ("Aim Rifle", {"LeftUpperArm": (0, 0, -70), "RightUpperArm": (0, 0, 70),
                   "LeftLowerArm": (40, 0, 0), "RightLowerArm": (25, 0, 0)}),
    ("Aim Pistol", {"RightUpperArm": (0, 0, 85), "RightLowerArm": (10, 0, 0)}),
    ("Reload", {"LeftUpperArm": (0, 0, -55), "RightUpperArm": (0, 0, 55),
                "LeftLowerArm": (95, 0, 0), "RightLowerArm": (95, 0, 0), "Neck": (25, 0, 0)}),
    ("Crouch", {"HIPS_DROP": 0.26, "Spine": (18, 0, 0),
                "LeftUpperLeg": (-60, 0, 0), "RightUpperLeg": (-60, 0, 0),
                "LeftLowerLeg": (80, 0, 0), "RightLowerLeg": (80, 0, 0)}),
    ("Deep Knee Bend", {"HIPS_DROP": 0.44,
                        "LeftUpperLeg": (-95, 0, 0), "RightUpperLeg": (-95, 0, 0),
                        "LeftLowerLeg": (120, 0, 0), "RightLowerLeg": (120, 0, 0)}),
    ("Torso Twist", {"Spine": (0, 45, 0), "Chest": (0, 25, 0)}),
    ("Head Turn Left", {"Head": (0, 60, 0)}),
    ("Head Turn Right", {"Head": (0, -60, 0)}),
    ("One-Handed Reach", {"RightUpperArm": (0, 0, 80), "Chest": (0, 15, 0)}),
    ("Death Collapse Preview", {"HIPS_DROP": 0.50, "Spine": (35, 0, 0), "Chest": (25, 0, 0),
                                "Neck": (30, 0, 0),
                                "LeftUpperLeg": (-80, 0, 0), "RightUpperLeg": (-40, 0, 0),
                                "LeftLowerLeg": (105, 0, 0), "RightLowerLeg": (60, 0, 0)}),
]

_MOUTH_POSES = [("Mouth Open", "Mouth_Open"), ("Mouth Wide", "Mouth_Wide"), ("Mouth Narrow", "Mouth_Narrow")]
_FRAME_STEP = 10


class RIGPORT_OT_add_test_poses(bpy.types.Operator):
    """Create the RigPort deformation test pose action and timeline markers.
    Scrub the timeline and inspect shoulders, elbows, hips, knees, and the mouth area"""

    bl_idname = "rigport.add_test_poses"
    bl_label = "Add Deformation Test Poses"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        rig = _find_rig(context)
        if rig is None:
            self.report({"ERROR"}, "No RigPort rig found.")
            return {"CANCELLED"}

        _ensure_object_mode(context)
        h = context.scene.rigport.character_height

        old = bpy.data.actions.get(contracts.TEST_POSE_ACTION)
        if old is not None:
            bpy.data.actions.remove(old)
        action = bpy.data.actions.new(contracts.TEST_POSE_ACTION)
        rig.animation_data_create()
        rig.animation_data.action = action

        posed_bones = set()
        for _, spec in _BODY_POSES:
            posed_bones.update(k for k in spec if k != "HIPS_DROP")

        scene = context.scene
        own_names = {n for n, _ in _BODY_POSES} | {n for n, _ in _MOUTH_POSES} | {"Viseme Cycle"}
        for mk in [mk for mk in scene.timeline_markers if mk.name in own_names]:
            scene.timeline_markers.remove(mk)

        frame = 1
        for pose_name, spec in _BODY_POSES:
            for bname in posed_bones | {"Hips"}:
                pb = rig.pose.bones.get(bname)
                if pb is None:
                    continue
                pb.rotation_mode = "XYZ"
                rot = spec.get(bname, (0, 0, 0))
                pb.rotation_euler = tuple(math.radians(a) for a in rot)
                pb.keyframe_insert("rotation_euler", frame=frame)
                if bname == "Hips":
                    drop = spec.get("HIPS_DROP", 0.0) * h
                    pb.location = (0.0, -drop, 0.0)
                    pb.keyframe_insert("location", frame=frame)
            scene.timeline_markers.new(pose_name, frame=frame)
            frame += _FRAME_STEP

        mouth_obj = _mouth_mesh(rig)
        if mouth_obj is not None:
            keys = _shape_keys(mouth_obj)
            mouth_names = [n for _, n in _MOUTH_POSES if n in keys]
            visemes = [n for n in contracts.MOUTH["recommended_visemes"] if n in keys]
            sk = mouth_obj.data.shape_keys

            def key_all(active, at_frame):
                for n in mouth_names + visemes:
                    keys[n].value = 1.0 if n == active else 0.0
                    keys[n].keyframe_insert("value", frame=at_frame)

            for pose_name, shape in _MOUTH_POSES:
                if shape not in keys:
                    continue
                key_all(shape, frame)
                scene.timeline_markers.new(pose_name, frame=frame)
                frame += _FRAME_STEP
            if visemes:
                scene.timeline_markers.new("Viseme Cycle", frame=frame)
                for v in visemes:
                    key_all(v, frame)
                    frame += 4
                key_all(None, frame)
                frame += _FRAME_STEP
            if sk.animation_data and sk.animation_data.action:
                for fc in sk.animation_data.action.fcurves:
                    for kp in fc.keyframe_points:
                        kp.interpolation = "CONSTANT"

        for fc in action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = "CONSTANT"

        scene.frame_start = 1
        scene.frame_end = frame
        scene.frame_set(1)
        self.report({"INFO"}, f"Test poses on frames 1-{frame}. Scrub and inspect joints and seams.")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 9: validation
# --------------------------------------------------------------------------


class RIGPORT_OT_validate(bpy.types.Operator):
    """Validate the rig against the RigPort bone, socket, and mouth contracts"""

    bl_idname = "rigport.validate"
    bl_label = "Validate Blender Rig"
    bl_options = {"REGISTER"}

    def execute(self, context):
        scene = context.scene
        pid = scene.rigport.preset
        p = contracts.preset(pid)
        clear_results(scene)

        rig = _find_rig(context)
        if rig is None:
            add_result(scene, "FAIL", "No RigPort rig in the scene.")
            return {"FINISHED"}

        bones = rig.data.bones
        req = contracts.required_bones(pid)
        missing = [b for b in req if b not in bones]
        if missing:
            add_result(scene, "FAIL", f"Missing required bones: {', '.join(missing)}.")
        else:
            add_result(scene, "PASS", f"All {len(req)} required bones present.")
        if p.get("requires_full_body", True):
            rec_missing = [b for b in contracts.BONES["recommended_bones"] if b not in bones]
            if rec_missing:
                add_result(scene, "WARN", f"Missing recommended bones: {', '.join(rec_missing)}.")

        req_sockets = contracts.required_sockets(pid)
        s_missing = [s for s in req_sockets if s not in bones]
        if s_missing:
            add_result(scene, "FAIL", f"Missing required sockets: {', '.join(s_missing)}.")
        elif req_sockets:
            add_result(scene, "PASS", f"All {len(req_sockets)} required sockets present.")
        rec_s_missing = [s for s in contracts.recommended_sockets(pid) if s not in bones]
        if rec_s_missing:
            add_result(scene, "WARN", f"Missing recommended sockets: {', '.join(rec_s_missing)}.")

        meshes = _bound_meshes(rig)
        if not meshes:
            add_result(scene, "FAIL", "No mesh is bound to the rig. Run Auto-Skin.")
        else:
            add_result(scene, "PASS", f"{len(meshes)} mesh object(s) bound to the rig.")
            for obj in meshes:
                if any(abs(s - 1.0) > 1e-4 for s in obj.scale):
                    add_result(scene, "WARN", f"'{obj.name}' has unapplied scale — apply before export.")

        needs_mouth = p.get("requires_vo_mouth", False)
        wants_mouth = needs_mouth or p.get("recommended_vo_mouth", False)
        if wants_mouth:
            mouth_obj = _mouth_mesh(rig)
            if mouth_obj is None:
                sev = "FAIL" if needs_mouth else "WARN"
                add_result(scene, sev, "No mouth shape keys found on any bound mesh.")
            else:
                keys = _shape_keys(mouth_obj)
                mvp_missing = [n for n in contracts.MOUTH["required_mvp_shapes"] if n not in keys]
                if mvp_missing:
                    sev = "FAIL" if needs_mouth else "WARN"
                    add_result(scene, sev, f"Missing mouth shapes: {', '.join(mvp_missing)}.")
                else:
                    add_result(scene, "PASS", f"MVP mouth shapes present on '{mouth_obj.name}'.")
                vis_missing = [n for n in contracts.MOUTH["recommended_visemes"] if n not in keys]
                if p.get("requires_visemes", False) and vis_missing:
                    add_result(scene, "FAIL", f"Preset requires visemes; missing: {', '.join(vis_missing)}.")
                elif vis_missing and p.get("minimum_mouth_lod", 3) == 0:
                    add_result(scene, "WARN", f"Mouth LOD 0 needs visemes; missing: {', '.join(vis_missing)}.")

        if not any(r.status == "FAIL" for r in scene.rigport.results):
            add_result(scene, "INFO", "Blender-side checks passed. Export the GLB and validate in Godot.")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# Step 10: export
# --------------------------------------------------------------------------


class RIGPORT_OT_export_glb(bpy.types.Operator):
    """Export the rig and bound meshes as a Godot-ready GLB using the RigPort preset"""

    bl_idname = "rigport.export_glb"
    bl_label = "Export Godot GLB"
    bl_options = {"REGISTER"}

    def execute(self, context):
        scene = context.scene
        rig = _find_rig(context)
        if rig is None:
            self.report({"ERROR"}, "No RigPort rig found.")
            return {"CANCELLED"}
        meshes = _bound_meshes(rig)
        if not meshes:
            self.report({"ERROR"}, "No meshes bound to the rig. Run Auto-Skin first.")
            return {"CANCELLED"}

        path = bpy.path.abspath(scene.rigport.export_path)
        if not path.lower().endswith(".glb"):
            path += ".glb"
        os.makedirs(os.path.dirname(path), exist_ok=True)

        _ensure_object_mode(context)
        for obj in context.selected_objects:
            obj.select_set(False)
        rig.select_set(True)
        for obj in meshes:
            obj.select_set(True)
        context.view_layer.objects.active = rig

        try:
            bpy.ops.export_scene.gltf(
                filepath=path,
                export_format="GLB",
                use_selection=True,
                export_yup=True,
                export_apply=scene.rigport.export_apply_modifiers,
                export_morph=True,
                export_morph_normal=True,
                export_skins=True,
                export_def_bones=False,  # sockets are non-deform bones — keep them in the export
                export_animations=scene.rigport.export_animations,
            )
        except (RuntimeError, TypeError) as exc:
            self.report({"ERROR"}, f"GLB export failed: {exc}")
            return {"CANCELLED"}

        self.report({"INFO"}, f"Exported {os.path.basename(path)}. Import in Godot, then run the RigPort Validator dock.")
        return {"FINISHED"}


# --------------------------------------------------------------------------
# registration
# --------------------------------------------------------------------------

CLASSES = (
    RIGPORT_OT_prep_meshes,
    RIGPORT_OT_auto_markers,
    RIGPORT_OT_mirror_markers,
    RIGPORT_OT_generate_rig,
    RIGPORT_OT_auto_skin,
    RIGPORT_OT_add_sockets,
    RIGPORT_OT_create_mouth_shapes,
    RIGPORT_OT_preview_mouth,
    RIGPORT_OT_add_test_poses,
    RIGPORT_OT_validate,
    RIGPORT_OT_export_glb,
)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
