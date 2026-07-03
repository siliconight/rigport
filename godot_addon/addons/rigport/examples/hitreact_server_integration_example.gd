extends Node
## EXAMPLE — server-authoritative HitReact integration (TDD section 14).
## Not registered by the plugin; copy into your game and adapt.
##
## Authority split:
##   SERVER  validates the shot, computes damage/armor, decides stagger and
##           death, updates AI — then replicates one compact hit payload.
##   CLIENTS reconstruct a RigPortHitEvent and play the visual reaction.
##           The server never simulates procedural bones; a headless server
##           has no RigPortHitReactDriver at all.
##
## Attach to a game-level "combat manager" node with multiplayer authority.
## `npc_root(npc_id)` is your lookup from replicated id -> character root.

## Ticks per second of your server simulation — used to age late events.
const SERVER_TICK_RATE := 30.0

## damage band -> impulse class (open decision 3: weapons map to impulse
## through damage config, not weapon type directly).
const DAMAGE_BANDS := [
	{"max": 15.0, "class": &"small"},
	{"max": 35.0, "class": &"medium"},
	{"max": 1.0e9, "class": &"heavy"},
]

var _current_tick := 0


func _physics_process(_delta: float) -> void:
	if multiplayer.is_server():
		_current_tick += 1


## SERVER: call after your raycast/projectile hit has been validated and
## damage fully resolved (armor, falloff, headshot multipliers...).
func server_register_hit(
	npc_id: int,
	hit_zone: StringName,
	world_hit_position: Vector3,
	world_hit_direction: Vector3,
	final_damage: float,
	killed: bool,
	stagger: bool,
) -> void:
	if not multiplayer.is_server():
		return
	var payload := {
		"npc_id": npc_id,
		"zone": String(hit_zone),
		"pos": world_hit_position,
		"dir": world_hit_direction,
		"class": String(_impulse_class_for(final_damage)),
		"damage_band": snappedf(final_damage, 5.0),  # band, not exact damage
		"seed": randi() % 10000,                     # server-owned seed (TDD 14.3)
		"tick": _current_tick,
		"killed": killed,
		"stagger": stagger,
	}
	_client_play_hit.rpc(payload)
	# Server-side consequences (AI aggro, stagger state, death) happen here,
	# in your own systems — never inside the visual driver.


## CLIENTS: reconstruct the event and hand it to the character's receiver.
@rpc("authority", "call_local", "unreliable_ordered")
func _client_play_hit(payload: Dictionary) -> void:
	if multiplayer.is_server() and DisplayServer.get_name() == "headless":
		return  # dedicated server: no visual playback (TDD 24.3)
	var root := npc_root(int(payload.get("npc_id", -1)))
	if root == null:
		return
	var receiver := root.find_children("*", "RigPortHitReactReceiver", true, false)
	if receiver.is_empty():
		return

	var event := RigPortHitEvent.create(
		StringName(str(payload.get("zone", "chest"))),
		payload.get("pos", Vector3.ZERO),
		payload.get("dir", Vector3.FORWARD),
		float(payload.get("damage_band", 25.0)),
		StringName(str(payload.get("class", "medium"))),
		int(payload.get("seed", 0)),
		bool(payload.get("killed", false)),
		bool(payload.get("stagger", false)),
	)
	event.server_tick = int(payload.get("tick", 0))
	# Age the event so late arrivals join in progress and stale ones drop
	# (the driver clamps against the contract max_stale_ms).
	event.age_ms = maxf(float(_current_tick - event.server_tick), 0.0) / SERVER_TICK_RATE * 1000.0

	(receiver[0] as RigPortHitReactReceiver).apply_hit(event)

	if bool(payload.get("killed", false)):
		# Hand off to your death system AFTER the fatal impact frame lands.
		# e.g. death_system.begin_death(root, event)
		pass


func _impulse_class_for(damage: float) -> StringName:
	for band: Dictionary in DAMAGE_BANDS:
		if damage <= float(band["max"]):
			return band["class"]
	return &"medium"


## Replace with your game's replicated-id -> character-root lookup.
func npc_root(_npc_id: int) -> Node:
	return null
