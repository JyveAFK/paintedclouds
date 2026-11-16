extends SceneTree
## Measures the distant clouds' parallax correction: paints the panorama at A, moves the camera to
## B (as far as it gets before an automatic re-paint), and compares B's view (with and without correction) against the truth (a panorama painted at B). Needs Vulkan:  godot --path . -s res://tools/test_parallax.gd

var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect


func wait_all() -> void:
	for i in 3:
		await process_frame
	while true:
		await process_frame
		var s := world.get_status()
		if s.ready == s.wanted and s.far_ready == s.far_wanted and s.jobs == 0:
			return


func wait_panorama() -> void:
	for i in 3:
		await process_frame
	while !(effect.pano_shown and !effect.painting and !effect.fading):
		await process_frame


func shot(name : String) -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	image.save_png(OS.get_user_data_dir() + "/shots/%s.png" % name)
	return image


# Mean colour difference over the horizon band, where the distant clouds are.
func difference(a : Image, b : Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(a.get_height() * 30 / 100, a.get_height() * 60 / 100, 2):
		for x in range(0, a.get_width(), 2):
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
	effect = demo.get_node("WorldEnvironment").compositor.compositor_effects[0]
	effect.swap_when_hidden = false # Tests swap panoramas in straight away.
	effect.panorama_fade_seconds = 0.0
	# Only the test re-paints, so the correction is measured on its own.
	effect.panorama_auto_repaint = false
	# The distant billow noise fades with distance from where it was painted, so it differs
	# between A and B by design; leave it out so only the geometry is compared.
	effect.distant_noise_distance = 0.0
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").visible = false
	demo.get_node("HoldMarker").queue_free()
	var a := Vector3(6000.0, 7000.0, 6000.0)
	# As far as the camera gets before the panorama re-paints by itself (just under
	# panorama_repaint_distance sideways and panorama_repaint_height up): the panorama paints from
	# close enough in to cover the hand-over band anywhere within that, so this is the worst case.
	var b := a + Vector3(3000.0, 900.0, 1800.0)
	camera.position = a
	camera.rotation_degrees = Vector3(-3.0, 200.0, 0.0)
	print("test_parallax: [1/4] streaming and painting at A %s" % a)
	await wait_all()
	await wait_panorama()
	print("test_parallax: [2/4] moved to B %s (panorama still from A)" % b)
	camera.position = b
	await wait_all()
	effect.panorama_parallax = true
	var corrected := await shot("parallax_corrected")
	effect.panorama_parallax = false
	var uncorrected := await shot("parallax_uncorrected")
	print("test_parallax: [3/4] re-painting at B for the truth")
	effect.panorama_parallax = true
	effect.pano_key = []
	effect.pano_shown = true
	await wait_panorama()
	var truth := await shot("parallax_truth")
	var err_corrected := difference(corrected, truth)
	var err_uncorrected := difference(uncorrected, truth)
	print("test_parallax: [4/4] horizon error vs truth: corrected %.2f, uncorrected %.2f (levels of 255)" % [err_corrected, err_uncorrected])
	# What's left is at cloud silhouettes, where B sees past an edge that A's panorama never
	# painted behind (disocclusion); most of the band is near clouds, the same in all three shots.
	var ok := err_corrected < err_uncorrected * 0.75
	print("%s parallax correction cuts the error  (%.0f%% of uncorrected)" % ["PASS" if ok else "FAIL", 100.0 * err_corrected / maxf(err_uncorrected, 0.001)])
	quit(0 if ok else 1)
