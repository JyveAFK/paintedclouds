extends SceneTree
## Tests hidden swaps: a newly painted panorama waits while distant clouds are on screen, swaps in
## once the camera is inside a cloud, and, when no hidden moment comes, the fallback wisp flies at
## the camera and the swap happens behind it. Saves the wisp's flight as a contact sheet
## (user://shots/wisp_sheet.png). Needs Vulkan:  godot --path . -s res://tools/test_hidden_swap.gd

var world : PaintedCloudTileWorld
var effect : PaintedCloudsEffect
var camera : Camera3D
var failures := 0


func check(name : String, ok : bool, detail : String) -> void:
	print("%s %s  (%s)" % ["PASS" if ok else "FAIL", name, detail])
	if !ok:
		failures += 1


func settled() -> bool:
	var s := world.get_status()
	return s.ready == s.wanted and s.far_ready == s.far_wanted and s.horizon_ready == s.horizon_wanted and s.jobs == 0 \
		and effect.pano_shown and !effect.is_busy()


func wait_settled() -> void:
	for i in 4:
		await process_frame
	while !settled():
		await process_frame


func wait_until_waiting() -> void:
	for i in 3:
		await process_frame
	while !effect.waiting:
		await process_frame


# A point near p well inside a cloud (or p itself if none found).
func inside_cloud_near(p : Vector3) -> Vector3:
	var best := p
	var best_distance := 0.0
	for x in range(-6, 7):
		for z in range(-6, 7):
			for y in range(-3, 4):
				var q := p + Vector3(x * 600.0, y * 500.0, z * 600.0)
				var d := PaintedCloudWorld.get_distance(q)
				if d < best_distance:
					best_distance = d
					best = q
	return best


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	get_root().add_child(demo)
	world = demo.get_node("PaintedCloudTileWorld")
	world.relight_angle = 0.0
	world.shift_threshold = 0.0
	effect = demo.get_node("WorldEnvironment").compositor.compositor_effects[0]
	effect.panorama_auto_repaint = false # Only the test asks for re-paints.
	camera = demo.get_node("FlyCamera")
	camera.set_process(false)
	demo.get_node("HUD").queue_free()
	demo.get_node("HoldMarker").queue_free()
	var open_view := Vector3(5000.0, 4800.0, 10000.0)
	camera.position = open_view
	camera.rotation_degrees = Vector3(-2.0, -90.0, 0.0) # Over the cloud field, plenty of distant clouds.
	print("test_hidden_swap: [1/4] streaming")
	await wait_settled()
	# Clear air (climb out of any cloud), with the cloud field ahead.
	while PaintedCloudWorld.get_distance(open_view) < 1000.0:
		open_view.y += 300.0
	camera.position = open_view
	print("test_hidden_swap:   watching from %s, %.0f m from the nearest cloud" % [open_view, PaintedCloudWorld.get_distance(open_view)])
	await wait_settled()

	print("test_hidden_swap: [2/4] re-painting with distant clouds in view: the swap should wait")
	effect.swap_max_wait = 1000.0
	effect.repaint_requested = true
	await wait_until_waiting()
	for i in 12:
		await process_frame
	check("the new panorama waits while distant clouds are on screen", effect.waiting,
		"%.1f%% of the screen showing distant clouds, %s" % [effect.coverage * 100.0, "measured" if effect.coverage_valid else "not measured yet"])

	print("test_hidden_swap: [3/4] flying into a cloud: the swap should happen there")
	var inside := inside_cloud_near(open_view)
	camera.position = inside
	var frames := 0
	while effect.waiting and frames < 60:
		await process_frame
		frames += 1
	check("it swaps in once the camera is inside a cloud", !effect.waiting,
		"camera %.0f m inside the cloud surface, swapped after %d frames, %.1f%% distant clouds on screen" % [
			-PaintedCloudWorld.get_distance(inside), frames, effect.coverage * 100.0])
	camera.position = open_view
	await wait_settled()

	print("test_hidden_swap: [4/5] no hidden moment: the wisp, flown through")
	effect.swap_max_wait = 1.0
	effect.wisp_fade_in = 1.0
	var signals := {"appeared": 0, "entered": 0, "gone": [], "where": Vector3.ZERO}
	effect.wisp_appeared.connect(func(p : Vector3, _r : float) -> void:
		signals.appeared += 1
		signals.where = p)
	effect.wisp_entered.connect(func() -> void: signals.entered += 1)
	effect.wisp_gone.connect(func(through : bool) -> void: signals.gone.append(through))
	effect.repaint_requested = true
	await wait_until_waiting()
	frames = 0
	while !effect.wisp_active and frames < 200:
		await process_frame
		frames += 1
	var start : Vector3 = camera.position
	var target : Vector3 = effect.wisp_centre - world.to_absolute(Vector3.ZERO)
	print("test_hidden_swap:   wisp at %s, %.0f m ahead; flying through it" % [target, start.distance_to(target)])
	var shots : Array[Image] = []
	var swapped_in_wisp := false
	var deepest := 0.0
	var direction := (target - start).normalized()
	var step := 120.0
	frames = 0
	while (effect.waiting or effect.wisp_active) and frames < 600:
		var was_waiting := effect.waiting
		camera.position += direction * step
		camera.look_at(camera.position + direction, Vector3.UP)
		await RenderingServer.frame_post_draw
		frames += 1
		var density := PaintedCloudsEffect.get_wisp_density(camera.position)
		deepest = maxf(deepest, density)
		# In it, or close enough that it fills the view.
		if was_waiting and !effect.waiting and camera.position.distance_to(target) < effect.wisp_radius * 1.6:
			swapped_in_wisp = true
		if effect.wisp_active and frames % 3 == 0 and shots.size() < 12:
			var image := get_root().get_texture().get_image()
			image.convert(Image.FORMAT_RGB8)
			shots.append(image)
	await process_frame
	check("with no hidden moment, a wisp appears on the camera's path", signals.appeared == 1, "at %s" % signals.where)
	check("the swap happens as the camera flies into it", swapped_in_wisp, "")
	check("get_wisp_density reads it from inside (for a boost)", deepest > 0.5, "deepest %.2f" % deepest)
	check("wisp_entered fired, and wisp_gone(true) once it faded", signals.entered == 1 and signals.gone == [true], "entered %d, gone %s" % [signals.entered, signals.gone])
	if !shots.is_empty():
		var w := shots[0].get_width() / 3
		var h := shots[0].get_height() / 3
		var columns := 4
		var sheet := Image.create(w * columns, h * ceili(shots.size() / float(columns)), false, Image.FORMAT_RGB8)
		for i in shots.size():
			var small := shots[i].duplicate()
			small.resize(w, h, Image.INTERPOLATE_BILINEAR)
			sheet.blit_rect(small, Rect2i(0, 0, w, h), Vector2i((i % columns) * w, (i / columns) * h))
		sheet.save_png(OS.get_user_data_dir() + "/shots/wisp_sheet.png")

	print("test_hidden_swap: [5/5] the wisp, swerved past: the swap is forced")
	camera.position = open_view
	camera.rotation_degrees = Vector3(-2.0, -90.0, 0.0)
	await wait_settled()
	signals.gone = []
	effect.wisp_timeout = 120.0 # A software GPU flies slowly: let it get past.
	effect.repaint_requested = true
	await wait_until_waiting()
	frames = 0
	while !effect.wisp_active and frames < 200:
		await process_frame
		frames += 1
	target = effect.wisp_centre - world.to_absolute(Vector3.ZERO)
	# Fly by well to one side of it.
	var side := (target - camera.position).cross(Vector3.UP).normalized() * (effect.wisp_radius * 3.0)
	direction = (target + side - camera.position).normalized()
	var forced := false
	frames = 0
	var max_density := 0.0
	while (effect.waiting or effect.wisp_active) and frames < 600:
		var was_waiting := effect.waiting
		camera.position += direction * step
		await process_frame
		frames += 1
		max_density = maxf(max_density, PaintedCloudsEffect.get_wisp_density(camera.position))
		if was_waiting and !effect.waiting:
			forced = true
	await process_frame
	check("swerving past it forces the swap, and it fades away", forced and !effect.wisp_active and signals.gone == [false],
		"never inside (max density %.2f), gone %s" % [max_density, signals.gone])
	print("test_hidden_swap: %s" % ("all passed" if failures == 0 else "%d failed" % failures))
	quit(0 if failures == 0 else 1)
