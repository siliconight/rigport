@tool
extends VBoxContainer
## RigPort Validator dock. Select an imported character in the scene tree,
## pick its preset, and run validation / VO setup / reporting.

const DRIVER_SCRIPT := preload("res://addons/rigport/rigport_vo_mouth_driver.gd")
const VO_TEST_SCRIPT := preload("res://addons/rigport/rigport_vo_test.gd")
const TEST_SCENE_DIR := "res://rigport_tests"

var _preset_button: OptionButton
var _output: RichTextLabel
var _preset_ids: Array = []
var _last_result: Dictionary = {}


func _ready() -> void:
	var title := Label.new()
	title.text = "RigPort — Rig it. Test it. Ship it."
	add_child(title)

	_preset_button = OptionButton.new()
	for pid: String in RigPortContracts.presets():
		_preset_ids.append(pid)
		_preset_button.add_item(RigPortContracts.preset(pid).get("name", pid))
	add_child(_preset_button)

	_add_button("Validate Selected Character", _on_validate)
	_add_button("Add VO Mouth Driver", _on_add_driver)
	_add_button("Connect Voice Audio Player", _on_connect_audio)
	_add_button("Create VO Test Scene", _on_create_test_scene)
	_add_button("Add HitReact Driver", _on_add_hitreact_driver)
	_add_button("Assign HitReact Profile", _on_assign_hitreact_profile)
	_add_button("Create HitReact Test Scene", _on_create_hitreact_test_scene)
	_add_button("Add Stumble Controller", _on_add_stumble_controller)
	_add_button("Save Readiness Report", _on_save_report)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.fit_content = true
	_output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_output)
	_say("Select an imported character scene, choose a preset, and validate.")


func _add_button(text: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	add_child(b)


func _say(msg: String) -> void:
	_output.text = msg


func _preset_id() -> String:
	var idx := _preset_button.selected
	return _preset_ids[idx] if idx >= 0 and idx < _preset_ids.size() else "player_character"


func _selected_node() -> Node:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	if nodes.is_empty():
		_say("[color=orange]Select the character's root node in the scene tree first.[/color]")
		return null
	return nodes[0]


# ------------------------------------------------------------ actions


func _on_validate() -> void:
	var node := _selected_node()
	if node == null:
		return
	_last_result = RigPortValidator.validate(node, _preset_id())
	_render(_last_result)


func _on_add_driver() -> void:
	var node := _selected_node()
	if node == null:
		return
	for child: Node in node.find_children("*", "Node", true, false):
		if child.get_script() == DRIVER_SCRIPT:
			_say("A RigPortVOMouthDriver is already attached to '%s'." % node.name)
			return
	var driver: Node = DRIVER_SCRIPT.new()
	driver.name = "RigPortVOMouthDriver"
	node.add_child(driver)
	driver.owner = EditorInterface.get_edited_scene_root()
	var mesh := RigPortValidator.find_mouth_mesh(node)
	if mesh != null:
		driver.mesh_path = driver.get_path_to(mesh)
	var players := node.find_children("*", "AudioStreamPlayer3D", true, false)
	if not players.is_empty():
		driver.audio_player_path = driver.get_path_to(players[0])
	driver.mouth_lod = int(RigPortContracts.preset(_preset_id()).get("default_mouth_lod", 1))
	var notes := ""
	if mesh == null:
		notes += "\n[color=orange]No mouth blend shapes found — assign Mesh Path manually.[/color]"
	if players.is_empty():
		notes += "\n[color=orange]No AudioStreamPlayer3D found — use Connect Voice Audio Player.[/color]"
	_say("Added RigPortVOMouthDriver to '%s' (Mouth LOD %d).%s" % [node.name, driver.mouth_lod, notes])


func _on_connect_audio() -> void:
	var node := _selected_node()
	if node == null:
		return
	var players := node.find_children("*", "AudioStreamPlayer3D", true, false)
	var player: AudioStreamPlayer3D
	if players.is_empty():
		player = AudioStreamPlayer3D.new()
		player.name = "VoiceAudio"
		node.add_child(player)
		player.owner = EditorInterface.get_edited_scene_root()
	else:
		player = players[0]
	for child: Node in node.find_children("*", "Node", true, false):
		if child.get_script() == DRIVER_SCRIPT:
			child.audio_player_path = child.get_path_to(player)
			_say("Connected '%s' to the VO mouth driver." % player.name)
			return
	_say("Voice audio player '%s' ready. Add a VO Mouth Driver to use it." % player.name)


func _on_create_test_scene() -> void:
	var node := _selected_node()
	if node == null:
		return
	var scene_path := node.scene_file_path
	if scene_path.is_empty():
		_say("[color=orange]'%s' is not an instanced/saved scene. Save the character as a .tscn/.glb scene first.[/color]" % node.name)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_SCENE_DIR))
	var root := Node3D.new()
	root.name = "RigPortVOTest_%s" % node.name
	root.set_script(VO_TEST_SCRIPT)
	root.set("character_scene", load(scene_path))
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		_say("[color=red]Failed to pack the VO test scene.[/color]")
		root.free()
		return
	var out_path := "%s/vo_test_%s.tscn" % [TEST_SCENE_DIR, str(node.name).validate_filename().to_lower()]
	var err := ResourceSaver.save(packed, out_path)
	root.free()
	if err != OK:
		_say("[color=red]Failed to save %s (err %d).[/color]" % [out_path, err])
		return
	EditorInterface.get_resource_filesystem().scan()
	_say("VO test scene saved: %s\nOpen it and press F6. It plays a generated voice burst and prints PASS/FAIL to Output." % out_path)


# ------------------------------------------------------------ hitreact


func _hitreact_supported() -> bool:
	if ClassDB.class_exists("SkeletonModifier3D"):
		return true
	_say("[color=orange]HitReact needs Godot 4.3+ (SkeletonModifier3D).[/color]")
	return false


func _hitreact_driver_of(node: Node) -> Node:
	var script: Script = load("res://addons/rigport/rigport_hit_react_driver.gd")
	for child: Node in node.find_children("*", "Node", true, false):
		if child.get_script() == script:
			return child
	return null


## Profile exported next to the character scene:
## enemy_grunt.glb -> enemy_grunt.hitreact.json
func _guess_profile_path(node: Node) -> String:
	var scene_path := node.scene_file_path
	if scene_path.is_empty():
		return ""
	var guess := scene_path.get_basename() + ".hitreact.json"
	return guess if FileAccess.file_exists(guess) else ""


func _on_add_hitreact_driver() -> void:
	if not _hitreact_supported():
		return
	var node := _selected_node()
	if node == null:
		return
	var support: String = RigPortContracts.hitreact().get("preset_support", {}) \
		.get(_preset_id(), {}).get("support", "optional")
	if support == "unsupported":
		_say("[color=orange]Preset '%s' does not support hit reactions.[/color]" % _preset_id())
		return
	if _hitreact_driver_of(node) != null:
		_say("A RigPortHitReactDriver is already attached to '%s'." % node.name)
		return
	var skeleton := RigPortValidator._find_skeleton(node)
	if skeleton == null:
		_say("[color=red]No Skeleton3D found under '%s'.[/color]" % node.name)
		return

	var driver: Node = load("res://addons/rigport/rigport_hit_react_driver.gd").new()
	driver.name = "RigPortHitReactDriver"
	skeleton.add_child(driver)
	driver.owner = EditorInterface.get_edited_scene_root()

	var receiver_note := ""
	if node.find_children("*", "RigPortHitReactReceiver", true, false).is_empty():
		var receiver: Node = load("res://addons/rigport/rigport_hit_react_receiver.gd").new()
		receiver.name = "RigPortHitReactReceiver"
		node.add_child(receiver)
		receiver.owner = EditorInterface.get_edited_scene_root()
		receiver_note = "\nAdded RigPortHitReactReceiver to the character root."

	var profile_note := "\n[color=orange]No profile assigned — use Assign HitReact Profile.[/color]"
	var guess := _guess_profile_path(node)
	if not guess.is_empty():
		driver.set("profile_path", guess)
		profile_note = "\nProfile auto-assigned: %s" % guess
	_say("Added RigPortHitReactDriver under '%s'.%s%s" % [skeleton.name, receiver_note, profile_note])


func _on_assign_hitreact_profile() -> void:
	if not _hitreact_supported():
		return
	var node := _selected_node()
	if node == null:
		return
	var driver := _hitreact_driver_of(node)
	if driver == null:
		_say("[color=orange]No RigPortHitReactDriver on '%s' — use Add HitReact Driver first.[/color]" % node.name)
		return
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.hitreact.json, *.json", "HitReact Profiles")
	dialog.file_selected.connect(func(path: String) -> void:
		driver.set("profile_path", path)
		_say("HitReact profile assigned: %s" % path)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered_ratio(0.5)


func _on_create_hitreact_test_scene() -> void:
	if not _hitreact_supported():
		return
	var node := _selected_node()
	if node == null:
		return
	var scene_path := node.scene_file_path
	if scene_path.is_empty():
		_say("[color=orange]'%s' is not an instanced/saved scene. Save the character as a .tscn/.glb scene first.[/color]" % node.name)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_SCENE_DIR))
	var root := Node3D.new()
	root.name = "RigPortHitReactTest_%s" % node.name
	root.set_script(load("res://addons/rigport/rigport_hit_react_test.gd"))
	root.set("character_scene", load(scene_path))
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		_say("[color=red]Failed to pack the HitReact test scene.[/color]")
		root.free()
		return
	var out_path := "%s/hitreact_test_%s.tscn" % [TEST_SCENE_DIR, str(node.name).validate_filename().to_lower()]
	var err := ResourceSaver.save(packed, out_path)
	root.free()
	if err != OK:
		_say("[color=red]Failed to save %s (err %d).[/color]" % [out_path, err])
		return
	EditorInterface.get_resource_filesystem().scan()
	_say("HitReact test scene saved: %s\nOpen it, press F6, then keys 1-5 fire zone hits, 6 rapid fire, 7 kill shot, 8 LOD cycle, 9 reset, 0 cycles NPC state." % out_path)


func _on_add_stumble_controller() -> void:
	if not _hitreact_supported():
		return
	var node := _selected_node()
	if node == null:
		return
	var driver := _hitreact_driver_of(node)
	if driver == null:
		_say("[color=orange]Add a HitReact Driver first — the stumble layer sits above it.[/color]")
		return
	var skeleton := RigPortValidator._find_skeleton(node)
	if skeleton == null:
		_say("[color=red]No Skeleton3D found under '%s'.[/color]" % node.name)
		return
	var stumble_script: Script = load("res://addons/rigport/rigport_stumble_controller.gd")
	for child: Node in skeleton.get_children():
		if child.get_script() == stumble_script:
			_say("A RigPortStumbleController is already attached to '%s'." % node.name)
			return

	var stumble: Node = stumble_script.new()
	stumble.name = "RigPortStumbleController"
	# Must sit AFTER the HitReact driver so its lean composes on the flinch.
	skeleton.add_child(stumble)
	skeleton.move_child(stumble, skeleton.get_child_count() - 1)
	stumble.owner = EditorInterface.get_edited_scene_root()

	var profile_path := str(driver.get("profile_path"))
	if not profile_path.is_empty():
		stumble.set("profile_path", profile_path)
	var sims := node.find_children("*", "PhysicalBoneSimulator3D", true, false)
	var note := ""
	if not sims.is_empty():
		stumble.set("physical_bone_simulator", stumble.get_path_to(sims[0]))
		note = "\nWired PhysicalBoneSimulator3D for fall ragdoll."
	else:
		note = "\n[color=orange]No PhysicalBoneSimulator3D — falls play as procedural collapse + `fell` signal.[/color]"
	_say("Added RigPortStumbleController above the HitReact driver on '%s'.%s" % [node.name, note])


func _on_save_report() -> void:
	if _last_result.is_empty():
		_say("[color=orange]Run Validate Selected Character first.[/color]")
		return
	var path := RigPortReport.save(_last_result)
	if path.is_empty():
		_say("[color=red]Could not save the report.[/color]")
		return
	EditorInterface.get_resource_filesystem().scan()
	_say("Readiness report saved: %s (plus .json)" % path)


# ------------------------------------------------------------ rendering


func _render(r: Dictionary) -> void:
	var score: int = r.get("score", 0)
	var color := "green"
	if score < 50:
		color = "red"
	elif score < 90:
		color = "yellow"
	var text := "[b]%s[/b]  —  %s\n" % [r.get("character", "?"), r.get("preset_name", "?")]
	text += "[b]Character Readiness: [color=%s]%d%%[/color][/b]\n%s\n" % [color, score, r.get("band", "")]
	if r.has("hitreact"):
		var hr_status: String = r.get("hitreact", "N/A")
		var hr_color := "green"
		if hr_status == "FAIL":
			hr_color = "red"
		elif hr_status == "WARN":
			hr_color = "yellow"
		elif hr_status == "N/A":
			hr_color = "gray"
		text += "HitReact: [color=%s]%s[/color]\n" % [hr_color, hr_status]
	text += _section("[color=red]FAIL[/color]", r.get("fails", []))
	text += _section("[color=yellow]WARN[/color]", r.get("warns", []))
	text += _section("[color=green]PASS[/color]", r.get("passes", []))
	_output.text = text


func _section(header: String, items: Array) -> String:
	var text := "\n[b]%s[/b]\n" % header
	if items.is_empty():
		return text + "- None\n"
	for msg: String in items:
		text += "- %s\n" % msg
	return text
