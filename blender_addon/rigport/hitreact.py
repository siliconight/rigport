"""RigPort HitReact — profile generation, validation, and preview math.

This module is deliberately bpy-free. Everything here operates on plain data
(bone name sets, dicts, floats) so it can be unit-tested outside Blender.
Operators in hitreact_operators.py adapt Blender state into these calls.

The hit reaction system: Blender exports a per-character .hitreact.json
profile describing how each hit zone drives weighted bone pose offsets;
the Godot runtime driver (Phase 2) applies short additive offsets over the
base animation. See docs/rigport_hitreact_tdd for the full design.
"""

import json
import math
import random

from . import contracts

PROFILE_VERSION = "0.1.0"
PROFILE_SUFFIX = ".hitreact.json"

# ---------------------------------------------------------------------------
# contract access
# ---------------------------------------------------------------------------


def contract():
    return contracts.HITREACT


def zones(include_limbs):
    """Zone id -> zone def. Required zones always; limb zones opt-in."""
    hc = contract()
    out = dict(hc["required_hit_zones"])
    if include_limbs:
        out.update(hc["optional_hit_zones"])
    return out


def zone_bones(zone):
    return list(zone["primary_bones"]) + list(zone["secondary_bones"])


def preset_support(preset_id):
    """'default', 'optional', or 'unsupported'. Unknown presets are optional."""
    entry = contract()["preset_support"].get(preset_id, {})
    return entry.get("support", "optional")


def preset_limit_scale(preset_id):
    entry = contract()["preset_support"].get(preset_id, {})
    return float(entry.get("limit_scale", 1.0))


def preset_mass_scale(preset_id):
    entry = contract()["preset_support"].get(preset_id, {})
    return float(entry.get("mass_scale", 1.0))


def preset_stumble_resistance(preset_id):
    entry = contract()["preset_support"].get(preset_id, {})
    return float(entry.get("stumble_resistance", 1.0))


# ---------------------------------------------------------------------------
# validation (TDD section 19, Phase 1 scope — no clip checks yet)
# ---------------------------------------------------------------------------


def validate(bone_names, preset_id, include_limbs):
    """Return [(status, message), ...] for the Blender results list.

    bone_names: set of bone names on the rig (sockets are non-deform bones,
    so socket presence is also a name check).
    """
    hc = contract()
    results = []

    support = preset_support(preset_id)
    if support == "unsupported":
        results.append(("FAIL", f"Preset '{preset_id}' does not support hit reactions."))
        return results

    missing = [b for b in hc["requires_bones"] if b not in bone_names]
    if missing:
        results.append(("FAIL", f"HitReact missing required bones: {', '.join(missing)}."))
    else:
        results.append(("PASS", f"All {len(hc['requires_bones'])} HitReact bones present."))

    for zone_id, zone in hc["required_hit_zones"].items():
        socket = zone["socket"]
        if socket not in bone_names:
            results.append(("FAIL", f"Zone '{zone_id}' missing socket {socket}. Run Add Gameplay Sockets."))
        zmissing = [b for b in zone_bones(zone) if b not in bone_names]
        if zmissing:
            results.append(("FAIL", f"Zone '{zone_id}' missing bones: {', '.join(zmissing)}."))
    if not any(s == "FAIL" for s, _ in results):
        results.append(("PASS", "All required hit zones resolve (head, chest, pelvis)."))

    if include_limbs:
        for zone_id, zone in hc["optional_hit_zones"].items():
            zmissing = [b for b in zone_bones(zone) if b not in bone_names]
            if zmissing:
                results.append(("WARN", f"Limb zone '{zone_id}' missing bones: {', '.join(zmissing)} — zone will be dropped."))

    if support == "optional":
        results.append(("INFO", f"HitReact is optional for preset '{preset_id}'."))
    return results


def has_failures(results):
    return any(s == "FAIL" for s, _ in results)


# ---------------------------------------------------------------------------
# profile build (TDD section 10)
# ---------------------------------------------------------------------------


def build_profile(bone_names, preset_id, character_name, include_limbs):
    """Assemble the .hitreact.json profile dict.

    Assumes validate() passed for required zones. Optional limb zones with
    missing bones are silently dropped; bones missing from limits are given
    a limit derived from their zone's max_degrees.
    """
    hc = contract()
    scale = preset_limit_scale(preset_id)
    zone_defs = zones(include_limbs)

    out_zones = {}
    referenced = set()
    for zone_id, zone in zone_defs.items():
        zmissing = [b for b in zone_bones(zone) if b not in bone_names]
        if zmissing:
            if zone_id in hc["required_hit_zones"]:
                raise ValueError(f"required zone '{zone_id}' missing bones: {zmissing}")
            continue  # drop incomplete optional zone
        entry = {
            "primary_bones": dict(zone["primary_bones"]),
            "secondary_bones": dict(zone["secondary_bones"]),
            "toughness": zone.get("toughness", hc["defaults"].get("zone_toughness", 1.0)),
        }
        if "socket" in zone:
            entry["socket"] = zone["socket"]
        out_zones[zone_id] = entry
        referenced.update(zone_bones(zone))

    limits = {}
    default_limits = hc["defaults"]["limits"]
    for bone in sorted(referenced):
        base = default_limits.get(bone)
        if base is None:
            deg = max(z["max_degrees"] for z in zone_defs.values() if bone in zone_bones(z))
            base = {"pitch": deg, "yaw": deg, "roll": deg * 0.6}
        limits[bone] = {axis: round(v * scale, 2) for axis, v in base.items()}

    # Physics metadata: whole-body mass hints for the future stumble /
    # partial-ragdoll layer (v0.3) and PhysicalBone3D setup. Data only —
    # nothing at runtime consumes this yet.
    mass_scale = preset_mass_scale(preset_id)
    total_mass = round(hc["defaults"]["total_mass_kg"] * mass_scale, 1)
    mass_hints = {
        bone: round(frac * total_mass, 2)
        for bone, frac in hc["defaults"]["mass_fractions"].items()
        if bone in bone_names
    }

    # Stumble / balance tuning for the v0.3 stumble kit. Thresholds scale up
    # with the preset's stumble_resistance (heavy enemies harder to knock
    # down, civilians easier); everything else is copied from the contract.
    stumble_src = hc["defaults"]["stumble"]
    resistance = preset_stumble_resistance(preset_id)
    stumble = dict(stumble_src)
    stumble["balance_threshold"] = round(stumble_src["balance_threshold"] * resistance, 3)
    stumble["fall_threshold"] = round(stumble_src["fall_threshold"] * resistance, 3)
    stumble["resistance"] = resistance

    return {
        "rigport_hitreact_version": PROFILE_VERSION,
        "character": character_name,
        "preset": preset_id,
        "skeleton_name": "Skeleton3D",
        "default_lod": hc["defaults"]["default_lod"],
        "zones": out_zones,
        "limits": limits,
        "timing": dict(hc["defaults"]["timing"]),
        "variation": dict(hc["defaults"]["variation"]),
        "physics": {
            "total_mass_kg": total_mass,
            "mass_hints_kg": mass_hints,
        },
        "stumble": stumble,
        "style_targets": {
            "animation_tags": list(hc["animation_tags"]),
            "recovery_pose": hc["defaults"]["recovery_pose"],
        },
    }


def profile_to_json(profile):
    return json.dumps(profile, indent=2) + "\n"


# ---------------------------------------------------------------------------
# preview math (used by the Blender modal preview operator)
# ---------------------------------------------------------------------------

# Direction -> (pitch_sign, yaw_sign, roll_sign) multipliers on pose-bone local
# XYZ eulers. Tuned for RigPort-generated rigs (T-pose, facing -Y, roll 0),
# same convention as the deformation test poses: +pitch leans the chain
# forward, +yaw twists left. The body moves AWAY from the incoming hit, so a
# hit from the front pitches the torso back (negative pitch).
_D = 0.7071
DIRECTION_COMPONENTS = {
    "front":       (-1.0, 0.0, 0.0),
    "back":        (1.0, 0.0, 0.0),
    "left":        (0.0, -1.0, -0.5),
    "right":       (0.0, 1.0, 0.5),
    "front_left":  (-_D, -_D, -0.35),
    "front_right": (-_D, _D, 0.35),
    "back_left":   (_D, -_D, -0.35),
    "back_right":  (_D, _D, 0.35),
    "up":          (-0.5, 0.0, 0.0),
    "down":        (0.5, 0.0, 0.0),
}


def envelope(t, timing):
    """Reaction strength 0..1 at time t. Fast in (easeOutCubic), hold,
    slower out (easeInOutSine). Matches TDD section 13.5."""
    attack = timing["attack_time"]
    hold = timing["hold_time"]
    recover = timing["recover_time"]
    if t <= 0.0:
        return 0.0
    if t < attack:
        x = t / attack
        return 1.0 - (1.0 - x) ** 3
    if t < attack + hold:
        return 1.0
    if t < attack + hold + recover:
        x = (t - attack - hold) / recover
        return 1.0 - (-(math.cos(math.pi * x) - 1.0) / 2.0)
    return 0.0


def total_duration(timing):
    return timing["attack_time"] + timing["hold_time"] + timing["recover_time"]


def peak_offsets(profile, zone_id, direction, impulse_class, seed, noise_scale=1.0):
    """Per-bone peak rotation offsets in degrees: {bone: (x, y, z)}.

    Deterministic for a given seed. Preview and LOD-2 clip baking both build
    on this so what artists see in Blender matches the data. Clips pass
    noise_scale=0 for canonical, noise-free style targets.
    """
    zone = profile["zones"][zone_id]
    strength = contract()["impulse_classes"][impulse_class]["strength"]
    pitch_s, yaw_s, roll_s = DIRECTION_COMPONENTS[direction]
    rng = random.Random(seed)
    noise = profile["variation"]["seeded_noise_degrees"] * noise_scale

    offsets = {}
    for bones in (zone["primary_bones"], zone["secondary_bones"]):
        for bone, weight in bones.items():
            lim = profile["limits"][bone]
            x = pitch_s * lim["pitch"] * weight * strength
            y = yaw_s * lim["yaw"] * weight * strength
            z = roll_s * lim["roll"] * weight * strength
            x += rng.uniform(-noise, noise) * weight
            y += rng.uniform(-noise, noise) * weight
            x = max(-lim["pitch"], min(lim["pitch"], x))
            y = max(-lim["yaw"], min(lim["yaw"], y))
            z = max(-lim["roll"], min(lim["roll"], z))
            offsets[bone] = (x, y, z)
    return offsets


def secondary_bones(profile, zone_id):
    return set(profile["zones"][zone_id]["secondary_bones"])


# ---------------------------------------------------------------------------
# baked additive clips (LOD 2 fallback, TDD sections 11.4 and 15)
# ---------------------------------------------------------------------------


def clip_name(zone_id, direction, impulse_class):
    """Canonical action name, e.g. RP_Hit_Chest_Front_Medium."""
    bc = contract()["baked_clips"]
    zone_part = "".join(w.capitalize() for w in zone_id.split("_"))
    dir_part = "".join(w.capitalize() for w in direction.split("_"))
    return "%s_%s_%s_%s" % (bc["prefix"], zone_part, dir_part, bc["class_names"][impulse_class])


def clip_combinations(include_limbs):
    """All (zone, direction, impulse_class) combos to bake."""
    bc = contract()["baked_clips"]
    combos = []
    for zone_id in zones(include_limbs):
        for direction in bc["directions"]:
            for impulse_class in contract()["impulse_classes"]:
                combos.append((zone_id, direction, impulse_class))
    return combos


def clip_keyframes(profile, zone_id, direction, impulse_class):
    """Keyframe data for one baked clip: {bone: [(frame, (x, y, z) deg), ...]}.

    TDD 11.4 timing at 30 fps: neutral 1, peak 4, follow-through 7,
    recovery 12, neutral 16. Secondary bones lag: they peak at the
    follow-through frame instead. Noise-free and seed-independent —
    baked clips are canonical style targets.
    """
    bc = contract()["baked_clips"]
    fr = bc["frames"]
    peaks = peak_offsets(profile, zone_id, direction, impulse_class, 0, noise_scale=0.0)
    secondary = secondary_bones(profile, zone_id)

    out = {}
    for bone, (x, y, z) in peaks.items():
        zero = (0.0, 0.0, 0.0)

        def scaled(f):
            return (x * f, y * f, z * f)

        if bone in secondary:
            keys = [
                (fr["neutral_in"], zero),
                (fr["peak"], scaled(0.55)),
                (fr["follow_through"], scaled(1.0)),
                (fr["recovery"], scaled(0.15)),
                (fr["neutral_out"], zero),
            ]
        else:
            keys = [
                (fr["neutral_in"], zero),
                (fr["peak"], scaled(1.0)),
                (fr["follow_through"], scaled(0.5)),
                (fr["recovery"], scaled(0.12)),
                (fr["neutral_out"], zero),
            ]
        out[bone] = keys
    return out
