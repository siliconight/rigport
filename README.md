# RigPort 0.1.0 (MVP)

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
both add-ons.

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
