class_name RigPortHitReactReceiver
extends Node
## Clean gameplay API for hit reactions. Lives on the character root.
##
## The damage system calls apply_hit() (or the apply_gunshot_hit()
## convenience) — the receiver gates by character state and forwards to the
## RigPortHitReactDriver under the Skeleton3D. Server stays authoritative
## over damage, stagger, and death; this is visual playback only.
##
## Phase 2 reference implementation — game code is expected to wrap or
## replace this with its own damage plumbing.

## Optional explicit driver path; auto-found under the parent when empty.
@export var driver_path: NodePath
## Optional game hitbox name -> RigPort zone translation,
## e.g. {"Hitbox_Head": "head", "head_col": "head"}.
@export var zone_aliases: Dictionary = {}
## Set by gameplay when the character dies. Dead characters ignore
## everything except the killing event itself.
var is_dead := false

var _driver: RigPortHitReactDriver
var _stumble: RigPortStumbleController


func _ready() -> void:
	_driver = get_node_or_null(driver_path) as RigPortHitReactDriver
	if _driver == null:
		var host := get_parent() if get_parent() != null else self
		var found := host.find_children("*", "RigPortHitReactDriver", true, false)
		if not found.is_empty():
			_driver = found[0]
	if _driver == null:
		push_warning("RigPortHitReactReceiver: no RigPortHitReactDriver found under the character.")
	# Optional v0.3 stumble layer — forwarded alongside the flinch when present.
	var host2 := get_parent() if get_parent() != null else self
	var st := host2.find_children("*", "RigPortStumbleController", true, false)
	if not st.is_empty():
		_stumble = st[0]


## The one gameplay-facing method (TDD 12.4).
func apply_hit(event: RigPortHitEvent) -> void:
	if _driver == null or event == null:
		return
	if is_dead and not event.killed:
		return
	var host := get_parent()
	if host is Node3D and not (host as Node3D).visible:
		return
	var zone := String(event.hit_zone)
	if zone_aliases.has(zone):
		event.hit_zone = StringName(String(zone_aliases[zone]))
	if event.killed:
		is_dead = true
	_driver.push_hit(event)
	if _stumble != null:
		_stumble.push_balance_impulse(event)


## Convenience wrapper matching TDD 21.1.
func apply_gunshot_hit(
	hit_zone: StringName,
	world_hit_position: Vector3,
	world_hit_direction: Vector3,
	damage: float,
	impulse_class: StringName,
	hit_seed: int,
	killed := false,
	stagger := false,
) -> void:
	apply_hit(RigPortHitEvent.create(
		hit_zone, world_hit_position, world_hit_direction,
		damage, impulse_class, hit_seed, killed, stagger,
	))


func set_dead(value: bool) -> void:
	# The killing impact itself still plays (gated in apply_hit); gameplay
	# hands off to death animation / ragdoll after that.
	is_dead = value
	if value:
		set_npc_state(&"dying")


func revive() -> void:
	is_dead = false
	set_npc_state(&"idle")
	if _driver != null:
		_driver.clear_reactions()
	if _stumble != null:
		_stumble.get_up()


func stumble() -> RigPortStumbleController:
	return _stumble


## Forward the AI/locomotion state to the driver (idle, walking, running,
## aiming, in_cover, staggered, dying) — scales reaction strength.
func set_npc_state(state: StringName) -> void:
	if _driver != null:
		_driver.set_npc_state(state)


func driver() -> RigPortHitReactDriver:
	return _driver
