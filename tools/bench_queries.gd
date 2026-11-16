extends SceneTree
## Times every PaintedCloudWorld query with a PaintedCloudTileWorld fully loaded (near and far tiles), at random
## positions round the camera: average and worst per call. Also checks run_async gives the same
## answers. Uses demo_tiles.tscn with 40 km cells at 1000 m voxels (pass --default for the
## demo's own 20 km / 200 m). Needs Vulkan:  godot --path . -s res://tools/bench_queries.gd

var world : PaintedCloudTileWorld


func _initialize() -> void:
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	world = demo.get_node("PaintedCloudTileWorld")
	if !OS.get_cmdline_user_args().has("--default") and !OS.get_cmdline_args().has("--default"):
		world.cell_size = 40000.0
		world.voxel_size = 1000.0
	get_root().add_child(demo)
	demo.get_node("HUD").queue_free()
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	camera.position = Vector3(world.cell_size * 0.5, 3000.0, world.cell_size * 0.5)
	print("bench_queries: [1/3] streaming %.0f km cells at %.0f m voxels" % [world.cell_size / 1000.0, world.voxel_size])
	for i in 3:
		await process_frame
	while true:
		await process_frame
		var s := world.get_status()
		if s.ready == s.wanted and s.far_ready == s.far_wanted and s.jobs == 0:
			break
	print("bench_queries: %d bakes registered" % PaintedCloudWorld.get_bakes().size())

	print("bench_queries: [2/3] timing (200 random positions within 1.5 cells of the camera)")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var points : Array[Vector3] = []
	var reach := world.cell_size * 1.5
	for i in 200:
		points.append(camera.position + Vector3(rng.randf_range(-reach, reach), rng.randf_range(-2500.0, 6000.0), rng.randf_range(-reach, reach)))
	var queries := {
		"get_density": func(p : Vector3, q : Vector3) -> Variant: return PaintedCloudWorld.get_density(p),
		"get_distance": func(p : Vector3, q : Vector3) -> Variant: return PaintedCloudWorld.get_distance(p),
		"get_sunlight": func(p : Vector3, q : Vector3) -> Variant: return PaintedCloudWorld.get_sunlight(p),
		"get_direction_to_cloud": func(p : Vector3, q : Vector3) -> Variant: return PaintedCloudWorld.get_direction_to_cloud(p),
		"get_hold_point (+300 m)": func(p : Vector3, q : Vector3) -> Variant: return PaintedCloudWorld.get_hold_point(p, 300.0),
		"get_visibility (to a point ~30 km off)": func(p : Vector3, q : Vector3) -> Variant: return PaintedCloudWorld.get_visibility(p, q),
		"raycast": func(p : Vector3, q : Vector3) -> Variant: return PaintedCloudWorld.raycast(p, q),
	}
	for name in queries:
		var total := 0
		var worst := 0
		for i in points.size():
			var started := Time.get_ticks_usec()
			queries[name].call(points[i], points[(i + 7) % points.size()])
			var took := Time.get_ticks_usec() - started
			total += took
			worst = maxi(worst, took)
		print("  %-40s average %7.3f ms   worst %7.3f ms" % [name, total / 1000.0 / points.size(), worst / 1000.0])

	print("bench_queries: [3/3] run_async")
	var results := {}
	var expected := {}
	for i in 16:
		var a := points[i]
		var b := points[i + 50]
		expected[i] = PaintedCloudWorld.get_visibility(a, b)
		var query := func() -> float: return PaintedCloudWorld.get_visibility(a, b)
		var done := func(value : float) -> void: results[i] = value
		PaintedCloudWorld.run_async(query, done)
	var waited := 0
	while results.size() < 16 and waited < 600:
		await process_frame
		waited += 1
	var same := results.size() == 16
	for i in results:
		if absf(results[i] - expected[i]) > 1e-6:
			same = false
	print("%s run_async: %d / 16 answered on worker threads, matching the direct calls: %s" % ["PASS" if same else "FAIL", results.size(), same])
	quit(0 if same else 1)
