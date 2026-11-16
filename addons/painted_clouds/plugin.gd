@tool
extends EditorPlugin
## Registers the gizmos that draw PaintedCloudPoints (their core and lobes, as baked) and PaintedCloudVolumes
## (their box).

var gizmo_plugin : EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	gizmo_plugin = preload("res://addons/painted_clouds/cloud_gizmo.gd").new()
	add_node_3d_gizmo_plugin(gizmo_plugin)


func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(gizmo_plugin)
