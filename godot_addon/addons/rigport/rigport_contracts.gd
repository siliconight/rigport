@tool
class_name RigPortContracts
extends RefCounted
## Loads the RigPort JSON data contracts. These files are the single source of
## truth shared with the Blender add-on — keep them byte-identical across both.

const DIR := "res://addons/rigport/contracts/"

static var _cache: Dictionary = {}


static func _load(file_name: String) -> Dictionary:
	if _cache.has(file_name):
		return _cache[file_name]
	var path := DIR + file_name
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("RigPort: cannot open contract %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("RigPort: contract %s is not valid JSON" % path)
		return {}
	_cache[file_name] = parsed
	return parsed


static func bones() -> Dictionary:
	return _load("bone_contract.json")


static func sockets() -> Dictionary:
	return _load("socket_contract.json")


static func mouth() -> Dictionary:
	return _load("mouth_shape_contract.json")


static func mouth_lod() -> Dictionary:
	return _load("mouth_lod_contract.json")


static func presets() -> Dictionary:
	return _load("presets.json").get("presets", {})


static func preset(preset_id: String) -> Dictionary:
	return presets().get(preset_id, {})


static func required_bones(preset_id: String) -> Array:
	var p := preset(preset_id)
	if p.has("required_bones_override"):
		return p["required_bones_override"]
	return bones().get("required_bones", [])


static func required_sockets(preset_id: String) -> Array:
	return preset(preset_id).get("required_sockets", [])


static func recommended_sockets(preset_id: String) -> Array:
	return preset(preset_id).get("recommended_sockets", [])


static func lod_entry(lod: int) -> Dictionary:
	for entry: Dictionary in mouth_lod().get("lods", []):
		if int(entry.get("lod", -1)) == lod:
			return entry
	return {}
