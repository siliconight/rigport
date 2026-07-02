@tool
class_name RigPortValidator
extends RefCounted
## Validates an imported character against the RigPort contracts and computes
## the character readiness score.
##
## Result dictionary:
##   character, preset_id, preset_name : String
##   passes, warns, fails             : Array[String]
##   score                            : int (0-100)
##   band                             : String

const DRIVER_SCRIPT := preload("res://addons/rigport/rigport_vo_mouth_driver.gd")

const DEFAULT_FAIL_WEIGHT := 15
const DEFAULT_WARN_WEIGHT := 4
const DEFAULT_SCALE_RANGE := [1.4, 2.2]  # meters, humanoid


static func validate(root: Node, preset_id: String) -> Dictionary:
	var p := RigPortContracts.preset(preset_id)
	var r := {
		"character": root.name,
		"preset_id": preset_id,
		"preset_name": p.get("name", preset_id),
		"passes": [], "warns": [], "fails": [],
		"score": 100, "band": "",
	}

	var skeleton := _find_skeleton(root)
	if skeleton == null:
		_fail(r, "No Skeleton3D found under '%s'." % root.name, 40)
		_finish(r)
		return r
	_pass(r, "Skeleton3D found: '%s' (%d bones)." % [skeleton.name, skeleton.get_bone_count()])

	_check_bones(r, skeleton, preset_id, p)
	_check_sockets(r, root, skeleton, preset_id)
	_check_mesh_binding(r, skeleton)
	_check_mouth(r, root, p)
	_check_scale(r, root, p)
	_check_direction(r, skeleton)

	_finish(r)
	return r


# ---------------------------------------------------------------- checks


static func _check_bones(r: Dictionary, skeleton: Skeleton3D, preset_id: String, p: Dictionary) -> void:
	var required: Array = RigPortContracts.required_bones(preset_id)
	var missing: Array[String] = []
	for bone_name: String in required:
		if skeleton.find_bone(bone_name) == -1:
			missing.append(bone_name)
	if missing.is_empty():
		_pass(r, "All %d required bones present." % required.size())
	else:
		_fail(r, "Missing required bones: %s." % ", ".join(missing))

	var root_idx := skeleton.find_bone("Root")
	if root_idx != -1:
		if skeleton.get_bone_parent(root_idx) == -1:
			_pass(r, "Root bone exists and is the hierarchy root.")
		else:
			_warn(r, "Root bone exists but is parented to another bone.")

	if p.get("requires_full_body", true):
		var rec_missing: Array[String] = []
		for bone_name: String in RigPortContracts.bones().get("recommended_bones", []):
			if skeleton.find_bone(bone_name) == -1:
				rec_missing.append(bone_name)
		if not rec_missing.is_empty():
			_warn(r, "Missing recommended bones: %s." % ", ".join(rec_missing))


static func _check_sockets(r: Dictionary, root: Node, skeleton: Skeleton3D, preset_id: String) -> void:
	var required: Array = RigPortContracts.required_sockets(preset_id)
	var missing: Array[String] = []
	for socket: String in required:
		if not _has_socket(root, skeleton, socket):
			missing.append(socket)
	if required.is_empty():
		return
	if missing.is_empty():
		_pass(r, "All %d required sockets present." % required.size())
	else:
		_fail(r, "Missing required sockets: %s." % ", ".join(missing))
	var rec_missing: Array[String] = []
	for socket: String in RigPortContracts.recommended_sockets(preset_id):
		if not _has_socket(root, skeleton, socket):
			rec_missing.append(socket)
	if not rec_missing.is_empty():
		_warn(r, "Missing recommended sockets: %s." % ", ".join(rec_missing))


static func _check_mesh_binding(r: Dictionary, skeleton: Skeleton3D) -> void:
	var meshes := skeleton.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		_fail(r, "No MeshInstance3D bound under the Skeleton3D.")
		return
	_pass(r, "%d mesh instance(s) bound to the skeleton." % meshes.size())
	for mi: MeshInstance3D in meshes:
		if mi.mesh == null:
			_warn(r, "'%s' has no mesh resource." % mi.name)
		elif not mi.visible:
			_warn(r, "'%s' is hidden." % mi.name)


static func _check_mouth(r: Dictionary, root: Node, p: Dictionary) -> void:
	var needs: bool = p.get("requires_vo_mouth", false)
	var wants: bool = needs or p.get("recommended_vo_mouth", false)
	if not wants:
		return

	var mouth_mesh := find_mouth_mesh(root)
	if mouth_mesh == null:
		if needs:
			_fail(r, "Speaking preset but no mouth blend shapes on any mesh.", 15)
		else:
			_warn(r, "VO mouth recommended for this preset but no mouth blend shapes found.")
		return
	_pass(r, "Mouth blend shapes found on '%s'." % mouth_mesh.name)

	if mouth_mesh.find_blend_shape_by_name("Mouth_Open") == -1:
		_fail(r, "Missing Mouth_Open blend shape — amplitude mouth flap cannot run.", 10)
	var mvp_missing: Array[String] = []
	for shape: String in RigPortContracts.mouth().get("required_mvp_shapes", []):
		if mouth_mesh.find_blend_shape_by_name(shape) == -1:
			mvp_missing.append(shape)
	if mvp_missing.is_empty():
		_pass(r, "All MVP mouth shapes present.")
	elif needs:
		_fail(r, "Missing MVP mouth shapes: %s." % ", ".join(mvp_missing))
	else:
		_warn(r, "Missing MVP mouth shapes: %s." % ", ".join(mvp_missing))

	var viseme_missing: Array[String] = []
	for shape: String in RigPortContracts.mouth().get("recommended_visemes", []):
		if mouth_mesh.find_blend_shape_by_name(shape) == -1:
			viseme_missing.append(shape)
	if p.get("requires_visemes", false) and not viseme_missing.is_empty():
		_fail(r, "Preset requires visemes; missing: %s." % ", ".join(viseme_missing), 10)
	elif not viseme_missing.is_empty():
		_warn(r, "Missing optional viseme shapes — amplitude mouth flap only. Not recommended for close-up dialogue.")
	else:
		_pass(r, "All recommended viseme shapes present.")

	var min_lod := int(p.get("minimum_mouth_lod", 3))
	var lod := RigPortContracts.lod_entry(min_lod)
	var lod_missing: Array[String] = []
	for shape: String in lod.get("required_shapes", []):
		if mouth_mesh.find_blend_shape_by_name(shape) == -1:
			lod_missing.append(shape)
	if lod_missing.is_empty():
		_pass(r, "Mouth LOD %d ('%s') is achievable." % [min_lod, lod.get("name", "?")])
	else:
		_warn(r, "Mouth LOD %d not achievable — missing: %s." % [min_lod, ", ".join(lod_missing)])

	if _find_first(root, "AudioStreamPlayer3D") == null:
		var sev_msg := "No AudioStreamPlayer3D for VO on this character."
		if needs:
			_fail(r, sev_msg, 5)
		else:
			_warn(r, sev_msg)
	else:
		_pass(r, "AudioStreamPlayer3D connected.")

	if _find_driver(root) == null:
		var msg := "No RigPortVOMouthDriver attached."
		if needs:
			_fail(r, msg, 5)
		else:
			_warn(r, msg)
	else:
		_pass(r, "RigPortVOMouthDriver attached.")


static func _check_scale(r: Dictionary, root: Node, p: Dictionary) -> void:
	if p.get("skip_scale_check", false):
		return
	var aabb := merged_aabb(root)
	if aabb.size == Vector3.ZERO:
		_warn(r, "Could not measure character bounds.")
		return
	var height := aabb.size.y
	var range_m: Array = p.get("scale_range_m", DEFAULT_SCALE_RANGE)
	if height >= float(range_m[0]) and height <= float(range_m[1]):
		_pass(r, "Character height %.2fm is within the expected range %.1f-%.1fm — capsule fit plausible." % [height, float(range_m[0]), float(range_m[1])])
	else:
		_warn(r, "Character height %.2fm is outside the expected range %.1f-%.1fm." % [height, float(range_m[0]), float(range_m[1])])
	if absf(aabb.position.y) > 0.15:
		_warn(r, "Feet are %.2fm from the ground plane." % aabb.position.y)
	else:
		_pass(r, "Feet are near the ground plane.")


static func _check_direction(r: Dictionary, skeleton: Skeleton3D) -> void:
	var l := skeleton.find_bone("LeftUpperArm")
	var rt := skeleton.find_bone("RightUpperArm")
	if l == -1 or rt == -1:
		return
	var lx := skeleton.get_bone_global_rest(l).origin.x
	var rx := skeleton.get_bone_global_rest(rt).origin.x
	if absf(lx - rx) < 0.01:
		_warn(r, "Cannot determine forward direction from arm bones.")
	elif lx > rx:
		_pass(r, "Character faces -Z (expected gameplay forward).")
	else:
		_fail(r, "Character appears to face +Z — forward direction is reversed.")


# ---------------------------------------------------------------- scoring


static func _pass(r: Dictionary, msg: String) -> void:
	r["passes"].append(msg)


static func _warn(r: Dictionary, msg: String, weight := DEFAULT_WARN_WEIGHT) -> void:
	r["warns"].append(msg)
	r["score"] -= weight


static func _fail(r: Dictionary, msg: String, weight := DEFAULT_FAIL_WEIGHT) -> void:
	r["fails"].append(msg)
	r["score"] -= weight


static func _finish(r: Dictionary) -> void:
	r["score"] = clampi(r["score"], 0, 100)
	var s: int = r["score"]
	if s >= 90:
		r["band"] = "Ready for gameplay review"
	elif s >= 75:
		r["band"] = "Usable for testing with cleanup needed"
	elif s >= 50:
		r["band"] = "Prototype only"
	else:
		r["band"] = "Not ready for gameplay"


# ---------------------------------------------------------------- lookups


static func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	var found := root.find_children("*", "Skeleton3D", true, false)
	return found[0] if not found.is_empty() else null


static func _find_first(root: Node, type_name: String) -> Node:
	if root.is_class(type_name):
		return root
	var found := root.find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null


static func _find_driver(root: Node) -> Node:
	for n: Node in root.find_children("*", "Node", true, false):
		if n.get_script() == DRIVER_SCRIPT:
			return n
	return null


static func _has_socket(root: Node, skeleton: Skeleton3D, socket: String) -> bool:
	if skeleton.find_bone(socket) != -1:
		return true
	return root.find_child(socket, true, false) != null


static func find_mouth_mesh(root: Node) -> MeshInstance3D:
	var names: Array = []
	names.append_array(RigPortContracts.mouth().get("required_mvp_shapes", []))
	names.append_array(RigPortContracts.mouth().get("recommended_visemes", []))
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for shape: String in names:
			if mi.find_blend_shape_by_name(shape) != -1:
				return mi
	return null


static func merged_aabb(root: Node) -> AABB:
	var aabb := AABB()
	var first := true
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or not mi.is_inside_tree():
			continue
		var world: AABB = mi.global_transform * mi.get_aabb()
		if first:
			aabb = world
			first = false
		else:
			aabb = aabb.merge(world)
	# Report relative to the character root so ground = character origin.
	if not first and root is Node3D and (root as Node3D).is_inside_tree():
		aabb.position -= (root as Node3D).global_transform.origin
	return aabb
