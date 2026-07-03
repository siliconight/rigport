class_name RigPortHitEvent
extends RefCounted
## One gunshot hit, as decided by the server / damage system.
##
## The damage system should not pass raw weapon internals — it builds one of
## these and hands it to RigPortHitReactReceiver.apply_hit(). Clients replay
## the same event with the same seed and see the same visual reaction.

var hit_zone: StringName = &""
var world_hit_position := Vector3.ZERO
## Direction the projectile was travelling (into the character), world space.
var world_hit_direction := Vector3.FORWARD
var world_surface_normal := Vector3.UP
var damage := 0.0
## One of the contract impulse classes: &"small", &"medium", &"heavy".
var impulse_class: StringName = &"medium"
var weapon_tag: StringName = &""
## Server-provided seed — same seed reproduces the same reaction on every client.
var seed: int = 0
var server_tick: int = 0
var killed := false
var stagger := false
## Network delay in ms (set by the replication layer from server_tick).
## Late events start partway through; stale ones are dropped unless killed.
var age_ms := 0.0


static func create(
	zone: StringName,
	position: Vector3,
	direction: Vector3,
	hit_damage: float,
	hit_impulse_class: StringName,
	hit_seed: int,
	hit_killed := false,
	hit_stagger := false,
) -> RigPortHitEvent:
	var e := RigPortHitEvent.new()
	e.hit_zone = zone
	e.world_hit_position = position
	e.world_hit_direction = direction.normalized() if direction.length_squared() > 0.0 else Vector3.FORWARD
	e.damage = hit_damage
	e.impulse_class = hit_impulse_class
	e.seed = hit_seed
	e.killed = hit_killed
	e.stagger = hit_stagger
	return e
