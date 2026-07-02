class_name RigPortVOMouthDriver
extends Node
## Connects an AudioStreamPlayer3D voice line to mouth blend shape movement.
##
## Modes:
##   - Amplitude flap (MVP): bus loudness drives Mouth_Open. LOD 1 smooth, LOD 2 cheap.
##   - Timed visemes (LOD 0): plays a RigPort viseme sidecar JSON against playback position.
##   - LOD 3: mouth stays neutral; only audio plays.
##
## For accurate amplitude, route the voice player to a dedicated audio bus
## (e.g. "Voice") — the driver reads that bus's peak level.

@export var mesh_path: NodePath
@export var audio_player_path: NodePath
@export_range(0, 3) var mouth_lod: int = 1:
	set(value):
		mouth_lod = clampi(value, 0, 3)
@export var gain := 2.5
@export var attack_speed := 18.0
@export var release_speed := 8.0
## LOD 2 cheap flap: open amount snaps to this when the line is loud, else closed.
@export var cheap_flap_open := 0.85
@export var cheap_flap_threshold := 0.30
## Optional viseme sidecar JSON ({"visemes":[{"time","shape","value"},...]}) for LOD 0.
@export_file("*.json") var viseme_sidecar_path := ""

var _mesh: MeshInstance3D
var _player: AudioStreamPlayer3D
var _bus_idx := -1
var _open_idx := -1
var _viseme_idx: Dictionary = {}  # shape name -> blend shape index
var _events: Array = []
var _open_value := 0.0
var _accum := 0.0
var _neutralized := false

const _LOD_RATES := {0: 60.0, 1: 30.0, 2: 10.0, 3: 0.0}
const _VISEME_SHAPES := [
	"Viseme_REST", "Viseme_AA", "Viseme_EE", "Viseme_OH", "Viseme_FV", "Viseme_MBP", "Viseme_L",
]


func _ready() -> void:
	_mesh = get_node_or_null(mesh_path) as MeshInstance3D
	_player = get_node_or_null(audio_player_path) as AudioStreamPlayer3D
	var host := get_parent() if get_parent() != null else self
	if _mesh == null:
		for mi: MeshInstance3D in host.find_children("*", "MeshInstance3D", true, false):
			if mi.find_blend_shape_by_name("Mouth_Open") != -1:
				_mesh = mi
				break
	if _player == null:
		var found := host.find_children("*", "AudioStreamPlayer3D", true, false)
		if not found.is_empty():
			_player = found[0]
	if _mesh == null:
		push_warning("RigPortVOMouthDriver: no mesh with a Mouth_Open blend shape found.")
		set_process(false)
		return
	_open_idx = _mesh.find_blend_shape_by_name("Mouth_Open")
	for shape: String in _VISEME_SHAPES:
		var idx := _mesh.find_blend_shape_by_name(shape)
		if idx != -1:
			_viseme_idx[shape] = idx
	if _player == null:
		push_warning("RigPortVOMouthDriver: no AudioStreamPlayer3D found — mouth will stay neutral.")
	if viseme_sidecar_path != "":
		_load_sidecar(viseme_sidecar_path)


func _process(delta: float) -> void:
	if _mesh == null:
		return
	if mouth_lod >= 3:
		if not _neutralized:
			_reset_mouth()
			_neutralized = true
		return
	_neutralized = false

	var rate: float = _LOD_RATES.get(mouth_lod, 30.0)
	_accum += delta
	if _accum < 1.0 / rate:
		return
	var step := _accum
	_accum = 0.0

	if mouth_lod == 0 and not _events.is_empty():
		_update_timed(step)
	else:
		_update_amplitude(step)


func _update_amplitude(step: float) -> void:
	var target := 0.0
	if _player != null and _player.playing:
		_bus_idx = AudioServer.get_bus_index(_player.bus)
		if _bus_idx != -1:
			var peak_db := AudioServer.get_bus_peak_volume_left_db(_bus_idx, 0)
			target = clampf(db_to_linear(clampf(peak_db, -60.0, 0.0)) * gain, 0.0, 1.0)
	if mouth_lod == 2:
		target = cheap_flap_open if target > cheap_flap_threshold else 0.0
	var speed := attack_speed if target > _open_value else release_speed
	_open_value = move_toward(_open_value, target, speed * step)
	if _open_idx != -1:
		_mesh.set_blend_shape_value(_open_idx, _open_value)


func _update_timed(step: float) -> void:
	if _player == null or not _player.playing:
		_decay_all(step)
		return
	var pos := _player.get_playback_position()
	var active := ""
	var active_value := 1.0
	for event: Dictionary in _events:
		if float(event.get("time", 0.0)) <= pos:
			active = str(event.get("shape", ""))
			active_value = float(event.get("value", 1.0))
		else:
			break
	for shape: String in _viseme_idx:
		var idx: int = _viseme_idx[shape]
		var target := active_value if shape == active else 0.0
		var current := _mesh.get_blend_shape_value(idx)
		_mesh.set_blend_shape_value(idx, move_toward(current, target, attack_speed * step))


func _decay_all(step: float) -> void:
	var done := true
	if _open_idx != -1:
		_open_value = move_toward(_open_value, 0.0, release_speed * step)
		_mesh.set_blend_shape_value(_open_idx, _open_value)
		done = done and is_zero_approx(_open_value)
	for shape: String in _viseme_idx:
		var idx: int = _viseme_idx[shape]
		var v := move_toward(_mesh.get_blend_shape_value(idx), 0.0, release_speed * step)
		_mesh.set_blend_shape_value(idx, v)
		done = done and is_zero_approx(v)


func _reset_mouth() -> void:
	_open_value = 0.0
	if _open_idx != -1:
		_mesh.set_blend_shape_value(_open_idx, 0.0)
	for shape: String in _viseme_idx:
		_mesh.set_blend_shape_value(_viseme_idx[shape], 0.0)


func _load_sidecar(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("RigPortVOMouthDriver: cannot open sidecar %s" % path)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("visemes"):
		push_warning("RigPortVOMouthDriver: %s is not a viseme sidecar" % path)
		return
	_events = parsed["visemes"]
	_events.sort_custom(func(a, b): return float(a.get("time", 0.0)) < float(b.get("time", 0.0)))


## True when every driven mouth shape has returned to neutral.
func is_mouth_neutral() -> bool:
	if _mesh == null:
		return true
	if _open_idx != -1 and absf(_mesh.get_blend_shape_value(_open_idx)) > 0.02:
		return false
	for shape: String in _viseme_idx:
		if absf(_mesh.get_blend_shape_value(_viseme_idx[shape])) > 0.02:
			return false
	return true


## Peak mouth-open value since the last call — used by the smoke test.
func current_open_value() -> float:
	return _open_value
