#!/usr/bin/env python3
"""Headless unit tests for the bpy-free HitReact logic (TDD 25.1, Phase 1 scope).

Run from the repo root: python3 tools/test_hitreact.py
Loads blender_addon/rigport/hitreact.py without bpy by stubbing the package.
"""

import importlib.util
import json
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "blender_addon" / "rigport"


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


# Stub package so `from . import contracts` resolves without bpy.
pkg = types.ModuleType("rigport_test")
pkg.__path__ = [str(ADDON)]
sys.modules["rigport_test"] = pkg
contracts = _load_module("rigport_test.contracts", ADDON / "contracts.py")
hitreact = _load_module("rigport_test.hitreact", ADDON / "hitreact.py")

FULL_RIG = set(contracts.BONES["required_bones"]) | {"Hitbox_Head", "Hitbox_Chest", "Hitbox_Pelvis"}

passed = failed = 0


def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}")


print("contract")
hc = hitreact.contract()
check("loads with required zones", set(hc["required_hit_zones"]) == {"head", "chest", "pelvis"})
check("zone sockets match socket contract parents",
      all(z["socket"] in contracts.SOCKETS["socket_parents"] for z in hc["required_hit_zones"].values()))
check("all contract bones are canonical bone-contract bones",
      set(hc["requires_bones"]) <= set(contracts.BONES["required_bones"]))
check("every zone bone has a default limit or zone max_degrees fallback path",
      all(b in hc["defaults"]["limits"] for z in list(hc["required_hit_zones"].values()) + list(hc["optional_hit_zones"].values()) for b in hitreact.zone_bones(z)))
check("every preset in presets.json has a support entry",
      set(contracts.PRESETS) == set(hc["preset_support"]))
check("state modifiers cover the TDD state table",
      set(hc["defaults"]["state_modifiers"]) == {"idle", "walking", "running", "aiming", "in_cover", "staggered", "dying"})
check("dying gates to zero", hc["defaults"]["state_modifiers"]["dying"] == 0.0)
check("idle is full strength", hc["defaults"]["state_modifiers"]["idle"] == 1.0)
check("staleness + cooldown constants present",
      hc["defaults"]["max_stale_ms"] == 250 and hc["defaults"]["same_zone_cooldown_ms"] > 80)
check("running lower-body and staggered soft scales in (0,1)",
      0.0 < hc["defaults"]["running_lower_body_scale"] < 1.0 and 0.0 < hc["defaults"]["staggered_soft_scale"] < 1.0)
check("mass fractions sum to ~1.0", abs(sum(hc["defaults"]["mass_fractions"].values()) - 1.0) < 1e-6)
check("animation tag vocabulary present",
      set(hc["animation_tags"]) >= {"pain", "stumble", "fall", "brace", "recoil", "recovery"})

print("validate")
check("full rig passes", not hitreact.has_failures(hitreact.validate(FULL_RIG, "enemy_grunt", False)))
check("missing Hitbox_Chest fails", hitreact.has_failures(hitreact.validate(FULL_RIG - {"Hitbox_Chest"}, "enemy_grunt", False)))
check("missing Spine fails", hitreact.has_failures(hitreact.validate(FULL_RIG - {"Spine"}, "enemy_grunt", False)))
check("unsupported preset fails", hitreact.has_failures(hitreact.validate(FULL_RIG, "cosmetic_preview_dummy", False)))
check("missing limb bone with limbs on warns, not fails",
      not hitreact.has_failures(hitreact.validate(FULL_RIG - {"LeftHand"}, "enemy_grunt", True))
      and any(s == "WARN" for s, _ in hitreact.validate(FULL_RIG - {"LeftHand"}, "enemy_grunt", True)))

print("build_profile")
p = hitreact.build_profile(FULL_RIG, "enemy_grunt", "enemy_grunt_v001", False)
check("core zones only without limbs", set(p["zones"]) == {"head", "chest", "pelvis"})
check("required sockets carried into profile",
      {p["zones"][z]["socket"] for z in p["zones"]} == {"Hitbox_Head", "Hitbox_Chest", "Hitbox_Pelvis"})
check("limits cover every referenced bone",
      all(b in p["limits"] for z in p["zones"].values() for b in list(z["primary_bones"]) + list(z["secondary_bones"])))
check("timing/variation copied from contract defaults",
      p["timing"] == hc["defaults"]["timing"] and p["variation"] == hc["defaults"]["variation"])

pl = hitreact.build_profile(FULL_RIG, "enemy_grunt", "g", True)
check("limb zones included when requested", "left_arm" in pl["zones"] and "right_leg" in pl["zones"])
pl2 = hitreact.build_profile(FULL_RIG - {"LeftHand"}, "enemy_grunt", "g", True)
check("incomplete optional zone dropped, required kept",
      "left_arm" not in pl2["zones"] and set(pl2["zones"]) >= {"head", "chest", "pelvis", "right_arm"})

ph = hitreact.build_profile(FULL_RIG, "heavy_enemy", "h", False)
check("heavy_enemy limit_scale 0.8 applied",
      abs(ph["limits"]["Head"]["pitch"] - p["limits"]["Head"]["pitch"] * 0.8) < 1e-6)

check("zones carry toughness", all("toughness" in z for z in p["zones"].values()))
check("physics block: total mass + per-bone kg hints filtered to rig",
      p["physics"]["total_mass_kg"] == 80.0 and set(p["physics"]["mass_hints_kg"]) <= FULL_RIG
      and abs(sum(p["physics"]["mass_hints_kg"].values()) - 80.0) < 0.5)
check("heavy_enemy mass_scale 1.5 applied", ph["physics"]["total_mass_kg"] == 120.0)
check("style targets: tags + recovery pose",
      "stumble" in p["style_targets"]["animation_tags"] and p["style_targets"]["recovery_pose"])

check("profile JSON round-trips", json.loads(hitreact.profile_to_json(p)) == p)

print("preview math")
t = p["timing"]
check("envelope 0 at t=0 and after end",
      hitreact.envelope(0.0, t) == 0.0 and hitreact.envelope(hitreact.total_duration(t) + 0.01, t) == 0.0)
check("envelope 1.0 during hold", abs(hitreact.envelope(t["attack_time"] + t["hold_time"] * 0.5, t) - 1.0) < 1e-9)
check("envelope monotone rise in attack",
      hitreact.envelope(t["attack_time"] * 0.3, t) < hitreact.envelope(t["attack_time"] * 0.9, t))

o1 = hitreact.peak_offsets(p, "chest", "front_left", "medium", 8123)
o2 = hitreact.peak_offsets(p, "chest", "front_left", "medium", 8123)
o3 = hitreact.peak_offsets(p, "chest", "front_left", "medium", 8124)
check("same seed deterministic", o1 == o2)
check("different seed differs", o1 != o3)
check("offsets cover zone bones", set(o1) == {"Chest", "Spine", "Neck", "Head", "Hips"})
check("all offsets within limits",
      all(abs(x) <= p["limits"][b]["pitch"] + 1e-9 and abs(y) <= p["limits"][b]["yaw"] + 1e-9
          and abs(z) <= p["limits"][b]["roll"] + 1e-9 for b, (x, y, z) in o1.items()))
check("front hit pitches primary bone back (negative)",
      hitreact.peak_offsets(p, "chest", "front", "heavy", 0)["Chest"][0] < 0)
check("heavy stronger than small on primary bone",
      abs(hitreact.peak_offsets(p, "chest", "front", "heavy", 0)["Chest"][0])
      > abs(hitreact.peak_offsets(p, "chest", "front", "small", 0)["Chest"][0]))
check("every contract direction has preview components",
      all(d in hitreact.DIRECTION_COMPONENTS for d in hc["directions"]))

print("baked clips")
check("clip name format", hitreact.clip_name("chest", "front", "medium") == "RP_Hit_Chest_Front_Medium"
      and hitreact.clip_name("left_arm", "back", "small") == "RP_Hit_LeftArm_Back_Light"
      and hitreact.clip_name("pelvis", "right", "heavy") == "RP_Hit_Pelvis_Right_Heavy")
check("core combos = 3 zones x 4 dirs x 3 classes", len(hitreact.clip_combinations(False)) == 36)
check("limb combos = 7 zones", len(hitreact.clip_combinations(True)) == 84)

kf = hitreact.clip_keyframes(p, "chest", "front", "medium")
check("keyframes cover zone bones", set(kf) == {"Chest", "Spine", "Neck", "Head", "Hips"})
check("clips start and end neutral",
      all(keys[0][1] == (0.0, 0.0, 0.0) and keys[-1][1] == (0.0, 0.0, 0.0) for keys in kf.values()))
_peak_noise_free = hitreact.peak_offsets(p, "chest", "front", "medium", 0, noise_scale=0.0)
check("primary peaks at frame 4 with noise-free peak value",
      kf["Chest"][1][0] == 4 and kf["Chest"][1][1] == _peak_noise_free["Chest"])
check("secondary lags: peaks at follow-through frame",
      kf["Head"][2][0] == 7 and kf["Head"][2][1] == _peak_noise_free["Head"])
check("clip keyframes deterministic (noise-free, seed-independent)",
      hitreact.clip_keyframes(p, "chest", "front", "medium") == kf)
check("clip frames within contract bounds",
      all(k[0] <= hc["baked_clips"]["frames"]["neutral_out"] for keys in kf.values() for k in keys))

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
