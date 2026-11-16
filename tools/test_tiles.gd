extends SceneTree
## Tests the PaintedCloudTileWorld in demo_tiles.tscn: streaming round the camera, seamless borders
## (CPU queries either side of a cell border agree), determinism (a tile re-baked after leaving
## matches), floating origin (the same absolute point reads the same after a shift) and the sun
## re-bake. Renders a few frames to user://shots/. Needs Vulkan:
##   godot --path . -s res://tools/test_tiles.gd

var failures := 0
var world : PaintedCloudTileWorld
var camera : Camera3D


func check(label : String, ok : bool, detail : String) -> void:
	print("%s %s  (%s)" % ["PASS" if ok else "FAIL", label, detail])
	if !ok:
		failures += 1


func wait_ready(label : String, timeout_s : float = 600.0) -> bool:
	var started := Time.get_ticks_msec()
	# process_frame comes before the nodes' _process: give the world a few frames to see changes.
	for i in 3:
		await process_frame
	while true:
		await process_frame
		var status := world.get_status()
		if status.ready == status.wanted and status.jobs == 0:
			print("test_tiles: %s: %d / %d tiles ready in %.1f s" % [label, status.ready, status.wanted, (Time.get_ticks_msec() - started) / 1000.0])
			return true
		if Time.get_ticks_msec() - started > timeout_s * 1000.0:
			print("test_tiles: %s: timed out at %s" % [label, status])
			return false
	return false


func shot(name : String) -> void:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	var path := OS.get_user_data_dir() + "/shots/%s.png" % name
	get_root().get_texture().get_image().save_png(path)
	print("test_tiles: shot ", path)


func voxel_hash(cell : Vector2i) -> int:
	for bake in PaintedCloudWorld.get_bakes():
		var corner := Vector3((cell - world.offset_cells).x * world.cell_size, 0, (cell - world.offset_cells).y * world.cell_size)
		if bake.tier == 0 and bake.size.x > world.cell_size and bake.origin.distance_to(corner - Vector3(bake.voxel_size, -world.floor_height, bake.voxel_size)) < 1.0:
			return hash(bake.voxels)
	return 0


func _initialize() -> void:
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	get_root().add_child(demo)
	world = demo.get_node("PaintedCloudTileWorld")
	camera = demo.get_node("FlyCamera")
	camera.set_process(false)
	camera.position = Vector3(10000.0, 2400.0, 10000.0)
	camera.rotation_degrees = Vector3(4.0, 0.0, 0.0)
	print("test_tiles: [1/6] streaming the first 3x3")
	check("first 3x3 streams in", await wait_ready("start"), "")
	var home := Vector2i(0, 0)
	var home_hash := voxel_hash(home)

	print("test_tiles: [2/6] borders")
	# Either side of the x = 20 km border, along it, at several heights: the two tiles agree.
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var cloudy := 0
	for z in range(0, 20000, 250):
		for y in [800.0, 1800.0, 3000.0, 5500.0]:
			var a := PaintedCloudWorld.get_distance(Vector3(20000.0 - 30.0, y, z))
			var b := PaintedCloudWorld.get_distance(Vector3(20000.0 + 30.0, y, z))
			if minf(a, b) < 500.0:
				cloudy += 1
				if absf(a - b) > worst:
					worst = absf(a - b)
					worst_at = Vector3(20000.0, y, z)
	check("distance field continuous across a tile border", worst < 90.0 and cloudy > 0,
		"worst jump %.0f m at %s over 60 m, %d samples near cloud" % [worst, worst_at, cloudy])
	var sun_a := PaintedCloudWorld.get_sunlight(Vector3(19990.0, 2000.0, 9000.0))
	var sun_b := PaintedCloudWorld.get_sunlight(Vector3(20010.0, 2000.0, 9000.0))
	check("sunlight continuous across the border", absf(sun_a - sun_b) < 0.15, "%.2f vs %.2f" % [sun_a, sun_b])
	# Looking along the x = 20 km border from above the clouds, before any shift.
	camera.position = Vector3(20000.0, 9500.0, 26000.0)
	camera.rotation_degrees = Vector3(-14.0, 0.0, 0.0)
	await shot("tiles_border")

	print("test_tiles: [3/6] travelling two cells east (floating origin off for this)")
	var threshold := world.shift_threshold
	world.shift_threshold = 0.0
	camera.position = Vector3(50000.0, 2400.0, 10000.0)
	check("tiles stream round the new cell", await wait_ready("east"), "")
	check("old tiles dropped", world.get_status().wanted == 9 and !world.near.tiles.has(Vector2i(-1, 0)), "")
	camera.position = Vector3(10000.0, 2400.0, 10000.0)
	await wait_ready("back home")
	check("a tile re-baked after leaving matches (deterministic)", voxel_hash(home) == home_hash and home_hash != 0,
		"%d vs %d" % [voxel_hash(home), home_hash])

	world.shift_threshold = threshold
	print("test_tiles: [4/6] floating origin")
	var probe_local := Vector3(31000.0, 2000.0, 12000.0)
	var probe_abs := world.to_absolute(probe_local)
	var before := PaintedCloudWorld.get_distance(probe_local)
	camera.position = Vector3(35000.0, 2400.0, 10000.0) # past the 30 km threshold
	await process_frame
	await process_frame
	var shifted := world.offset_cells
	await wait_ready("after shift")
	var after_local := probe_abs - Vector3(world.offset_cells.x * world.cell_size, 0, world.offset_cells.y * world.cell_size)
	var after := PaintedCloudWorld.get_distance(after_local)
	check("origin shifted by whole cells", shifted != Vector2i.ZERO and camera.position.x < 30000.0,
		"offset %s, camera now %s" % [shifted, camera.position])
	check("the same absolute point reads the same after the shift", absf(before - after) < 1.0, "%.1f vs %.1f m" % [before, after])

	print("test_tiles: [5/6] turning the sun 20 degrees")
	var sun : DirectionalLight3D = world.sun
	var lit_before := PaintedCloudWorld.get_sunlight(after_local)
	sun.rotate_y(deg_to_rad(20.0))
	var relit := [0] # An array: lambdas capture locals by value.
	var started := Time.get_ticks_msec()
	world.tile_ready.connect(func(_cell : Vector2i) -> void: relit[0] += 1)
	while relit[0] < 9 and Time.get_ticks_msec() - started < 600000:
		await process_frame
	var current := sun.global_transform.basis.z.normalized()
	var all_new := true
	for cell in world.near.tiles:
		if world.near.tiles[cell].sun.angle_to(current) > deg_to_rad(1.0):
			all_new = false
	check("every tile re-baked its light for the new sun", relit[0] >= 9 and all_new, "%d re-bakes in %.1f s" % [relit[0], (Time.get_ticks_msec() - started) / 1000.0])
	print("test_tiles: sunlight at the probe %.2f -> %.2f" % [lit_before, PaintedCloudWorld.get_sunlight(after_local)])

	print("test_tiles: [6/6] rendering")
	camera.position = Vector3(5000.0, 3200.0, 14000.0)
	camera.rotation_degrees = Vector3(-6.0, -20.0, 0.0)
	await wait_ready("final")
	await shot("tiles_view")
	camera.rotation_degrees = Vector3(-12.0, 160.0, 0.0)
	await shot("tiles_view_back")
	print("test_tiles: %s" % ("all passed" if failures == 0 else "%d failed" % failures))
	quit(failures)
