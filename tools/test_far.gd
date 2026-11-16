extends SceneTree
## Tests the distant clouds in demo_tiles.tscn: the far tiles stream in, the panorama paints and
## fades in, far and near tiles agree where they overlap, PaintedCloudWorld answers beyond the near tiles
## from the far ones, and moving cell re-paints. Renders the horizon with the distant clouds on
## and off to user://shots/. Needs Vulkan:  godot --path . -s res://tools/test_far.gd

var failures := 0
var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect


func check(label : String, ok : bool, detail : String) -> void:
	print("%s %s  (%s)" % ["PASS" if ok else "FAIL", label, detail])
	if !ok:
		failures += 1


func wait_all(label : String) -> bool:
	var started := Time.get_ticks_msec()
	for i in 3:
		await process_frame
	while Time.get_ticks_msec() - started < 900000:
		await process_frame
		var s := world.get_status()
		if s.ready == s.wanted and s.far_ready == s.far_wanted and s.jobs == 0:
			print("test_far: %s: near %d / %d, far %d / %d in %.1f s" % [label, s.ready, s.wanted, s.far_ready, s.far_wanted, (Time.get_ticks_msec() - started) / 1000.0])
			return true
	print("test_far: %s timed out: %s" % [label, world.get_status()])
	return false


func wait_panorama() -> bool:
	var started := Time.get_ticks_msec()
	for i in 3:
		await process_frame
	while Time.get_ticks_msec() - started < 300000:
		await process_frame
		if effect.pano_shown and !effect.painting and !effect.fading and effect.pano_key == world.get_render_state().get("far", {}).get("key", []):
			return true
	return false


func shot(name : String) -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	image.save_png(OS.get_user_data_dir() + "/shots/%s.png" % name)
	print("test_far: shot %s" % name)
	return image


func _initialize() -> void:
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	get_root().add_child(demo)
	world = demo.get_node("PaintedCloudTileWorld")
	effect = demo.get_node("WorldEnvironment").compositor.compositor_effects[0]
	effect.swap_when_hidden = false # Tests swap panoramas in straight away.
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").visible = false
	demo.get_node("HoldMarker").queue_free()
	camera.position = Vector3(10000.0, 7500.0, 10000.0)
	camera.rotation_degrees = Vector3(-3.0, 200.0, 0.0)

	print("test_far: [1/5] streaming near and far tiles")
	check("near and far tiles stream in", await wait_all("start"), "")
	check("the distant panorama paints and fades in", await wait_panorama(), "")

	print("test_far: [2/5] horizon, distant clouds on and off")
	var with_far := await shot("far_on")
	effect.distant_clouds = false
	var without := await shot("far_off")
	effect.distant_clouds = true
	# Pixels near the horizon that the distant clouds change.
	var changed := 0
	var total := 0
	for y in range(with_far.get_height() * 35 / 100, with_far.get_height() * 60 / 100, 2):
		for x in range(0, with_far.get_width(), 2):
			total += 1
			var a := with_far.get_pixel(x, y)
			var b := without.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.06:
				changed += 1
	check("distant clouds show at the horizon", changed > total / 50, "%.1f%% of the horizon band changed" % [100.0 * changed / total])

	print("test_far: [3/5] far tiles agree with near ones")
	var diffs := 0.0
	var count := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 4000:
		var p := Vector3(rng.randf_range(-15000, 35000), rng.randf_range(500, 9000), rng.randf_range(-15000, 35000))
		var near_d := INF
		var far_d := INF
		for cell in world.near.tiles:
			var bake : PaintedCloudBake = world.near.tiles[cell].bake
			if bake.contains(p):
				near_d = bake.get_distance(p)
		for cell in world.far.tiles:
			var bake : PaintedCloudBake = world.far.tiles[cell].bake
			if bake.contains(p):
				far_d = bake.get_distance(p)
		if near_d < 600.0 and far_d < INF:
			diffs += absf(near_d - far_d)
			count += 1
	var mean := diffs / maxi(count, 1)
	check("far and near distance fields agree near clouds (coarser, so roughly)", count > 50 and mean < world.far.voxel,
		"mean difference %.0f m over %d samples, far voxels %.0f m" % [mean, count, world.far.voxel])

	print("test_far: [4/5] queries beyond the near tiles")
	var window_min : Vector3 = world.get_render_state().window_min
	var beyond := 0
	var cloudy := 0
	for i in 400:
		var p := Vector3(window_min.x - rng.randf_range(2000, 35000), rng.randf_range(800, 6000), window_min.z + rng.randf_range(0, 60000))
		var d := PaintedCloudWorld.get_distance(p)
		if d < world.max_distance * 1.5:
			beyond += 1
		if d < 0.0:
			cloudy += 1
	check("queries beyond the near tiles answer from the far ones", beyond > 350 and cloudy > 0, "%d / 400 answered, %d inside cloud" % [beyond, cloudy])

	print("test_far: [5/5] moving a cell re-paints the panorama")
	var key_before := effect.pano_key.duplicate()
	camera.position.x += world.cell_size
	await wait_all("after moving")
	check("the panorama re-paints for the new cell", await wait_panorama() and effect.pano_key != key_before, "")
	await shot("far_after_move")
	print("test_far: %s" % ("all passed" if failures == 0 else "%d failed" % failures))
	quit(failures)
