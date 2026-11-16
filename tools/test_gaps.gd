extends SceneTree
## Looks for gaps in the distant clouds as the camera moves sideways past clouds: paints the
## panorama at A, moves sideways (short of the automatic re-paints), and compares the view against
## the truth (everything re-painted there). A gap is where the truth has cloud and the view shows
## sky through it (bright sky blue where the truth is white or shaded). Saves view / truth pairs.
## Needs Vulkan:  godot --path . -s res://tools/test_gaps.gd

var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect


func wait_all() -> void:
	for i in 3:
		await process_frame
	while true:
		await process_frame
		var s := world.get_status()
		if s.ready == s.wanted and s.far_ready == s.far_wanted and s.horizon_ready == s.horizon_wanted and s.jobs == 0:
			return


func wait_panorama() -> void:
	for i in 3:
		await process_frame
	while !(effect.pano_shown and !effect.painting and !effect.fading and !effect.repaint_requested):
		await process_frame


func shot() -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	return image


# Over the horizon band: the mean difference, and the share of pixels where the view shows sky
# (bluer and darker) where the truth has cloud.
func compare(view : Image, truth : Image) -> Vector2:
	var total := 0.0
	var gaps := 0
	var n := 0
	for y in range(view.get_height() * 25 / 100, view.get_height() * 65 / 100, 2):
		for x in range(0, view.get_width(), 2):
			var p := view.get_pixel(x, y)
			var q := truth.get_pixel(x, y)
			total += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)
			# Sky is strongly blue (b well above r); cloud is much less so.
			var p_sky := p.b - p.r
			var q_sky := q.b - q.r
			if p_sky - q_sky > 0.12:
				gaps += 1
			n += 1
	return Vector2(total / n * 255.0 / 3.0, 100.0 * gaps / n)


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
	effect.panorama_auto_repaint = false # Moves are kept within the automatic re-paint distances.
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").queue_free()
	demo.get_node("HoldMarker").queue_free()
	var a := Vector3(5000.0, 4800.0, 10000.0)
	camera.position = a
	camera.rotation_degrees = Vector3(-2.0, -90.0, 0.0) # Looking along +x, over the cloud field.
	print("test_gaps: [1/3] streaming and painting at A %s" % a)
	await wait_all()
	await wait_panorama()
	var results := []
	var pairs : Array[Image] = []
	# Sideways (across the view), short of the inner and outer re-paint distances.
	var sideways := Vector3(0.0, 0.0, 1.0)
	for move in [1900.0, 3900.0]:
		effect.panorama_auto_repaint = false
		camera.position = a
		await wait_all()
		effect.repaint_requested = true
		await wait_panorama()
		var b : Vector3 = a + sideways * move
		print("test_gaps: [2/3] moved %.0f m sideways to %s (panorama still from A)" % [move, b])
		camera.position = b
		# Straight away: a move within the cell streams nothing, and any re-paint that starts only
		# shows once finished (seconds later), so this is the panorama painted at A.
		var view := await shot()
		effect.repaint_requested = true
		await wait_panorama()
		var truth := await shot()
		var r := compare(view, truth)
		results.append(r)
		print("test_gaps:   vs truth: mean difference %.2f, gaps %.2f%% of the horizon band" % [r.x, r.y])
		pairs.append(view)
		pairs.append(truth)
	print("test_gaps: [3/3] saving view / truth pairs")
	var w := pairs[0].get_width() / 2
	var h := pairs[0].get_height() / 2
	var sheet := Image.create(w * 2, h * (pairs.size() / 2), false, Image.FORMAT_RGB8)
	for i in pairs.size():
		var small := pairs[i].duplicate()
		small.resize(w, h, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(small, Rect2i(0, 0, w, h), Vector2i((i % 2) * w, (i / 2) * h))
	sheet.save_png(OS.get_user_data_dir() + "/shots/gaps_view_truth.png")
	var worst_gaps := maxf(results[0].y, results[1].y)
	var ok := worst_gaps < 1.0
	print("%s no gaps open in the distant clouds when moving sideways  (worst %.2f%% of the band)" % ["PASS" if ok else "FAIL", worst_gaps])
	quit(0 if ok else 1)
