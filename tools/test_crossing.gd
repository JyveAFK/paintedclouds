extends SceneTree
## Watches a cell crossing's hand-over: crosses into the next cell, then holds the camera still and
## saves every frame while the new tiles stream in and the near cells hand over to and from the
## distant panorama. Nothing should pop, vanish or double: each frame should be close to the last.
## Saves the biggest frame-to-frame change as a pair. Needs Vulkan:
##   godot --path . -s res://tools/test_crossing.gd

var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect


func settled() -> bool:
	var s := world.get_status()
	return s.ready == s.wanted and s.far_ready == s.far_wanted and s.horizon_ready == s.horizon_wanted and s.jobs == 0 \
		and effect.pano_shown and !effect.is_busy()


func grab() -> Image:
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	return image


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
	world.shift_threshold = 0.0
	effect = demo.get_node("WorldEnvironment").compositor.compositor_effects[0]
	effect.swap_when_hidden = false # Tests swap panoramas in straight away.
	effect.panorama_auto_repaint = false # Only the hand-over re-paints.
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").queue_free()
	demo.get_node("HoldMarker").queue_free()
	camera.position = Vector3(19800.0, 4800.0, 10000.0)
	camera.rotation_degrees = Vector3(-2.0, -90.0, 0.0) # Looking along +x, towards the new cells.
	print("test_crossing: [1/3] streaming at x = 19800 (cell 0)")
	for i in 4:
		await process_frame
	while !settled():
		await process_frame
	camera.position.x = 20200.0
	print("test_crossing: [2/3] crossed into cell 1; holding still through the hand-over")
	var frames : Array[Image] = [await grab()]
	var diffs : Array[float] = []
	var paints := 0
	var was_painting := false
	for f in 3000:
		var image := await grab()
		diffs.append(diff(frames[-1], image))
		frames.append(image)
		if frames.size() > 3:
			frames[frames.size() - 4] = null # Keep memory down: only the last few.
		if effect.painting and !was_painting:
			paints += 1
			print("test_crossing:   frame %d: panorama re-painting (%d near cells held, status %s)" % [f, effect.paint_cells.size(), world.get_status()])
		was_painting = effect.painting
		if diffs[-1] > 1.0:
			image.save_png(OS.get_user_data_dir() + "/shots/crossing_%04d.png" % f)
			frames[-2].save_png(OS.get_user_data_dir() + "/shots/crossing_%04d_before.png" % f) if frames[-2] else null
		if f > 10 and settled():
			print("test_crossing:   settled after %d frames" % f)
			break
	print("test_crossing: [3/3] results")
	var worst := 0.0
	var worst_at := -1
	var total := 0.0
	for i in diffs.size():
		total += diffs[i]
		if diffs[i] > worst:
			worst = diffs[i]
			worst_at = i
	print("test_crossing: %d frames, %d re-paints; frame-to-frame change: mean %.3f, worst %.2f (frame %d)" % [
		diffs.size(), paints, total / maxi(diffs.size(), 1), worst, worst_at])
	var ok := worst < 2.0 and paints >= 1
	print("%s the hand-over at a cell crossing never jumps (worst %.2f levels in one frame, camera still)" % ["PASS" if ok else "FAIL", worst])
	quit(0 if ok else 1)
