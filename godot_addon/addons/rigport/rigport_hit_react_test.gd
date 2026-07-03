class_name RigPortHitReactTest
extends Node3D
## Keyboard smoke test for HitReact. Add as a sibling/parent of a RigPort
## character that has a RigPortHitReactReceiver, run the scene, and fire
## fake gunshot events:
##
##   1  Hit Head Front        5  Hit Pelvis Front
##   2  Hit Head Back         6  Rapid Fire Chest (5 rounds)
##   3  Hit Chest Left        7  Kill Shot Head
##   4  Hit Chest Right       8  Cycle LOD 0-3
##   9  Reset (clear reactions + revive)
##   0  Cycle NPC state (idle → walking → running → aiming → in_cover → staggered)
##   -  Knockdown (heavy chest hit, server-flagged stagger → likely fall)
##
## Directions are computed from the character's facing (-Z forward), so the
## test is orientation-independent. Seeds are randomized per shot and printed
## so any reaction can be replayed deterministically.

@export var receiver_path: NodePath
@export var impulse_class: StringName = &"medium"
@export var damage := 25.0
## Set by the dock's Create HitReact Test Scene — instantiated on ready.
@export var character_scene: PackedScene

const STATES: Array[StringName] = [&"idle", &"walking", &"running", &"aiming", &"in_cover", &"staggered"]

var _receiver: RigPortHitReactReceiver
var _rng := RandomNumberGenerator.new()
var _state_i := 0


func _ready() -> void:
	_rng.randomize()
	if character_scene != null:
		var character := character_scene.instantiate()
		add_child(character)
		var cam := Camera3D.new()
		cam.position = Vector3(0, 1.5, 3.5)
		cam.look_at_from_position(cam.position, Vector3(0, 1.2, 0))
		add_child(cam)
		add_child(DirectionalLight3D.new())
	_receiver = get_node_or_null(receiver_path) as RigPortHitReactReceiver
	if _receiver == null:
		var found := find_children("*", "RigPortHitReactReceiver", true, false)
		if found.is_empty() and get_parent() != null:
			found = get_parent().find_children("*", "RigPortHitReactReceiver", true, false)
		if not found.is_empty():
			_receiver = found[0]
	if _receiver == null:
		push_warning("RigPortHitReactTest: no RigPortHitReactReceiver found.")
		return
	var st := _receiver.stumble()
	if st != null:
		st.stumble_started.connect(func(_dir: Vector3) -> void: print("  -> stumble started"))
		st.fell.connect(func() -> void: print("  -> FELL"))
		st.recovered.connect(func() -> void: print("  -> recovered"))
		st.recovery_step_requested.connect(func(dir: Vector3, dist: float) -> void:
			print("  -> recovery step %.2fm along %v" % [dist, dir]))
	print("HitReact test ready. 1-5 zone hits, 6 rapid fire, 7 kill shot, 8 LOD cycle, 9 reset, 0 state, - knockdown.")


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or _receiver == null:
		return
	match key.keycode:
		KEY_1: _fire(&"head", _dir_from(&"front"))
		KEY_2: _fire(&"head", _dir_from(&"back"))
		KEY_3: _fire(&"chest", _dir_from(&"left"))
		KEY_4: _fire(&"chest", _dir_from(&"right"))
		KEY_5: _fire(&"pelvis", _dir_from(&"front"))
		KEY_6: _rapid_fire()
		KEY_7: _fire(&"head", _dir_from(&"front"), true)
		KEY_8: _cycle_lod()
		KEY_9: _reset()
		KEY_0: _cycle_state()
		KEY_MINUS: _knockdown()


func _knockdown() -> void:
	# Heavy chest hit from the front — enough to cross the fall threshold on
	# most presets, or explicitly flag the fall for a guaranteed knockdown.
	var hit_seed := _rng.randi_range(0, 9999)
	print("HitReact test: KNOCKDOWN chest / heavy / seed %d" % hit_seed)
	_receiver.apply_gunshot_hit(&"chest", Vector3.ZERO, _dir_from(&"front"), 80.0, &"heavy", hit_seed, false, true)
	_report_stumble()


func _report_stumble() -> void:
	var st := _receiver.stumble()
	if st != null:
		print("  stumble state: %s" % st.state_name())


## Bullet travel direction for a hit coming FROM the named side of the
## character. Character faces -Z: a shot from the front travels toward +Z
## in character space.
func _dir_from(side: StringName) -> Vector3:
	var basis := _character_basis()
	match side:
		&"front": return basis * Vector3(0, 0, 1)
		&"back": return basis * Vector3(0, 0, -1)
		&"left": return basis * Vector3(-1, 0, 0)   # from character's left, travelling right
		&"right": return basis * Vector3(1, 0, 0)
	return basis * Vector3(0, 0, 1)


func _character_basis() -> Basis:
	var host := _receiver.get_parent()
	if host is Node3D:
		return (host as Node3D).global_transform.basis
	return global_transform.basis


func _fire(zone: StringName, direction: Vector3, killed := false) -> void:
	var hit_seed := _rng.randi_range(0, 9999)
	print("HitReact test: %s / %s / seed %d%s" % [zone, impulse_class, hit_seed, " / KILL" if killed else ""])
	_receiver.apply_gunshot_hit(zone, Vector3.ZERO, direction, damage, impulse_class, hit_seed, killed)


func _rapid_fire() -> void:
	for i in 5:
		var dir := _dir_from(&"front" if i % 2 == 0 else &"left")
		get_tree().create_timer(i * 0.06).timeout.connect(_fire.bind(&"chest", dir))


func _cycle_lod() -> void:
	var driver := _receiver.driver()
	if driver == null:
		return
	driver.set_lod((driver.lod + 1) % 4)
	print("HitReact test: LOD -> %d" % driver.lod)


func _cycle_state() -> void:
	_state_i = (_state_i + 1) % STATES.size()
	_receiver.set_npc_state(STATES[_state_i])
	print("HitReact test: NPC state -> %s" % STATES[_state_i])


func _reset() -> void:
	var driver := _receiver.driver()
	if driver != null:
		driver.clear_reactions()
	_receiver.revive()
	_state_i = 0
	print("HitReact test: reactions cleared, character revived, state idle.")
