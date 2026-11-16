extends SceneTree
## Flies 40 km in 500 m steps through the tile demo (crossing cell borders, so the near tiles
## stream and the panorama re-paints), waiting for streaming at each step, and measures how much
## each frame changes from the last: a pop (a cloud swapping from the distant panorama to the near
## tiles in one step) shows up as a spike. Saves a strip of frames. Needs Vulkan:
##   godot --path . -s res://tools/test_handover.gd

var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect


func settled() -> bool:
	var s := world.get_status()
	return s.ready == s.wanted and s.far_ready == s.far_wanted and s.horizon_ready == s.horizon_wanted and s.jobs == 0 \
		and effect.pano_shown and !effect.painting and !effect.fading and !effect.repaint_requested


func wait_settled() -> void:
	for i in 4:
		await process_frame
	while !settled():
		await process_frame
	for i in 3:
		await process_frame


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	get_root().add_child(demo)
	world = demo.get_node("PaintedCloudTileWorld")
	world.relight_angle = 0.0
	world.shift_threshold = 0.0
	effect = demo.get_node("WorldEnvironment").compositor.compositor_effects[0]
	effect.swap_when_hidden = false # Tests swap panoramas in straight away.
	effect.panorama_fade_seconds = 0.0
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").queue_free()
	demo.get_node("HoldMarker").queue_free()
	camera.position = Vector3(5000.0, 4800.0, 10000.0)
	camera.rotation_degrees = Vector3(-2.0, -90.0, 0.0) # Looking along +x, the way it flies.
	print("test_handover: [1/3] streaming")
	await wait_settled()
	print("test_handover: [2/3] flying 40 km along x in 500 m steps")
	var diffs : Array[float] = []
	var surface : Array[float] = [] # Camera's distance to the nearest cloud surface at each step.
	var frames : Array[Image] = []
	var crossings : Array[int] = []
	var previous : Image = null
	var strip : Array[Image] = []
	var last_cell := floori(camera.position.x / world.cell_size)
	for step in 81:
		if step > 0:
			camera.position.x += 500.0
			await wait_settled()
		var cell := floori(camera.position.x / world.cell_size)
		if cell != last_cell:
			crossings.append(step)
			last_cell = cell
		await RenderingServer.frame_post_draw
		var image := get_root().get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		if previous:
			var total := 0.0
			var n := 0
			for y in range(0, image.get_height(), 3):
				for x in range(0, image.get_width(), 3):
					var a := image.get_pixel(x, y)
					var b := previous.get_pixel(x, y)
					total += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
					n += 1
			diffs.append(total / n * 255.0 / 3.0)
		previous = image
		frames.append(image)
		surface.append(PaintedCloudWorld.get_distance(camera.position))
		if step % 8 == 0:
			strip.append(image)
		if step % 10 == 0:
			print("test_handover:   step %d / 80, x = %.0f m%s" % [step, camera.position.x, ", crossed into cell %d" % cell if crossings.has(step) else ""])
	print("test_handover: [3/3] results")
	var sorted := diffs.duplicate()
	sorted.sort()
	var median : float = sorted[sorted.size() / 2]
	var worst : float = sorted[-1]
	var worst_step := diffs.find(worst) + 1
	var at_crossings := PackedStringArray()
	for c in crossings:
		at_crossings.append("step %d: %.2f" % [c, diffs[c - 1]])
	print("test_handover: frame-to-frame change: median %.2f, worst %.2f (step %d), at cell crossings: %s" % [
		median, worst, worst_step, ", ".join(at_crossings)])
	# Flying into or out of a cloud legitimately changes the whole view: judge the rest.
	var judged : Array[float] = []
	var top := PackedStringArray()
	for i in diffs.size():
		var near_cloud := minf(surface[i], surface[i + 1]) < 400.0
		if !near_cloud:
			judged.append(diffs[i])
		if diffs[i] > median * 2.0:
			top.append("step %d: %.1f (camera %.0f m from cloud)" % [i + 1, diffs[i], minf(surface[i], surface[i + 1])])
	print("test_handover: big steps: %s" % (", ".join(top) if !top.is_empty() else "none"))
	judged.sort()
	var judged_worst : float = judged[-1] if !judged.is_empty() else 0.0
	var ok := judged_worst < median * 3.0
	print("%s away from clouds, no step changes much more than a typical one (worst %.1fx the median)" % [
		"PASS" if ok else "FAIL", judged_worst / maxf(median, 0.001)])
	var pair := Image.create(frames[0].get_width() * 2, frames[0].get_height(), false, Image.FORMAT_RGB8)
	pair.blit_rect(frames[worst_step - 1], Rect2i(Vector2i.ZERO, frames[0].get_size()), Vector2i.ZERO)
	pair.blit_rect(frames[worst_step], Rect2i(Vector2i.ZERO, frames[0].get_size()), Vector2i(frames[0].get_width(), 0))
	pair.save_png(OS.get_user_data_dir() + "/shots/handover_worst_pair.png")
	var w := strip[0].get_width() / 2
	var h := strip[0].get_height() / 2
	var sheet := Image.create(w * 2, h * ceili(strip.size() / 2.0), false, Image.FORMAT_RGB8)
	for i in strip.size():
		var small := strip[i].duplicate()
		small.resize(w, h, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(small, Rect2i(0, 0, w, h), Vector2i((i % 2) * w, (i / 2) * h))
	sheet.save_png(OS.get_user_data_dir() + "/shots/handover_strip.png")
	quit(0 if ok else 1)
