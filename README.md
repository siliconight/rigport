# RigPort 0.3.0

**Rig it. Test it. Ship it to Godot.**

Blender-to-Godot humanoid character readiness pipeline: raw mesh → fitted
skeleton markers → game export rig → auto-skin → gameplay sockets → VO mouth
shapes → GLB → Godot validation → readiness report.

RigPort is a guided first-pass tool, not a one-click perfect rigger.
Characters it produces are meant for **first-pass gameplay testing**; final
shipping quality still needs manual weight cleanup and art review.

## Layout

```
contracts/                      Canonical JSON data contracts (bone, socket,
                                mouth shape, mouth LOD, presets)
blender_addon/rigport/          Blender add-on (Blender 4.0+)
godot_addon/addons/rigport/     Godot editor add-on + runtime driver (Godot 4.2+)
```

The contracts are duplicated into both add-ons so each installs standalone.
`contracts/` is the source of truth — if you edit a contract, copy it into
both add-ons (`tools/sync_contracts.sh`).

## HitReact (v0.2, Phase 1)

Procedural gunshot hit reactions. Blender panel section **7. Damage
Reactions** (opt-in per character) validates the rig against
`hit_react_contract.json`, previews seeded directional reactions on the rig,
and exports a per-character `*.hitreact.json` profile next to the GLB. The
profile drives the Godot `RigPortHitReactDriver` (SkeletonModifier3D overlay
— Phase 2, not yet in this repo). Head/chest/pelvis zones are required and
use the `Hitbox_*` sockets; arm/leg zones are opt-in. `first_person_arms`
and `cosmetic_preview_dummy` presets don't support HitReact.

Headless logic tests: `python3 tools/test_hitreact.py` (no Blender needed).

## Publishing to GitHub

From the extracted `rigport/` folder:

```sh
git init -b main
git add .
git commit -m "RigPort v0.1.0 — Blender + Godot MVP"
git remote add origin git@github.com:siliconight/rigport.git
git push -u origin main
```

`.gitignore`, `.gitattributes`, and `LICENSE` (MIT) are included.
`tools/sync_contracts.sh` re-copies the canonical contracts into both
add-ons; `tools/build_blender_addon.sh` rebuilds the installable Blender
zip.

## Install

**Blender:** zip the `blender_addon/rigport/` folder (the folder itself, so the
zip contains `rigport/__init__.py`) → Edit → Preferences → Add-ons → Install
from Disk. `rigport_blender_addon.zip` in this repo is pre-built. The panel
appears in the 3D Viewport sidebar (N) under **RigPort**.

**Godot:** copy `godot_addon/addons/rigport/` into your project's `addons/`
folder, then enable **RigPort Validator** in Project Settings → Plugins. The
dock appears on the right; `RigPortVOMouthDriver` becomes an addable node type.

## Blender workflow (panel = the wizard, top to bottom)

1. **Prepare** — select the character meshes, run the prep check. Expected:
   upright, facing **-Y**, T- or A-pose, feet near Z=0, transforms applied.
2. **Fit Skeleton Markers** — auto-place, then drag the `RP_*` empties onto
   the character's joints. Mirror L→R after adjusting the left side.
3. **Rig + Skin** — generates the `RigPort_Rig` game export skeleton
   (contract bone names, clean hierarchy), then parents the selected meshes
   with automatic weights. Auto weights are a first pass — inspect them.
4. **Gameplay Sockets** — adds the preset's sockets as non-deforming bones
   (weapon, muzzle, camera FP/TP, footstep, hitbox, cosmetic anchors).
5. **VO Mouth** — creates the shape keys (`Mouth_Neutral/Open/Wide/Narrow`,
   optionally the seven visemes) on the **active** mesh. They start as copies
   of Basis — sculpt each one. Preview flap / viseme cycle in-viewport.
   Skip this section for characters that never speak.
6. **Pose Tests** — builds the `RigPort_TestPoses` action with timeline
   markers (aim, reload, crouch, deep knee bend, twist, death collapse,
   mouth shapes). Scrub and inspect shoulders, elbows, hips, knees, mouth.
7. **Validate + Export** — checks the bone/socket/mouth contracts for the
   chosen preset, then exports a Godot-ready GLB (Y-up, shape keys included,
   socket bones kept).

## Godot workflow

1. Import the GLB, drop it in a scene, select the character root.
2. **RigPort dock** → pick the preset → **Validate Selected Character**.
   You get PASS/WARN/FAIL lines and a readiness score:
   90–100 ready for gameplay review · 75–89 usable with cleanup ·
   50–74 prototype only · <50 not ready.
3. **Add VO Mouth Driver** / **Connect Voice Audio Player** — wires a
   `RigPortVOMouthDriver` to the mouth mesh and an `AudioStreamPlayer3D`.
4. **Create VO Test Scene** → open it → F6. It plays a generated voice burst
   (or an assigned stream) and prints PASS/FAIL for "mouth moves during VO"
   and "mouth returns to neutral" to Output.
5. **Save Readiness Report** → `res://rigport_reports/<name>_<date>.md` + `.json`.

### VO mouth driver

- **LOD 0** — timed visemes from a sidecar JSON (`viseme_sidecar_path`).
- **LOD 1** — amplitude flap at 30 Hz: bus loudness drives `Mouth_Open`.
- **LOD 2** — cheap flap at 10 Hz: `Mouth_Open` snaps open/closed.
- **LOD 3** — disabled: mouth stays neutral, only audio plays.

Route the voice player to a dedicated audio bus (e.g. `Voice`) — the driver
reads that bus's peak level, so anything else on the bus pollutes the flap.

## Known limits (MVP)

- Rig generation assumes T-pose facing -Y; test-pose rotations are tuned for
  the rig this add-on generates and are deliberately approximate — their job
  is to expose bad weights, not to look good.
- Bone rolls are left at 0. Fine for export/validation; twist-sensitive
  animation work may want a roll pass.
- No fingers, no face bones, no ragdoll, no retargeting/BoneMap assistant,
  no in-editor animation smoke-test scene — that's the MVP 2.0 slice
  (Rigify-backed rigs, SkeletonProfileHumanoid/BoneMap assistant, timed
  viseme tooling, capsule/socket previews).
- Dock actions don't register editor undo yet — save before bulk changes.
- Godot-side "forward direction" is inferred from arm bone symmetry.

## Data contracts (v0.2.0)

- `bone_contract.json` — 18 required humanoid bones, plain-English names.
- `socket_contract.json` — player-required + optional sockets, parent map.
- `mouth_shape_contract.json` — 4 MVP shapes, 7 visemes, optional expressions.
- `mouth_lod_contract.json` — LOD 0–3 modes, required shapes, update rates.
- `presets.json` — 8 character presets and their requirements.

### Godot runtime (Phase 2)

`RigPortHitReactDriver` (**Godot 4.3+**, `SkeletonModifier3D`) sits under the
character's `Skeleton3D`, loads the `.hitreact.json` profile, and applies
seeded, limit-clamped additive pose offsets after `AnimationMixer` — LOD 0
full body, LOD 1 torso/head. `RigPortHitReactReceiver` on the character root
is the gameplay API: `apply_hit(RigPortHitEvent)` /
`apply_gunshot_hit(...)`. Attach `RigPortHitReactTest` next to the character
for keyboard smoke testing (1-9). Aggregation: same-zone hits within 80 ms
combine, same-zone spam dampens 0.6x, max 3 active reactions, per-bone
clamps always win. If reactions lean INTO the shot on your rig, toggle
`flip_front` / `flip_side` on the driver.

### Runtime integration (Phase 3)

State gating is data-driven from the contract `state_modifiers` table
(idle 1.0 → dying 0.0). Set it from AI/locomotion via
`receiver.set_npc_state(&"running")`. Running additionally halves pelvis/leg
motion; staggered NPCs turn non-heavy hits into small torso twitches; killed
events bypass gating so the fatal impact reads before death handoff.
Late events join in progress via `event.age_ms`; events staler than
`max_stale_ms` (250) drop unless killed. Same-zone hits: ≤80 ms merge,
80–120 ms drop (cooldown), beyond that dampen 0.6x.
`examples/hitreact_server_integration_example.gd` shows the full
server-authoritative payload flow (damage bands → impulse class, server
seed, tick-based aging, headless-server skip).

### Editor tooling + physics metadata (Phase 4)

The Godot validator now runs `_check_hitreact` (driver present, profile
loads, zones/bones/sockets resolve, version supported) and the dock/report
show a dedicated `HitReact: PASS/WARN/FAIL/N/A` line. Dock buttons: Add
HitReact Driver (auto-adds a receiver and auto-assigns
`<scene>.hitreact.json` if present), Assign HitReact Profile, Create
HitReact Test Scene. The driver has `debug_draw` (impact point, incoming
red, reaction green, 0.5 s). Profiles now carry ARC-style rig metadata for
the future stumble/partial-ragdoll layer: `physics.total_mass_kg` +
per-bone `mass_hints_kg` (heavy enemies 1.5x), per-zone `toughness`, and
`style_targets` (animation tag vocabulary + recovery pose name). Data
only — nothing consumes it at runtime yet.

### Baked clip fallback (Phase 5)

Blender panel button **Generate Additive Hit Clips** bakes noise-free
canonical RP_Hit_* actions (36 for core zones: 3 zones x 4 cardinal
directions x 3 impulse classes; 84 with limb zones) using the exact same
offset math as the preview and runtime — TDD frame timing at 30 fps
(neutral 1 / peak 4 / follow-through 7 / recovery 12 / neutral 16),
secondary bones lag to the follow-through frame. **Validate Hit Clips**
checks they're short, bone-only, and scale-free. Enable animation export on
the GLB to ship them. In Godot, LOD 2 resolves zone + nearest cardinal
direction + class to the clip name, emits `baked_clip_requested` (hook into
an AnimationTree add-blend for true additive playback), and falls back to
playing directly on `baked_anim_player` — fine for far NPCs. The validator
warns when a driver sits at LOD 2 with no reachable RP_Hit_* clips.

## Stumble Kit (v0.3)

The balance/stumble/fall layer above HitReact flinch. `RigPortStumbleController`
(**Godot 4.3+**, `SkeletonModifier3D`) sits under the Skeleton3D *after* the
HitReact driver so its whole-body lean composes on top of the flinch. It
accumulates a mass-weighted balance impulse from each hit (using the profile's
`mass_hints_kg` — a pelvis hit unbalances more than a hand), and when balance
crosses the profile thresholds the NPC **staggers** (lean + a
`recovery_step_requested` signal the mover can honor) or **falls** (partial
ragdoll via an assigned `PhysicalBoneSimulator3D`, else a procedural collapse
plus a `fell` signal). Server flags still win: `event.stagger` forces a
stagger and `event.killed` forces a fall, so gameplay stays authoritative;
the local balance model only adds visual richness and drives stumbles in
single-player/testing.

Per-character tuning ships in the profile's `stumble` block, with thresholds
scaled by preset `stumble_resistance` (heavy enemies 1.8x harder to knock
down, civilians 0.7x). Dock: **Add Stumble Controller** (auto-wires the
profile and any PhysicalBoneSimulator3D). Signals: `stumble_started`,
`recovery_step_requested(local_dir, distance)`, `fell`, `recovered`. The
controller never moves the gameplay capsule — a recovery step is a request,
not a teleport.

### Wiring the recovery step (gameplay side)

```gdscript
# On your CharacterBody3D mover:
receiver.stumble().recovery_step_requested.connect(
    func(local_dir: Vector3, dist: float) -> void:
        var world_dir := global_transform.basis * local_dir
        _pending_step = world_dir * dist   # apply over a few physics frames
)
```
