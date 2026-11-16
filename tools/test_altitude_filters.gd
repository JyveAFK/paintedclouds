extends SceneTree
## Climbs through the tile demo checking the distant panorama re-paints with height (and renders
## at 9, 16.6 and 30 km), then renders each paint filter alone and all together from one view.
## Needs Vulkan:  godot --path . -s res://tools/test_altitude_filters.gd

var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect
var failures := 0


func check(label : String, ok : bool, detail : String) -> void:
	print("%s %s  (%s)" % ["PASS" if ok else "FAIL", label, detail])
	if !ok:
		failures += 1


func wait_tiles() -> void:
	for i in 3:
		await process_frame
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 1200000:
		await process_frame
		var s := world.get_status()
		if s.ready == s.wanted and s.far_ready == s.far_wanted and s.horizon_ready == s.horizon_wanted and s.jobs == 0:
			return


func wait_panorama() -> void:
	for i in 3:
		await process_frame
	while effect.painting or effect.fading or effect.repaint_requested or !effect.pano_shown:
		await process_frame


func shot(name : String) -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	image.save_png(OS.get_user_data_dir() + "/shots/%s.png" % name)
	print("test_altitude_filters: shot %s" % name)
	return image


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	get_root().add_child(demo)
	world = demo.get_node("PaintedCloudTileWorld")
	effect = demo.get_node("WorldEnvironment").compositor.compositor_effects[0]
	effect.swap_when_hidden = false # Tests swap panoramas in straight away.
	effect.panorama_fade_seconds = 0.0
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").visible = false
	demo.get_node("HoldMarker").queue_free()
	camera.position = Vector3(10000.0, 3000.0, 10000.0)
	camera.rotation_degrees = Vector3(-3.0, 200.0, 0.0)

	print("test_altitude_filters: [1/3] streaming near, far and horizon tiles")
	var started := Time.get_ticks_msec()
	await wait_tiles()
	var s := world.get_status()
	check("near, far and horizon rings stream in", s.horizon_ready == s.horizon_wanted and s.horizon_wanted > 0,
		"near %d, far %d, horizon %d tiles in %.0f s" % [s.ready, s.far_ready, s.horizon_ready, (Time.get_ticks_msec() - started) / 1000.0])
	await wait_panorama()

	print("test_altitude_filters: [2/3] climbing")
	for climb in [[9000.0, -8.0], [16600.0, -18.0], [30000.0, -28.0]]:
		camera.position.y = climb[0]
		camera.rotation_degrees.x = climb[1]
		await wait_tiles()
		await wait_panorama()
		var painted_at : Vector3 = effect.painted_from() - world.to_absolute(Vector3.ZERO)
		check("panorama re-painted near %.0f km" % (climb[0] / 1000.0), absf(painted_at.y - climb[0]) < effect.panorama_repaint_height,
			"painted from %.0f m" % painted_at.y)
		await shot("climb_%dkm" % roundi(climb[0] / 1000.0))

	print("test_altitude_filters: [3/3] paint filters")
	camera.position = Vector3(10000.0, 9000.0, 10000.0)
	camera.rotation_degrees = Vector3(-8.0, 200.0, 0.0)
	await wait_tiles()
	await wait_panorama()
	var looks := [
		["none", {}],
		["kuwahara classic", {"kuwahara": 1}],
		["kuwahara anisotropic", {"kuwahara": 2}],
		["watercolour edges", {"watercolor_strength": 0.8}],
		["canvas grain", {"grain_strength": 0.8}],
		["ink outlines", {"ink_strength": 0.7}],
		["hue-shifted shadows", {"hue_shift_strength": 0.8}],
		["rim bloom", {"rim_bloom_strength": 1.0}],
		["all together", {"kuwahara": 2, "watercolor_strength": 0.5, "grain_strength": 0.4, "ink_strength": 0.35,
			"hue_shift_strength": 0.5, "rim_bloom_strength": 0.6}],
	]
	var defaults := {"kuwahara": 0, "watercolor_strength": 0.0, "grain_strength": 0.0, "ink_strength": 0.0,
		"hue_shift_strength": 0.0, "rim_bloom_strength": 0.0}
	var images : Array[Image] = []
	for look in looks:
		for key in defaults:
			effect.set(key, look[1].get(key, defaults[key]))
		var started_frame := Time.get_ticks_usec()
		images.append(await shot("filter_" + look[0].replace(" ", "_")))
	# A contact sheet, 3 x 3 at a third of the size.
	var w := images[0].get_width() / 3
	var h := images[0].get_height() / 3
	var sheet := Image.create(w * 3, h * 3, false, Image.FORMAT_RGBA8)
	for i in images.size():
		var small := images[i].duplicate()
		small.convert(Image.FORMAT_RGBA8)
		small.resize(w, h, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(small, Rect2i(0, 0, w, h), Vector2i((i % 3) * w, (i / 3) * h))
	sheet.save_png(OS.get_user_data_dir() + "/shots/filter_sheet.png")
	var none := images[0]
	for i in range(1, images.size()):
		var changed := 0
		for y in range(0, none.get_height(), 4):
			for x in range(0, none.get_width(), 4):
				var a := none.get_pixel(x, y)
				var b := images[i].get_pixel(x, y)
				if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.03:
					changed += 1
		check("filter '%s' changes the look" % looks[i][0], changed > 50, "%d sampled pixels changed" % changed)
	print("test_altitude_filters: %s" % ("all passed" if failures == 0 else "%d failed" % failures))
	quit(failures)
