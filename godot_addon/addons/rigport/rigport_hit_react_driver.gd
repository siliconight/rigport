class_name RigPortHitReactDriver
extends SkeletonModifier3D
## Procedural gunshot hit reactions, applied AFTER animation playback.
##
## Loads a RigPort .hitreact.json profile (exported from the Blender add-on),
## receives RigPortHitEvent pushes, and layers short-lived additive pose
## offsets over whatever the AnimationMixer produced. Runs as a
## SkeletonModifier3D so locomotion, aiming, and cover are evaluated first.
## Requires Godot 4.3+.
##
## Never moves the gameplay capsule — visual skeleton pose only.
## Built-in `active` toggles the driver; built-in `influence` scales it.
##
## Phase 2 scope: LOD 0 (full procedural) and LOD 1 (torso + head only).
## LOD 2 (baked clip fallback) arrives with the clip pipeline; until then it
## behaves like LOD 3 (disabled) with a one-time warning.

## Per-character profile exported by the Blender RigPort add-on.
@export_file("*.hitreact.json", "*.json") var profile_path := "":
	set(value):
		profile_path = value
		if is_inside_tree():
			_load_profile()
## 0 full procedural, 1 torso/head only, 2 baked clips (not yet), 3 disabled.
@export_range(0, 3) var lod := 0
## Current NPC state, set by gameplay/AI (TDD 13.3 / 16). Scales reaction
## strength via the contract state_modifiers table: idle, walking, running,
## aiming, in_cover, staggered, dying. Unknown states scale 1.0.
## Killed events bypass the state scale so the death impact still reads.
@export var npc_state: StringName = &"idle"
## Extra manual multiplier on top of the state table (kept for gameplay
## edge cases). 1.0 = neutral.
@export_range(0.0, 1.5) var state_strength_scale := 1.0
## Expected damage per impulse class, for the damage_scale curve
## (clamped 0.25–1.5 around these values).
@export var expected_damage := {&"small": 10.0, &"medium": 25.0, &"heavy": 50.0}
## Flip these if reactions lean toward the shot instead of away on your rig.
@export var flip_front := false
@export var flip_side := false
@export var debug_logging := false
## Draw impact point, incoming direction (red) and local reaction vector
## (green) for half a second per accepted hit. Editor/dev builds only.
@export var debug_draw := false
## AnimationPlayer holding the imported RP_Hit_* baked clips, for LOD 2.
## If unset, LOD 2 only emits baked_clip_requested — hook that into your
## AnimationTree add-blend for proper additive playback.
@export var baked_anim_player: NodePath

## Emitted at LOD 2 with the resolved clip name (e.g.
## &"RP_Hit_Chest_Front_Medium"). The AnimationPlayer fallback plays the
## clip directly, which is acceptable for far LODs.
signal baked_clip_requested(clip_name: StringName, event: RigPortHitEvent)

const MAX_ACTIVE_REACTIONS := 3
const COMBINE_WINDOW_MS := 80
const SAME_ZONE_DAMPEN := 0.6
const LOD1_BONES: Array[StringName] = [&"Head", &"Neck", &"Chest", &"Spine", &"Hips"]
const LOWER_BODY_BONES: Array[StringName] = [
	&"Hips", &"LeftUpperLeg", &"LeftLowerLeg", &"LeftFoot",
	&"RightUpperLeg", &"RightLowerLeg", &"RightFoot",
]

var _profile: Dictionary = {}
var _bone_idx: Dictionary = {}        # bone name -> skeleton bone index
var _limits: Dictionary = {}          # bone name -> Vector3 limits in radians (pitch, yaw, roll)
var _timing: Dictionary = {}
var _variation: Dictionary = {}
var _active: Array[Dictionary] = []   # {zone, start_ms, strength, offsets: {idx: Vector3 rad}, secondary: {idx: true}}
var _last_zone_push_ms: Dictionary = {}  # zone id -> ticks of last accepted push
var _lod2_warned := false


func _ready() -> void:
	if profile_path != "":
		_load_profile()


# ---------------------------------------------------------------------------
# public API (TDD section 21.2)
# ---------------------------------------------------------------------------


func push_hit(event: RigPortHitEvent) -> void:
	if not active or _profile.is_empty():
		return
	if lod >= 3:
		return
	if lod == 2:
		_play_baked_clip(event)
		return

	var zone_id := String(event.hit_zone)
	var zones: Dictionary = _profile.get("zones", {})
	if not zones.has(zone_id):
		if debug_logging:
			push_warning("HitReact: unknown zone '%s' — event dropped." % zone_id)
		return

	var hc_defaults: Dictionary = RigPortContracts.hitreact().get("defaults", {})

	# Staleness clamp (TDD 14.3): late events start partway through; events
	# older than the visual threshold are dropped unless they killed the NPC.
	var age := maxf(event.age_ms, 0.0)
	if age > float(hc_defaults.get("max_stale_ms", 250)) and not event.killed:
		_debug_drop(zone_id, "stale %.0f ms" % age)
		return

	var now := Time.get_ticks_msec()

	# Per-zone cooldown: inside the combine window hits merge (below);
	# between the window and the cooldown they're dropped outright.
	var cooldown := int(hc_defaults.get("same_zone_cooldown_ms", 120))
	var last_push := int(_last_zone_push_ms.get(zone_id, -1 << 30))
	var since_last := now - last_push
	if since_last > COMBINE_WINDOW_MS and since_last <= cooldown and not event.killed:
		_debug_drop(zone_id, "cooldown")
		return

	var strength := _compute_strength(event)
	if strength <= 0.0:
		_debug_drop(zone_id, "state '%s' gates to zero" % npc_state)
		return

	# Staggered NPCs: only heavy hits add real reactions; lighter hits become
	# small upper-body twitches (TDD 16.2).
	var force_torso := false
	if npc_state == &"staggered" and event.impulse_class != &"heavy" and not event.killed:
		strength *= float(hc_defaults.get("staggered_soft_scale", 0.35))
		force_torso = true

	var offsets := _compute_offsets(zone_id, event, strength, force_torso)
	if offsets.is_empty():
		return

	var start_ms := now - int(age)  # late events join in progress, not from t=0

	# Hits within the combine window on the same zone merge into one stronger
	# impulse instead of stacking a new reaction (TDD 13.6).
	for reaction: Dictionary in _active:
		if reaction["zone"] == zone_id and now - int(reaction["start_ms"]) <= COMBINE_WINDOW_MS:
			_combine_into(reaction, offsets, strength)
			_last_zone_push_ms[zone_id] = now
			_debug_hit(event, zone_id, strength, "combined")
			return

	# Same-zone spam outside the window is dampened.
	for reaction: Dictionary in _active:
		if reaction["zone"] == zone_id:
			strength *= SAME_ZONE_DAMPEN
			for idx: int in offsets:
				offsets[idx] = offsets[idx] * SAME_ZONE_DAMPEN
			break

	var entry := {
		"zone": zone_id,
		"start_ms": start_ms,
		"strength": strength,
		"offsets": offsets,
		"secondary": _secondary_indices(zone_id),
	}

	if _active.size() >= MAX_ACTIVE_REACTIONS:
		# New hit interrupts an old reaction only if stronger (TDD 13.6).
		var weakest_i := 0
		for i in _active.size():
			if float(_active[i]["strength"]) < float(_active[weakest_i]["strength"]):
				weakest_i = i
		if strength <= float(_active[weakest_i]["strength"]):
			return
		_active[weakest_i] = entry
	else:
		_active.append(entry)
	_last_zone_push_ms[zone_id] = now
	_debug_hit(event, zone_id, strength, "new")
	if debug_draw:
		_debug_draw_hit(event)


func clear_reactions() -> void:
	_active.clear()


func set_lod(value: int) -> void:
	lod = clampi(value, 0, 3)


func set_enabled(value: bool) -> void:
	active = value
	if not value:
		clear_reactions()


func set_profile_path(path: String) -> void:
	profile_path = path


func set_npc_state(state: StringName) -> void:
	npc_state = state


func active_reaction_count() -> int:
	return _active.size()


# ---------------------------------------------------------------------------
# modification (runs after AnimationMixer)
# ---------------------------------------------------------------------------


func _process_modification() -> void:
	if _active.is_empty():
		return
	var skeleton := get_skeleton()
	if skeleton == null:
		return

	var now := Time.get_ticks_msec()
	var delay := float(_variation.get("secondary_delay", 0.0))
	var total := _total_duration() + delay

	# Accumulate per-bone euler offsets across all active reactions,
	# clamped to the profile limits so overlapping hits can't explode the pose.
	var summed: Dictionary = {}  # idx -> Vector3 radians
	var finished: Array[int] = []
	for i in _active.size():
		var reaction: Dictionary = _active[i]
		var t := float(now - int(reaction["start_ms"])) / 1000.0
		if t > total:
			finished.append(i)
			continue
		var secondary: Dictionary = reaction["secondary"]
		var offsets: Dictionary = reaction["offsets"]
		for idx: int in offsets:
			var local_t := t - delay if secondary.has(idx) else t
			var env := _envelope(local_t)
			if env <= 0.0:
				continue
			summed[idx] = summed.get(idx, Vector3.ZERO) + offsets[idx] * env

	for i in range(finished.size() - 1, -1, -1):
		_active.remove_at(finished[i])

	for idx: int in summed:
		var v: Vector3 = summed[idx]
		var lim: Vector3 = _limits.get(skeleton.get_bone_name(idx), Vector3.ONE)
		v.x = clampf(v.x, -lim.x, lim.x)
		v.y = clampf(v.y, -lim.y, lim.y)
		v.z = clampf(v.z, -lim.z, lim.z)
		var pose := skeleton.get_bone_pose_rotation(idx)
		skeleton.set_bone_pose_rotation(idx, pose * Quaternion.from_euler(v))


# ---------------------------------------------------------------------------
# LOD 2: baked clip fallback (TDD 15)
# ---------------------------------------------------------------------------


## Resolve zone + direction + class to a Blender-baked RP_Hit_* clip and
## play/emit it. Direction snaps to the nearest baked cardinal.
func _play_baked_clip(event: RigPortHitEvent) -> void:
	var zone_id := String(event.hit_zone)
	if not _profile.get("zones", {}).has(zone_id):
		return
	var clip := _baked_clip_name(zone_id, event)
	baked_clip_requested.emit(clip, event)

	if baked_anim_player.is_empty():
		return
	var player := get_node_or_null(baked_anim_player) as AnimationPlayer
	if player == null:
		return
	if player.has_animation(String(clip)):
		player.play(String(clip))
	elif not _lod2_warned:
		push_warning("RigPortHitReactDriver: LOD 2 clip '%s' not found on '%s' — bake clips in Blender and export animations." % [clip, player.name])
		_lod2_warned = true


func _baked_clip_name(zone_id: String, event: RigPortHitEvent) -> StringName:
	var bc: Dictionary = RigPortContracts.hitreact().get("baked_clips", {})
	var skeleton := get_skeleton()
	var direction := "front"
	if skeleton != null:
		var local_dir: Vector3 = (skeleton.global_transform.basis.inverse() * event.world_hit_direction).normalized()
		if absf(local_dir.z) >= absf(local_dir.x):
			direction = "front" if local_dir.z > 0.0 else "back"
		else:
			direction = "left" if local_dir.x < 0.0 else "right"
	var class_names: Dictionary = bc.get("class_names", {})
	var cls := str(class_names.get(String(event.impulse_class), "Medium"))
	return StringName("%s_%s_%s_%s" % [
		bc.get("prefix", "RP_Hit"),
		String(zone_id).capitalize().replace(" ", ""),
		direction.capitalize(),
		cls,
	])





# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------


func _load_profile() -> void:
	_profile = {}
	_bone_idx = {}
	_limits = {}
	clear_reactions()
	var f := FileAccess.open(profile_path, FileAccess.READ)
	if f == null:
		push_warning("RigPortHitReactDriver: cannot open profile %s" % profile_path)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("zones"):
		push_warning("RigPortHitReactDriver: %s is not a hitreact profile" % profile_path)
		return
	_profile = parsed
	_timing = _profile.get("timing", {})
	_variation = _profile.get("variation", {})

	var skeleton := get_skeleton()
	if skeleton == null:
		push_warning("RigPortHitReactDriver: no parent Skeleton3D — driver must sit under the skeleton.")
		_profile = {}
		return
	# Bone cache: built once, no per-frame name lookups (TDD 23).
	var missing: Array[String] = []
	var limits_deg: Dictionary = _profile.get("limits", {})
	for bone_name: String in limits_deg:
		var idx := skeleton.find_bone(bone_name)
		if idx == -1:
			missing.append(bone_name)
			continue
		_bone_idx[bone_name] = idx
		var lim: Dictionary = limits_deg[bone_name]
		_limits[bone_name] = Vector3(
			deg_to_rad(float(lim.get("pitch", 12.0))),
			deg_to_rad(float(lim.get("yaw", 12.0))),
			deg_to_rad(float(lim.get("roll", 8.0))),
		)
	if not missing.is_empty():
		push_warning("RigPortHitReactDriver: profile bones missing on skeleton: %s" % ", ".join(missing))
	if debug_logging:
		print("HitReact: profile '%s' loaded, %d zones, %d bones cached." % [
			str(_profile.get("character", "?")), _profile.get("zones", {}).size(), _bone_idx.size()])


func _compute_strength(event: RigPortHitEvent) -> float:
	var hc: Dictionary = RigPortContracts.hitreact()
	var classes: Dictionary = hc.get("impulse_classes", {})
	var cls: Dictionary = classes.get(String(event.impulse_class), classes.get("medium", {}))
	var base := float(cls.get("strength", 0.65))
	var expected := float(expected_damage.get(event.impulse_class, 25.0))
	var damage_scale := 1.0
	if event.damage > 0.0 and expected > 0.0:
		damage_scale = clampf(event.damage / expected, 0.25, 1.5)
	# State table (TDD 13.3): dying gates to zero — the death system owns the
	# pose. Killed events bypass the table so the fatal impact still reads
	# before handoff (TDD 16.5).
	var state_scale := 1.0
	if not event.killed:
		var modifiers: Dictionary = hc.get("defaults", {}).get("state_modifiers", {})
		state_scale = float(modifiers.get(String(npc_state), 1.0))
	return base * damage_scale * state_scale * state_strength_scale


func _compute_offsets(zone_id: String, event: RigPortHitEvent, strength: float, force_torso := false) -> Dictionary:
	var skeleton := get_skeleton()
	if skeleton == null:
		return {}

	# World hit direction -> skeleton local. Character faces -Z, left = +X.
	var local_dir: Vector3 = (skeleton.global_transform.basis.inverse() * event.world_hit_direction).normalized()
	var front := clampf(local_dir.z, -1.0, 1.0)    # > 0: hit came from the front
	var side := clampf(-local_dir.x, -1.0, 1.0)    # > 0: hit came from the character's left
	if flip_front:
		front = -front
	if flip_side:
		side = -side

	# Body moves AWAY from the impact. Same sign convention as the Blender
	# preview: +pitch = forward lean, +yaw = twist left.
	var pitch_s := -front
	var yaw_s := -side
	var roll_s := -side * 0.5

	var zone: Dictionary = _profile["zones"][zone_id]
	var rng := RandomNumberGenerator.new()
	rng.seed = event.seed  # deterministic across clients (TDD 14.3)
	var noise := deg_to_rad(float(_variation.get("seeded_noise_degrees", 0.0)))
	var torso_only := lod == 1 or force_torso
	# Pelvis/leg motion is reduced while running to limit foot sliding
	# (TDD 13.6 / 16), and dropped entirely for staggered soft twitches.
	var lower_scale := 1.0
	if npc_state == &"running":
		lower_scale = float(RigPortContracts.hitreact().get("defaults", {}).get("running_lower_body_scale", 0.5))

	var offsets: Dictionary = {}
	for bones: Dictionary in [zone.get("primary_bones", {}), zone.get("secondary_bones", {})]:
		for bone_name: String in bones:
			if not _bone_idx.has(bone_name):
				continue
			var sname := StringName(bone_name)
			if torso_only and not LOD1_BONES.has(sname):
				continue
			var weight := float(bones[bone_name])
			if lower_scale < 1.0 and LOWER_BODY_BONES.has(sname):
				weight *= lower_scale
			var lim: Vector3 = _limits[bone_name]
			var v := Vector3(
				pitch_s * lim.x * weight * strength + rng.randf_range(-noise, noise) * weight,
				yaw_s * lim.y * weight * strength + rng.randf_range(-noise, noise) * weight,
				roll_s * lim.z * weight * strength,
			)
			v.x = clampf(v.x, -lim.x, lim.x)
			v.y = clampf(v.y, -lim.y, lim.y)
			v.z = clampf(v.z, -lim.z, lim.z)
			offsets[_bone_idx[bone_name]] = v
	return offsets


func _combine_into(reaction: Dictionary, new_offsets: Dictionary, new_strength: float) -> void:
	var skeleton := get_skeleton()
	var boost := 1.0 + 0.5 * new_strength
	var offsets: Dictionary = reaction["offsets"]
	for idx: int in offsets:
		var v: Vector3 = offsets[idx] * boost
		if new_offsets.has(idx):
			v += new_offsets[idx] * 0.5
		if skeleton != null:
			var lim: Vector3 = _limits.get(skeleton.get_bone_name(idx), Vector3.ONE)
			v.x = clampf(v.x, -lim.x, lim.x)
			v.y = clampf(v.y, -lim.y, lim.y)
			v.z = clampf(v.z, -lim.z, lim.z)
		offsets[idx] = v
	reaction["strength"] = maxf(float(reaction["strength"]), new_strength)


func _secondary_indices(zone_id: String) -> Dictionary:
	var out: Dictionary = {}
	var zone: Dictionary = _profile["zones"][zone_id]
	for bone_name: String in zone.get("secondary_bones", {}):
		if _bone_idx.has(bone_name):
			out[_bone_idx[bone_name]] = true
	return out


## Fast in (easeOutCubic), hold, slower out (easeInOutSine). Mirrors the
## Blender preview so what artists tuned is what plays at runtime (TDD 13.5).
func _envelope(t: float) -> float:
	var attack := float(_timing.get("attack_time", 0.04))
	var hold := float(_timing.get("hold_time", 0.05))
	var recover := float(_timing.get("recover_time", 0.22))
	if t <= 0.0:
		return 0.0
	if t < attack:
		var x := t / attack
		return 1.0 - pow(1.0 - x, 3.0)
	if t < attack + hold:
		return 1.0
	if t < attack + hold + recover:
		var x := (t - attack - hold) / recover
		return 1.0 - (-(cos(PI * x) - 1.0) / 2.0)
	return 0.0


func _total_duration() -> float:
	return float(_timing.get("attack_time", 0.04)) \
		+ float(_timing.get("hold_time", 0.05)) \
		+ float(_timing.get("recover_time", 0.22))


func _debug_drop(zone_id: String, reason: String) -> void:
	if debug_logging:
		print("HitReact: dropped %s hit (%s)" % [zone_id, reason])


func _debug_hit(event: RigPortHitEvent, zone_id: String, strength: float, kind: String) -> void:
	if debug_logging:
		print("HitReact: %s / %s / seed %d / strength %.2f / %s / LOD %d / active %d" % [
			zone_id, String(event.impulse_class), event.seed, strength, kind, lod, _active.size()])


## Impact point marker: incoming direction in red, local reaction vector in
## green. Self-frees after 0.5 s. Visual aid only — never ship enabled.
func _debug_draw_hit(event: RigPortHitEvent) -> void:
	var skeleton := get_skeleton()
	if skeleton == null or not is_inside_tree():
		return
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true

	var origin := event.world_hit_position
	var incoming := event.world_hit_direction.normalized() * 0.4
	var reaction := (skeleton.global_transform.basis * -(
		skeleton.global_transform.basis.inverse() * event.world_hit_direction
	).normalized()) * 0.3

	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	mesh.surface_set_color(Color.RED)
	mesh.surface_add_vertex(origin - incoming)
	mesh.surface_add_vertex(origin)
	mesh.surface_set_color(Color.GREEN)
	mesh.surface_add_vertex(origin)
	mesh.surface_add_vertex(origin + reaction)
	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.top_level = true
	add_child(mi)
	mi.global_transform = Transform3D.IDENTITY
	get_tree().create_timer(0.5).timeout.connect(mi.queue_free)
