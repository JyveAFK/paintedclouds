@tool
extends EditorNode3DGizmoPlugin
## PaintedCloudPoints: each primitive the bake will use, as outlines in their recipe's gizmo colour (core
## parts solid, lobes faint, sheet puffs as rings). PaintedCloudVolumes: their box.

const SEGMENTS := 24


var _made := {}


func _init() -> void:
	create_material("volume", Color(0.4, 0.7, 1.0, 0.6))


func _get_gizmo_name() -> String:
	return "PaintedClouds"


func _has_gizmo(node : Node3D) -> bool:
	return node is PaintedCloudPoint or node is PaintedCloudVolume


func _redraw(gizmo : EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	var to_local := node.global_transform.affine_inverse()
	if node is PaintedCloudVolume:
		var half : Vector3 = node.size * 0.5
		var lines := PackedVector3Array()
		var aabb := AABB(node.global_position - half, node.size)
		for i in 12:
			var edge := _box_edge(aabb, i)
			lines.append(to_local * edge[0])
			lines.append(to_local * edge[1])
		gizmo.add_lines(lines, get_material("volume", gizmo))
		return
	var cloud := node as PaintedCloudPoint
	var color := cloud.get_recipe().gizmo_color
	var core := PackedVector3Array()
	var lobes := PackedVector3Array()
	for p in cloud.build_primitives():
		var role : int = p[6]
		var target := lobes if role == 2 else core
		var a : Vector3 = p[0]
		var b : Vector3 = p[1]
		var r : float = p[2]
		var squash : float = p[3]
		# Rings at each end, and (except for sheet puffs, which are many) the outline from the side.
		_ring(target, to_local, a, r, Vector3.RIGHT, Vector3.BACK, 1.0)
		if role == 1:
			continue
		if a != b:
			_ring(target, to_local, b, r, Vector3.RIGHT, Vector3.BACK, 1.0)
			for side in [Vector3.RIGHT, Vector3.BACK]:
				for s in [1.0, -1.0]:
					target.append(to_local * (a + side * r * s))
					target.append(to_local * (b + side * r * s))
		_ring(target, to_local, (a + b) * 0.5, r, Vector3.RIGHT, Vector3.UP, squash, (b - a).y * 0.5)
	if !core.is_empty():
		gizmo.add_lines(core, _color_material(color, gizmo))
	if !lobes.is_empty():
		gizmo.add_lines(lobes, _color_material(Color(color, color.a * 0.3), gizmo))


# A line material per recipe colour, made the first time it's needed.
func _color_material(color : Color, gizmo : EditorNode3DGizmo) -> StandardMaterial3D:
	var key := "c" + color.to_html(true)
	if !_made.has(key):
		create_material(key, color)
		_made[key] = true
	return get_material(key, gizmo)


# A ring of radius around centre in the plane of u and v; v scaled by squash, and split by
# stretch along v (a capsule's side outline).
func _ring(lines : PackedVector3Array, to_local : Transform3D, centre : Vector3, radius : float, u : Vector3, v : Vector3, squash : float, stretch : float = 0.0) -> void:
	var previous := Vector3.ZERO
	for i in SEGMENTS + 1:
		var angle := TAU * i / SEGMENTS
		var sv := sin(angle)
		var point := centre + u * cos(angle) * radius + v * (sv * radius * squash + signf(sv) * stretch)
		if i > 0:
			lines.append(to_local * previous)
			lines.append(to_local * point)
		previous = point


func _box_edge(aabb : AABB, i : int) -> Array:
	var a := aabb.position
	var s := aabb.size
	var corners := [a, a + Vector3(s.x, 0, 0), a + Vector3(s.x, 0, s.z), a + Vector3(0, 0, s.z)]
	if i < 4:
		return [corners[i], corners[(i + 1) % 4]]
	if i < 8:
		return [corners[i - 4] + Vector3(0, s.y, 0), corners[(i - 3) % 4] + Vector3(0, s.y, 0)]
	return [corners[i - 8], corners[i - 8] + Vector3(0, s.y, 0)]
