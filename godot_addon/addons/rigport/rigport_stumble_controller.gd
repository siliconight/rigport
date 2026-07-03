class_name RigPortStumbleController
extends SkeletonModifier3D
## Balance, stumble, and fall — the layer above HitReact flinch (v0.3).
##
## Sits under the same Skeleton3D as RigPortHitReactDriver, AFTER it in child
## order, so its whole-body lean composes on top of the flinch. Accumulates a
## mass-weighted balance impulse from hits, and when balance crosses the
## profile thresholds the NPC staggers (lean + optional recovery step) or
## falls (optional partial ragdoll). Requires Godot 4.3+.
##
## Authority model (matches HitReact):
##   - Server flags win: event.stagger forces a stagger, event.killed forces
##     a fall. Gameplay stays authoritative over whether an NPC goes down.
##   - The local balance model is a visual amplifier that ALSO triggers
##     stumbles when no server flag is set (single-player, local testing).
##
## Capsule movement is NOT done here. A recovery step emits
## recovery_step_requested(local_dir, distance); the CharacterBody3D mover
## honors or ignores it. This node only moves the visual skeleton.

enum State { BALANCED, STAGGER, RECOVER, FALLING, DOWN }

## Profile that carries the stumble block (usually the same .hitreact.json
## as the HitReact driver). If empty, the driver's profile is reused.
@export_file("*.hitreact.json", "*.json") var profile_path := ""
## Optional PhysicalBoneSimulator3D for the fall ragdoll. If unset, falls
## play as a procedural collapse and emit `fell` for gameplay to handle.
@export var physical_bone_simulator: NodePath
## Multiply incoming balance impulse. 1.0 = use profile values as-is.
@export_range(0.0, 3.0) var sensitivity := 1.0
@export var debug_logging := false

signal stumble_started(direction: Vector3)
signal recovery_step_requested(local_direction: Vector3, distance: float)
signal fell()
signal recovered()

var _stumble: Dictionary = {}
var _lean_bones: Dictionary = {}      # bone name -> weight
var _lean_idx: Dictionary = {}        # bone name -> skeleton bone index
var _fall_bone_names: PackedStringArray = []
var _mass_hints: Dictionary = {}
var _total_mass := 80.0

var _state: int = State.BALANCED
var _balance := Vector3.ZERO          # local-space horizontal lean accumulator
var _state_time := 0.0
var _lean_dir := Vector3.ZERO         # frozen balance direction for the active stumble
var _lean_amount := 0.0               # 0..1 current lean strength, applied in modification
var _sim: PhysicalBoneSimulator3D


func _ready() -> void:
	_load()
	set_physics_process(true)


func _load() -> void:
	var profile := _read_profile()
	if profile.is_empty():
		var driver := _find_driver()
		if driver != null:
			profile = _read_profile_from(str(driver.get("profile_path")))
	if profile.is_empty():
		push_warning("RigPortStumbleController: no profile with a stumble block found.")
		return

	_stumble = profile.get("stumble", {})
	if _stumble.is_empty():
		push_warning("RigPortStumbleController: profile has no stumble block — re-export with RigPort 0.3+.")
		return

	var physics: Dictionary = profile.get("physics", {})
	_mass_hints = physics.get("mass_hints_kg", {})
	_total_mass = float(physics.get("total_mass_kg", 80.0))
	_fall_bone_names = PackedStringArray(_stumble.get("fall_bones", []))

	var skeleton := get_skeleton()
	if skeleton == null:
		push_warning("RigPortStumbleController: no parent Skeleton3D.")
		return
	_lean_bones = _stumble.get("lean_bones", {})
	_lean_idx.clear()
	for bone_name: String in _lean_bones:
		var idx := skeleton.find_bone(bone_name)
		if idx != -1:
			_lean_idx[bone_name] = idx

	if not physical_bone_simulator.is_empty():
		_sim = get_node_or_null(physical_bone_simulator) as PhysicalBoneSimulator3D


# ---------------------------------------------------------------------------
# public API — called by the receiver (or gameplay directly)
# ---------------------------------------------------------------------------


## Feed a hit into the balance model. The receiver calls this alongside the
## HitReact driver push, so one apply_hit() drives both flinch and balance.
func push_balance_impulse(event: RigPortHitEvent) -> void:
	if _stumble.is_empty() or _state == State.DOWN:
		return
	var skeleton := get_skeleton()
	if skeleton == null:
		return

	# Local-space push direction: the body is shoved AWAY from the incoming
	# round, weighted by how much mass the struck zone carries (a pelvis hit
	# unbalances more than a hand hit).
	var local_dir: Vector3 = (skeleton.global_transform.basis.inverse() * event.world_hit_direction)
	local_dir.y = 0.0
	if local_dir.length_squared() < 1e-6:
		return
	local_dir = local_dir.normalized()

	var scale_map: Dictionary = _stumble.get("impulse_scale", {})
	var magnitude := float(scale_map.get(String(event.impulse_class), 0.55))
	magnitude *= _zone_mass_factor(event.hit_zone)
	magnitude *= sensitivity
	_balance += local_dir * magnitude

	# Server authority: explicit flags trigger regardless of accumulation.
	if event.killed:
		_enter_fall(local_dir)
	elif event.stagger:
		_enter_stagger(local_dir)
	_debug("impulse %s -> balance %.2f" % [event.impulse_class, _balance.length()])


func state_name() -> StringName:
	return [&"balanced", &"stagger", &"recover", &"falling", &"down"][_state]


func is_down() -> bool:
	return _state == State.DOWN


## Gameplay revive: stop any ragdoll, blend back to neutral.
func get_up() -> void:
	if _sim != null and _sim.is_simulating_physics():
		_sim.physical_bones_stop_simulation()
	_state = State.BALANCED
	_balance = Vector3.ZERO
	_lean_amount = 0.0
	recovered.emit()


func reset() -> void:
	get_up()


# ---------------------------------------------------------------------------
# state machine (physics thread-safe: no pose writes here)
# ---------------------------------------------------------------------------


func _physics_process(delta: float) -> void:
	if _stumble.is_empty():
		return

	# Passive balance recovery.
	var decay := float(_stumble.get("balance_decay_per_sec", 1.7)) * delta
	var bl := _balance.length()
	if bl > 0.0:
		_balance = _balance * maxf(0.0, (bl - decay) / bl)

	_state_time += delta
	match _state:
		State.BALANCED:
			if _balance.length() >= float(_stumble.get("fall_threshold", 2.4)):
				_enter_fall(_balance.normalized())
			elif _balance.length() >= float(_stumble.get("balance_threshold", 1.0)):
				_enter_stagger(_balance.normalized())
		State.STAGGER:
			_lean_amount = 1.0
			if _state_time >= float(_stumble.get("stagger_duration", 0.55)):
				_request_recovery_step()
				_set_state(State.RECOVER)
		State.RECOVER:
			var dur := float(_stumble.get("recover_duration", 0.5))
			_lean_amount = clampf(1.0 - _state_time / dur, 0.0, 1.0)
			if _state_time >= dur:
				_balance = Vector3.ZERO
				_lean_amount = 0.0
				_set_state(State.BALANCED)
				recovered.emit()
		State.FALLING:
			if _state_time >= float(_stumble.get("fall_duration", 0.9)):
				_set_state(State.DOWN)
		State.DOWN:
			pass  # gameplay decides when to get_up()


func _enter_stagger(direction: Vector3) -> void:
	if _state == State.STAGGER or _state == State.FALLING or _state == State.DOWN:
		# Re-stagger only refreshes the direction/timer if already staggering.
		if _state == State.STAGGER:
			_lean_dir = direction
			_state_time = 0.0
		return
	_lean_dir = direction
	_set_state(State.STAGGER)
	stumble_started.emit(direction)
	_debug("STAGGER")


func _enter_fall(direction: Vector3) -> void:
	if _state == State.FALLING or _state == State.DOWN:
		return
	_lean_dir = direction
	_set_state(State.FALLING)
	_lean_amount = 1.0
	_start_ragdoll()
	fell.emit()
	_debug("FALL")


func _set_state(next: int) -> void:
	_state = next
	_state_time = 0.0


func _request_recovery_step() -> void:
	var dist := _balance.length() * float(_stumble.get("recovery_step_max_m", 0.55))
	dist = minf(dist, float(_stumble.get("recovery_step_max_m", 0.55)))
	if dist > 0.02 and _lean_dir.length_squared() > 0.0:
		recovery_step_requested.emit(_lean_dir.normalized(), dist)


func _start_ragdoll() -> void:
	if _sim == null:
		return
	if _fall_bone_names.is_empty():
		_sim.physical_bones_start_simulation()
	else:
		_sim.physical_bones_start_simulation(_fall_bone_names)


func _zone_mass_factor(zone: StringName) -> float:
	# Heavier struck regions unbalance more. Normalize against ~14% of body
	# mass (a torso-ish reference) so the factor sits near 1.0 for a chest hit.
	var bone := {
		&"head": "Head", &"chest": "Chest", &"pelvis": "Hips",
		&"left_arm": "LeftUpperArm", &"right_arm": "RightUpperArm",
		&"left_leg": "LeftUpperLeg", &"right_leg": "RightUpperLeg",
	}.get(zone, "Chest")
	var m := float(_mass_hints.get(bone, _total_mass * 0.14))
	return clampf(m / (_total_mass * 0.14), 0.5, 1.6)


# ---------------------------------------------------------------------------
# pose application (runs after HitReact in the modifier stack)
# ---------------------------------------------------------------------------


func _process_modification() -> void:
	if _lean_amount <= 0.0 or _lean_dir.length_squared() < 1e-6 or active == false:
		return
	# Physical bones own the pose while simulating — don't fight the ragdoll.
	if _sim != null and _sim.is_simulating_physics():
		return
	var skeleton := get_skeleton()
	if skeleton == null:
		return

	var lean_max := deg_to_rad(float(_stumble.get("lean_max_degrees", 24.0)))
	# Lean the body along the push direction: forward/back push -> pitch,
	# lateral push -> roll. Same -Z-forward, +X-left convention as the driver.
	var pitch := _lean_dir.z * lean_max * _lean_amount
	var roll := -_lean_dir.x * lean_max * _lean_amount

	for bone_name: String in _lean_idx:
		var weight := float(_lean_bones[bone_name])
		var idx: int = _lean_idx[bone_name]
		var euler := Vector3(pitch * weight, 0.0, roll * weight)
		var pose := skeleton.get_bone_pose_rotation(idx)
		skeleton.set_bone_pose_rotation(idx, pose * Quaternion.from_euler(euler))


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


func _find_driver() -> Node:
	var skeleton := get_skeleton()
	if skeleton == null:
		return null
	var script := load("res://addons/rigport/rigport_hit_react_driver.gd")
	for child: Node in skeleton.get_children():
		if child.get_script() == script:
			return child
	return null


func _read_profile() -> Dictionary:
	return _read_profile_from(profile_path)


func _read_profile_from(path: String) -> Dictionary:
	if path.is_empty():
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _debug(msg: String) -> void:
	if debug_logging:
		print("Stumble[%s]: %s" % [state_name(), msg])
