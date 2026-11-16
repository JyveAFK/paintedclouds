extends SceneTree
## Looks for a flicker at a floating-origin shift: flies steadily across the shift threshold
## (mid-cell, so no tiles stream at the same moment), saving every frame, and checks each frame
## against its neighbours. A flicker is a frame that differs from both neighbours while they agree
## with each other. Saves the frames either side of the shift. Needs Vulkan:
##   godot --path . -s res://tools/test_shift.gd

var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect


func settled() -> bool:
	var s := world.get_status()
	return s.ready == s.wanted and s.far_ready == s.far_wanted and s.horizon_ready == s.horizon_wanted and s.jobs == 0 \
		and effect.pano_shown and !effect.is_busy()


func diff(a : Image, b : Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, a.get_height(), 3):
		for x in range(0, a.get_width(), 3):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			total += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)
			n += 1
	return total / n * 255.0 / 3.0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	get_root().add_child(demo)
	world = demo.get_node("PaintedCloudTileWorld")
	world.relight_angle = 0.0
	world.shift_threshold = 30000.0
	effect = demo.get_node("WorldEnvironment").compositor.compositor_effects[0]
	effect.swap_when_hidden = false # Tests swap panoramas in straight away.
	effect.panorama_fade_seconds = 0.0
	effect.panorama_auto_repaint = false # So nothing but the shift changes during the run.
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").queue_free()
	demo.get_node("HoldMarker").queue_free()
	camera.position = Vector3(29000.0, 4800.0, 10000.0)
	camera.rotation_degrees = Vector3(-2.0, -90.0, 0.0) # Looking along +x, the way it flies.
	var shifts := [0]
	world.origin_shifted.connect(func(_o : Vector3) -> void: shifts[0] += 1)
	print("test_shift: [1/3] streaming at x = 29000 (shift at 30000)")
	for i in 4:
		await process_frame
	while !settled():
		await process_frame
	print("test_shift: [2/3] flying 2 km along x at 50 m a frame, saving every frame")
	var frames : Array[Image] = []
	var shift_frame := -1
	for f in 40:
		camera.position.x += 50.0
		await RenderingServer.frame_post_draw
		var image := get_root().get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		frames.append(image)
		if shifts[0] > 0 and shift_frame < 0:
			shift_frame = f
			print("test_shift:   origin shifted during frame %d (camera now at local x %.0f)" % [f, camera.position.x])
	print("test_shift: [3/3] results")
	var steps : Array[float] = []
	for i in range(1, frames.size()):
		steps.append(diff(frames[i - 1], frames[i]))
	var sorted := steps.duplicate()
	sorted.sort()
	var median : float = sorted[sorted.size() / 2]
	var worst_flicker := 0.0
	var worst_at := -1
	for i in range(1, frames.size() - 1):
		var jump := minf(diff(frames[i - 1], frames[i]), diff(frames[i], frames[i + 1]))
		var skip := diff(frames[i - 1], frames[i + 1])
		var flicker := jump - skip * 0.5
		if flicker > worst_flicker:
			worst_flicker = flicker
			worst_at = i
	print("test_shift: frame-to-frame change: median %.2f; around the shift: %s" % [median,
		", ".join(range(maxi(shift_frame - 2, 0), mini(shift_frame + 3, steps.size())).map(func(i : int) -> String: return "%d: %.2f" % [i + 1, steps[i]]))])
	print("test_shift: strongest one-frame flicker: %.2f at frame %d" % [worst_flicker, worst_at])
	if shift_frame >= 1:
		var w := frames[0].get_width()
		var h := frames[0].get_height()
		var strip := Image.create(w * 3, h, false, Image.FORMAT_RGB8)
		for k in 3:
			var i := clampi(shift_frame - 1 + k, 0, frames.size() - 1)
			strip.blit_rect(frames[i], Rect2i(0, 0, w, h), Vector2i(k * w, 0))
		strip.save_png(OS.get_user_data_dir() + "/shots/shift_frames.png")
	# The step into the shifted frame should look like any other step (anything anchored to the
	# local coordinates rather than the world, like the billow noise once was, jumps there).
	var at_shift : float = steps[shift_frame - 1] if shift_frame >= 1 else 0.0
	var ok : bool = shifts[0] == 1 and worst_flicker < maxf(median * 2.0, 1.0) and at_shift < median * 1.25
	print("%s nothing jumps or flickers at the origin shift  (%d shift, step into it %.2f, flicker %.2f, typical change %.2f)" % [
		"PASS" if ok else "FAIL", shifts[0], at_shift, worst_flicker, median])
	quit(0 if ok else 1)
