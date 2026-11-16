@tool
extends Node3D
class_name PaintedCloudVolume
## The box the clouds are baked into. Press Bake to turn every PaintedCloudPoint under this node into a
## smooth signed distance field plus baked sun and sky light, in a 3D texture saved at bake_path.
## The box is centred on this node and axis aligned (its rotation and scale are ignored).
## Baking runs on the GPU (a local RenderingDevice), in the editor or in game, and logs its
## progress to the output panel.

## The box's size (m).
@export var size := Vector3(48000.0, 14000.0, 48000.0):
	set(value):
		size = value
		update_gizmos()

## Size of one voxel (m). Memory is (size / voxel_size) cubed x 8 bytes: halving it costs 8x.
@export_range(25.0, 1000.0, 5.0, "suffix:m") var voxel_size : float = 200.0

## Where the bake is saved.
@export_file("*.res") var bake_path : String = "res://clouds/sky_bake.res"

@export_group("Shape")
## How much neighbouring lobes and clouds melt into each other (m): low gives bubbly separate
## lobes, high gives smooth masses.
@export_range(0.0, 2000.0, 5.0, "suffix:m") var blend : float = 220.0
## Distances beyond this (m) are stored as this: rays skip at most this far per step.
@export_range(500.0, 20000.0, 50.0, "suffix:m") var max_distance : float = 4000.0

@export_group("Light")
## The sun. Its direction is baked in, so re-bake after moving it.
@export var sun : DirectionalLight3D
## How far towards the sun (m) the clouds shade each voxel.
@export_range(100.0, 20000.0, 50.0, "suffix:m") var light_distance : float = 5000.0
@export_range(4, 64) var light_steps : int = 24
## How far up (m) the clouds shade each voxel from the sky.
@export_range(100.0, 20000.0, 50.0, "suffix:m") var sky_distance : float = 3000.0
## Edge softness (m) the light bake (and get_density()) treat the surface with.
@export_range(10.0, 2000.0, 5.0, "suffix:m") var softness : float = 300.0
## How strongly cloud blocks light, per metre at full density.
@export_range(0.0, 0.02, 0.0001) var extinction : float = 0.0012

@export_group("")
@export_tool_button("Bake", "Bake") var bake_action = bake
@export_custom(PROPERTY_HINT_MULTILINE_TEXT, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var last_bake : String = ""

var bake_result : PaintedCloudBake



func _ready() -> void:
	if bake_path != "" and ResourceLoader.exists(bake_path):
		bake_result = load(bake_path)
		bake_result.get_texture() # Built here, on the main thread, before the effect needs it.
		PaintedCloudBake.active = bake_result
		PaintedCloudWorld.register_bake(bake_result)


func _exit_tree() -> void:
	if bake_result:
		PaintedCloudWorld.unregister_bake(bake_result)
		if PaintedCloudBake.active == bake_result:
			PaintedCloudBake.active = null


func _enter_tree() -> void:
	if bake_result:
		PaintedCloudWorld.register_bake(bake_result)
		PaintedCloudBake.active = bake_result


## Gameplay: signed distance (m) to the nearest cloud surface, negative inside (this volume only:
## PaintedCloudWorld answers for every volume).
func get_distance(world_position : Vector3) -> float:
	return bake_result.get_distance(world_position) if bake_result else INF


## Gameplay: rough density 0 (clear) .. 1 (inside), soft over the edge.
func get_density(world_position : Vector3) -> float:
	return bake_result.get_density(world_position) if bake_result else 0.0


func get_box_min() -> Vector3:
	return global_position - size * 0.5 if is_inside_tree() else position - size * 0.5


func bake() -> void:
	var started := Time.get_ticks_msec()
	var report := func(stage : String, text : String) -> void:
		print("PaintedCloudVolume bake: %s %s" % [stage, text])

	report.call("[1/5]", "gathering cloud points")
	var clouds : Array[PaintedCloudPoint] = []
	_gather(self, clouds)
	if clouds.is_empty():
		push_warning("PaintedCloudVolume: no PaintedCloudPoints under this node to bake.")
	var cloud_prims : Array = []
	var prim_count := 0
	for i in clouds.size():
		var prims := clouds[i].build_primitives()
		prim_count += prims.size()
		cloud_prims.append(prims)
		if (i + 1) % 50 == 0 or i == clouds.size() - 1:
			report.call("[1/5]", "built %d / %d clouds (%d primitives)" % [i + 1, clouds.size(), prim_count])
	var packed := PaintedCloudBaker.pack(cloud_prims)

	var dims := Vector3i((size / voxel_size).ceil()).max(Vector3i(4, 4, 4))
	var voxels := dims.x * dims.y * dims.z
	report.call("[2/5]", "grid %d x %d x %d = %d voxels, %.1f MB" % [dims.x, dims.y, dims.z, voxels, voxels * 8.0 / 1048576.0])
	var baker := PaintedCloudBaker.new()
	if !baker.is_valid():
		push_error("PaintedCloudVolume: baking needs the Forward+ or Mobile renderer (no RenderingDevice), or the bake shaders failed.")
		baker.free_resources()
		return
	var box_min := get_box_min()
	var sun_dir := Vector3(0.4, 0.6, 0.3).normalized()
	if sun:
		sun_dir = sun.global_transform.basis.z.normalized()
	var stage_start := [Time.get_ticks_msec(), ""]
	var next_report := [0.1]
	var progress := func(stage : String, fraction : float) -> void:
		if stage != stage_start[1]:
			stage_start[0] = Time.get_ticks_msec()
			stage_start[1] = stage
			next_report[0] = 0.1
		if fraction >= next_report[0] or fraction >= 1.0:
			var label := "[3/5]" if stage == "distance field" else "[4/5]"
			print("PaintedCloudVolume bake: %s %s %3d%%  (%d ms)" % [label, stage, roundi(fraction * 100.0), Time.get_ticks_msec() - stage_start[0]])
			while next_report[0] <= fraction:
				next_report[0] += 0.1
	var bytes := baker.bake(packed, box_min, dims, voxel_size, _settings(sun_dir), Vector3i.ZERO, progress)
	baker.free_resources()
	if bytes.is_empty():
		push_error("PaintedCloudVolume: bake failed.")
		return

	report.call("[5/5]", "saving %s" % bake_path)
	if bake_result == null:
		bake_result = load(bake_path) if bake_path != "" and ResourceLoader.exists(bake_path) else PaintedCloudBake.new()
	bake_result.set_voxels(bytes, dims)
	bake_result.origin = box_min
	bake_result.size = Vector3(dims) * voxel_size
	bake_result.voxel_size = voxel_size
	bake_result.sun_direction = sun_dir
	bake_result.softness = softness
	bake_result.max_distance = max_distance
	bake_result.cloud_count = clouds.size()
	bake_result.primitive_count = prim_count
	if bake_path != "":
		DirAccess.make_dir_recursive_absolute(bake_path.get_base_dir())
		var err := ResourceSaver.save(bake_result, bake_path)
		if err != OK:
			push_error("PaintedCloudVolume: couldn't save %s (error %d)" % [bake_path, err])
		else:
			bake_result.take_over_path(bake_path)
	bake_result.get_texture()
	PaintedCloudBake.active = bake_result
	PaintedCloudWorld.register_bake(bake_result)
	bake_result.emit_changed()
	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	last_bake = "%d clouds, %d primitives\n%d x %d x %d voxels (%.1f MB)\n%.1f s" % [
		clouds.size(), prim_count, dims.x, dims.y, dims.z, voxels * 8.0 / 1048576.0, seconds]
	report.call("done", "in %.1f s" % seconds)


func _settings(sun_dir : Vector3) -> Dictionary:
	return {"blend": blend, "max_distance": max_distance, "sun_direction": sun_dir, "light_distance": light_distance,
		"light_steps": light_steps, "sky_distance": sky_distance, "softness": softness, "extinction": extinction}


func _gather(node : Node, into : Array[PaintedCloudPoint]) -> void:
	for child in node.get_children():
		if child is PaintedCloudPoint and child.visible:
			into.append(child)
		_gather(child, into)
