extends Node3D
## RigPort VO mouth smoke test scene. Run it (F6).
##
## Spawns the character, plays a voice line (the provided stream, or a
## generated speech-like noise burst if none is set), and prints PASS/FAIL for:
##   1. the mouth moves while VO plays
##   2. the mouth returns to neutral after VO stops

const DRIVER_SCRIPT := preload("res://addons/rigport/rigport_vo_mouth_driver.gd")

@export var character_scene: PackedScene
@export var voice_stream: AudioStream
@export var test_duration := 3.0
@export var mouth_lod := 1

var _character: Node
var _driver: Node
var _player: AudioStreamPlayer3D
var _playback: AudioStreamGeneratorPlayback
var _generated := false
var _gen_t := 0.0
var _mix_rate := 22050.0
var _phase := 0  # 0 speaking, 1 settling, 2 done
var _timer := 0.0
var _max_open := 0.0


func _ready() -> void:
	if character_scene == null:
		push_error("RigPort VO test: no character_scene assigned.")
		get_tree().quit(1)
		return
	_character = character_scene.instantiate()
	add_child(_character)

	var players := _character.find_children("*", "AudioStreamPlayer3D", true, false)
	if players.is_empty():
		_player = AudioStreamPlayer3D.new()
		_player.name = "VoiceAudio"
		_character.add_child(_player)
	else:
		_player = players[0]

	if voice_stream == null:
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = _mix_rate
		gen.buffer_length = 0.2
		_player.stream = gen
		_generated = true
	else:
		_player.stream = voice_stream
		test_duration = maxf(test_duration, voice_stream.get_length())

	for child: Node in _character.find_children("*", "Node", true, false):
		if child.get_script() == DRIVER_SCRIPT:
			_driver = child
			break
	if _driver == null:
		_driver = DRIVER_SCRIPT.new()
		_driver.name = "RigPortVOMouthDriver"
		_character.add_child(_driver)
	_driver.mouth_lod = mouth_lod

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.6, 2.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, 1.5, 0.0))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	add_child(light)

	_player.play()
	if _generated:
		_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback as AudioStreamGeneratorPlayback
	print("=== RigPort VO Mouth Smoke Test: %s ===" % _character.name)


func _process(delta: float) -> void:
	if _driver != null and _driver.has_method("current_open_value"):
		_max_open = maxf(_max_open, _driver.current_open_value())

	match _phase:
		0:
			_timer += delta
			if _generated and _playback != null:
				_fill_generator()
			if _timer >= test_duration or (not _generated and not _player.playing):
				_player.stop()
				_phase = 1
				_timer = 0.0
		1:
			_timer += delta
			if _timer >= 1.0:
				_report()
				_phase = 2
		2:
			pass


func _fill_generator() -> void:
	while _playback.get_frames_available() > 0:
		# Speech-shaped noise: fast syllable flap under a slow loudness wave.
		var envelope := absf(sin(_gen_t * TAU * 3.2)) * (0.35 + 0.65 * absf(sin(_gen_t * TAU * 0.9)))
		var sample := (randf() * 2.0 - 1.0) * 0.6 * envelope
		_playback.push_frame(Vector2(sample, sample))
		_gen_t += 1.0 / _mix_rate


func _report() -> void:
	var moved := _max_open > 0.05
	var neutral: bool = _driver.is_mouth_neutral() if _driver.has_method("is_mouth_neutral") else false
	print("Mouth moved during VO:      %s (peak open %.2f)" % ["PASS" if moved else "FAIL", _max_open])
	print("Mouth returned to neutral:  %s" % ("PASS" if neutral else "FAIL"))
	print("Result: %s" % ("PASS" if moved and neutral else "FAIL"))
	print("=== RigPort VO Mouth Smoke Test complete ===")
