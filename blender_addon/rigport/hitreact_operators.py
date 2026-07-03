"""RigPort HitReact Blender operators (panel section 7: Damage Reactions).

Phase 1 scope: generate + validate + export the .hitreact.json profile, and
preview reactions on the rig. Additive clip baking (LOD 2 fallback) is
deferred to a later phase per the TDD implementation plan.
"""

import math
import os

import bpy

from . import contracts, hitreact
from .operators import _find_rig
from .properties import add_result, clear_results


def _rig_bone_names(rig):
    return {b.name for b in rig.data.bones}


def _character_name(export_path):
    base = os.path.basename(export_path)
    for suffix in (hitreact.PROFILE_SUFFIX, ".json", ".glb"):
        if base.lower().endswith(suffix):
            base = base[: -len(suffix)]
            break
    return base or "character"


def _report_results(scene, results):
    for status, message in results:
        add_result(scene, status, message)


class RIGPORT_OT_validate_hitreact(bpy.types.Operator):
    """Validate the rig against the RigPort hit reaction contract"""

    bl_idname = "rigport.validate_hitreact"
    bl_label = "Validate HitReact"
    bl_options = {"REGISTER"}

    def execute(self, context):
        scene = context.scene
        rp = scene.rigport
        clear_results(scene)
        rig = _find_rig(context)
        if rig is None:
            add_result(scene, "FAIL", "No RigPort rig in the scene.")
            return {"FINISHED"}
        results = hitreact.validate(_rig_bone_names(rig), rp.preset, rp.hitreact_include_limbs)
        _report_results(scene, results)
        if not hitreact.has_failures(results):
            add_result(scene, "INFO", "HitReact checks passed. Generate and export the profile.")
        return {"FINISHED"}


class RIGPORT_OT_generate_hitreact_profile(bpy.types.Operator):
    """Resolve hit zones against the rig and report the generated profile.
    Export HitReact Profile writes the same data to disk"""

    bl_idname = "rigport.generate_hitreact_profile"
    bl_label = "Generate Hit React Profile"
    bl_options = {"REGISTER"}

    def execute(self, context):
        scene = context.scene
        rp = scene.rigport
        clear_results(scene)
        rig = _find_rig(context)
        if rig is None:
            add_result(scene, "FAIL", "No RigPort rig in the scene.")
            return {"CANCELLED"}

        names = _rig_bone_names(rig)
        results = hitreact.validate(names, rp.preset, rp.hitreact_include_limbs)
        _report_results(scene, results)
        if hitreact.has_failures(results):
            add_result(scene, "FAIL", "Fix the failures above, then regenerate.")
            return {"CANCELLED"}

        profile = hitreact.build_profile(
            names, rp.preset, _character_name(rp.hitreact_export_path), rp.hitreact_include_limbs
        )
        for zone_id, zone in profile["zones"].items():
            weighted = {**zone["primary_bones"], **zone["secondary_bones"]}
            summary = ", ".join(f"{b} {w:g}" for b, w in weighted.items())
            add_result(scene, "PASS", f"Zone {zone_id}: {summary}")
        add_result(scene, "INFO", f"{len(profile['zones'])} zone(s), {len(profile['limits'])} bone limits. Preview, then export.")
        return {"FINISHED"}


class RIGPORT_OT_export_hitreact_profile(bpy.types.Operator):
    """Write the .hitreact.json profile for the Godot HitReact driver"""

    bl_idname = "rigport.export_hitreact_profile"
    bl_label = "Export HitReact Profile"
    bl_options = {"REGISTER"}

    def execute(self, context):
        scene = context.scene
        rp = scene.rigport
        rig = _find_rig(context)
        if rig is None:
            self.report({"ERROR"}, "No RigPort rig found.")
            return {"CANCELLED"}

        names = _rig_bone_names(rig)
        results = hitreact.validate(names, rp.preset, rp.hitreact_include_limbs)
        if hitreact.has_failures(results):
            clear_results(scene)
            _report_results(scene, results)
            self.report({"ERROR"}, "HitReact validation failed — see Results.")
            return {"CANCELLED"}

        path = bpy.path.abspath(rp.hitreact_export_path)
        if not path.lower().endswith(hitreact.PROFILE_SUFFIX):
            root, _ = os.path.splitext(path)
            path = root + hitreact.PROFILE_SUFFIX
        os.makedirs(os.path.dirname(path), exist_ok=True)

        profile = hitreact.build_profile(
            names, rp.preset, _character_name(path), rp.hitreact_include_limbs
        )
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(hitreact.profile_to_json(profile))
        except OSError as exc:
            self.report({"ERROR"}, f"Profile export failed: {exc}")
            return {"CANCELLED"}

        self.report({"INFO"}, f"Exported {os.path.basename(path)}. Assign it to the HitReact driver in Godot.")
        return {"FINISHED"}


class RIGPORT_OT_generate_hitreact_clips(bpy.types.Operator):
    """Bake additive hit reaction actions (RP_Hit_*) for LOD 2 fallback.
    Noise-free canonical style targets — same math as preview and runtime.
    Enable animation export on the GLB for these to reach Godot"""

    bl_idname = "rigport.generate_hitreact_clips"
    bl_label = "Generate Additive Hit Clips"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        scene = context.scene
        rp = scene.rigport
        clear_results(scene)
        rig = _find_rig(context)
        if rig is None:
            add_result(scene, "FAIL", "No RigPort rig in the scene.")
            return {"CANCELLED"}

        names = _rig_bone_names(rig)
        results = hitreact.validate(names, rp.preset, rp.hitreact_include_limbs)
        if hitreact.has_failures(results):
            _report_results(scene, results)
            add_result(scene, "FAIL", "Fix HitReact validation failures before baking clips.")
            return {"CANCELLED"}

        profile = hitreact.build_profile(names, rp.preset, "clips", rp.hitreact_include_limbs)
        fps = hitreact.contract()["baked_clips"]["fps"]
        made = 0
        skipped = 0
        for zone_id, direction, impulse_class in hitreact.clip_combinations(rp.hitreact_include_limbs):
            if zone_id not in profile["zones"]:
                continue
            action_name = hitreact.clip_name(zone_id, direction, impulse_class)
            if action_name in bpy.data.actions:
                skipped += 1
                continue
            self._bake_clip(rig, action_name, hitreact.clip_keyframes(profile, zone_id, direction, impulse_class))
            made += 1

        if scene.render.fps != fps:
            add_result(scene, "WARN", "Scene FPS is %d; clips are authored for %d fps." % (scene.render.fps, fps))
        add_result(scene, "PASS", "Baked %d additive hit clip(s) (%d already existed)." % (made, skipped))
        add_result(scene, "INFO", "Actions are additive offsets from rest. Enable animation export on the GLB so LOD 2 can play them in Godot.")
        return {"FINISHED"}

    @staticmethod
    def _bake_clip(rig, action_name, keyframes):
        action = bpy.data.actions.new(action_name)
        action.use_fake_user = True
        for bone, keys in keyframes.items():
            pb = rig.pose.bones.get(bone)
            if pb is None:
                continue
            pb.rotation_mode = "XYZ"
            base_path = 'pose.bones["%s"].rotation_euler' % bone
            for axis in range(3):
                fcurve = action.fcurves.new(data_path=base_path, index=axis)
                fcurve.keyframe_points.add(len(keys))
                for i, (frame, rot) in enumerate(keys):
                    kp = fcurve.keyframe_points[i]
                    kp.co = (float(frame), math.radians(rot[axis]))
                    kp.interpolation = "BEZIER"
                fcurve.update()


class RIGPORT_OT_validate_hitreact_clips(bpy.types.Operator):
    """Check baked RP_Hit_* actions: short, rig bones only, no scale keys"""

    bl_idname = "rigport.validate_hitreact_clips"
    bl_label = "Validate Hit Clips"
    bl_options = {"REGISTER"}

    def execute(self, context):
        scene = context.scene
        clear_results(scene)
        rig = _find_rig(context)
        bone_names = _rig_bone_names(rig) if rig else set()
        prefix = hitreact.contract()["baked_clips"]["prefix"] + "_"
        max_frame = hitreact.contract()["baked_clips"]["frames"]["neutral_out"] + 4

        clips = [a for a in bpy.data.actions if a.name.startswith(prefix)]
        if not clips:
            add_result(scene, "WARN", "No RP_Hit_* actions found — run Generate Additive Hit Clips first.")
            return {"FINISHED"}

        bad = 0
        for action in clips:
            problems = []
            if action.frame_range[1] > max_frame:
                problems.append("too long (%.0f frames)" % action.frame_range[1])
            for fc in action.fcurves:
                if ".scale" in fc.data_path:
                    problems.append("keys scale")
                    break
                if fc.data_path.startswith('pose.bones["'):
                    bone = fc.data_path.split('"')[1]
                    if bone_names and bone not in bone_names:
                        problems.append("keys unknown bone '%s'" % bone)
                        break
            if problems:
                bad += 1
                add_result(scene, "FAIL", "%s: %s." % (action.name, "; ".join(problems)))
        if bad == 0:
            add_result(scene, "PASS", "All %d RP_Hit_* clips are short, bone-only, and scale-free." % len(clips))
        return {"FINISHED"}


class RIGPORT_OT_preview_hitreact(bpy.types.Operator):
    """Preview the selected hit reaction on the rig, looping (Esc or right-click to stop).
    Uses the same offsets and timing curve the exported profile describes"""

    bl_idname = "rigport.preview_hitreact"
    bl_label = "Preview Reaction"
    bl_options = {"REGISTER"}

    _timer = None
    _t = 0.0
    _loop = 0
    _rig_name = ""
    _profile = None
    _offsets = {}
    _secondary = set()
    _saved = {}

    _LOOP_GAP = 0.5  # neutral pause between repeats

    def _rig(self):
        rig = bpy.data.objects.get(self._rig_name)
        return rig if rig and rig.type == "ARMATURE" else None

    def invoke(self, context, event):
        rp = context.scene.rigport
        rig = _find_rig(context)
        if rig is None:
            self.report({"ERROR"}, "No RigPort rig found.")
            return {"CANCELLED"}

        names = _rig_bone_names(rig)
        results = hitreact.validate(names, rp.preset, rp.hitreact_include_limbs)
        if hitreact.has_failures(results):
            self.report({"ERROR"}, "HitReact validation failed — run Validate HitReact for details.")
            return {"CANCELLED"}

        self._profile = hitreact.build_profile(names, rp.preset, "preview", rp.hitreact_include_limbs)
        if rp.hitreact_preview_zone not in self._profile["zones"]:
            self.report({"ERROR"}, f"Zone '{rp.hitreact_preview_zone}' unavailable — enable limb zones or pick another.")
            return {"CANCELLED"}

        self._rig_name = rig.name
        self._loop = 0
        self._t = 0.0
        self._rebuild_offsets(rp)

        self._saved = {}
        for bone in self._offsets:
            pb = rig.pose.bones.get(bone)
            if pb is None:
                continue
            pb.rotation_mode = "XYZ"
            self._saved[bone] = tuple(pb.rotation_euler)

        wm = context.window_manager
        self._timer = wm.event_timer_add(1.0 / 30.0, window=context.window)
        wm.modal_handler_add(self)
        return {"RUNNING_MODAL"}

    def _rebuild_offsets(self, rp):
        # Re-seed per loop so artists see the seeded variation band, not one sample.
        seed = rp.hitreact_seed + self._loop
        self._offsets = hitreact.peak_offsets(
            self._profile, rp.hitreact_preview_zone, rp.hitreact_preview_direction,
            rp.hitreact_impulse_class, seed,
        )
        self._secondary = hitreact.secondary_bones(self._profile, rp.hitreact_preview_zone)

    def modal(self, context, event):
        rig = self._rig()
        if event.type in {"ESC", "RIGHTMOUSE"} or rig is None:
            return self._finish(context, rig)
        if event.type != "TIMER":
            return {"RUNNING_MODAL"}

        rp = context.scene.rigport
        timing = self._profile["timing"]
        delay = self._profile["variation"]["secondary_delay"]
        self._t += 1.0 / 30.0

        if self._t >= hitreact.total_duration(timing) + delay + self._LOOP_GAP:
            self._t = 0.0
            self._loop += 1
            self._rebuild_offsets(rp)

        for bone, (x, y, z) in self._offsets.items():
            pb = rig.pose.bones.get(bone)
            if pb is None:
                continue
            t = self._t - (delay if bone in self._secondary else 0.0)
            e = hitreact.envelope(t, timing)
            base = self._saved.get(bone, (0.0, 0.0, 0.0))
            pb.rotation_euler = (
                base[0] + math.radians(x) * e,
                base[1] + math.radians(y) * e,
                base[2] + math.radians(z) * e,
            )
        if context.area:
            context.area.tag_redraw()
        return {"RUNNING_MODAL"}

    def _finish(self, context, rig):
        if self._timer:
            context.window_manager.event_timer_remove(self._timer)
            self._timer = None
        if rig:
            for bone, rot in self._saved.items():
                pb = rig.pose.bones.get(bone)
                if pb is not None:
                    pb.rotation_euler = rot
        return {"FINISHED"}


CLASSES = (
    RIGPORT_OT_validate_hitreact,
    RIGPORT_OT_generate_hitreact_profile,
    RIGPORT_OT_generate_hitreact_clips,
    RIGPORT_OT_validate_hitreact_clips,
    RIGPORT_OT_export_hitreact_profile,
    RIGPORT_OT_preview_hitreact,
)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
