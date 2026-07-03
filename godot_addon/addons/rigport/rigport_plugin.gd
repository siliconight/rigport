@tool
extends EditorPlugin
## RigPort Validator — Godot side of the RigPort character pipeline.
## Adds the validator dock and registers the RigPortVOMouthDriver node type.

const DOCK_SCRIPT := preload("res://addons/rigport/rigport_dock.gd")
const DRIVER_SCRIPT := preload("res://addons/rigport/rigport_vo_mouth_driver.gd")
const HITREACT_DRIVER_SCRIPT := preload("res://addons/rigport/rigport_hit_react_driver.gd")
const HITREACT_RECEIVER_SCRIPT := preload("res://addons/rigport/rigport_hit_react_receiver.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = DOCK_SCRIPT.new()
	_dock.name = "RigPort"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	add_custom_type("RigPortVOMouthDriver", "Node", DRIVER_SCRIPT, null)
	if ClassDB.class_exists("SkeletonModifier3D"):
		add_custom_type("RigPortHitReactDriver", "SkeletonModifier3D", HITREACT_DRIVER_SCRIPT, null)
		add_custom_type("RigPortHitReactReceiver", "Node", HITREACT_RECEIVER_SCRIPT, null)
	else:
		push_warning("RigPort: HitReact needs Godot 4.3+ (SkeletonModifier3D) — HitReact nodes not registered.")


func _exit_tree() -> void:
	remove_control_from_docks(_dock)
	_dock.queue_free()
	remove_custom_type("RigPortVOMouthDriver")
	if ClassDB.class_exists("SkeletonModifier3D"):
		remove_custom_type("RigPortHitReactDriver")
		remove_custom_type("RigPortHitReactReceiver")
