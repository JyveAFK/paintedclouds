extends SceneTree
## Bakes an isolated tower and cumulus, checks the PaintedCloudWorld queries against them and times
## them. The bake needs Vulkan:  godot --path . -s res://tools/test_queries.gd

var failures := 0


func check(label : String, ok : bool, detail : String) -> void:
	print("%s %s  (%s)" % ["PASS" if ok else "FAIL", label, detail])
	if !ok:
		failures += 1


func _initialize() -> void:
	# An isolated tower and cumulus, baked fresh (needs a Vulkan renderer for the bake), so the
	# expected answers don't depend on the demo's scatter.
	print("test_queries: [1/3] baking a test volume")
	var root := Node3D.new()
	get_root().add_child(root)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32.0, 35.0, 0.0)
	root.add_child(sun)
	var volume := PaintedCloudVolume.new()
	volume.size = Vector3(30000.0, 14000.0, 30000.0)
	volume.position = Vector3(0.0, 6000.0, 0.0)
	volume.bake_path = "user://test_bake.res"
	volume.sun = sun
	root.add_child(volume)
	var tower := PaintedCloudPoint.new()
	tower.recipe = load("res://addons/painted_clouds/recipes/tower.tres")
	tower.radius = 2000.0
	tower.height = 8500.0
	tower.lobe_seed = 3
	tower.position = Vector3(0.0, -4500.0, 0.0) # Base at 1500 m.
	volume.add_child(tower)
	var cumulus := PaintedCloudPoint.new()
	cumulus.radius = 1200.0
	cumulus.height = 2600.0
	cumulus.position = Vector3(9000.0, -4500.0, 6000.0)
	volume.add_child(cumulus)
	await process_frame
	volume.bake()
	print("test_queries: [2/3] checking")
	var base := tower.global_position
	var core := base + Vector3.UP * tower.height * 0.4
	print("test_queries: tower base %s, %d bakes registered" % [base, PaintedCloudWorld.get_bakes().size()])

	var d_core := PaintedCloudWorld.get_distance(core)
	check("inside the tower core", d_core < -500.0 and PaintedCloudWorld.get_density(core) > 0.99,
		"distance %.0f m, density %.2f" % [d_core, PaintedCloudWorld.get_density(core)])
	var sky := Vector3(0, 12900, 0)
	check("clear air high up", PaintedCloudWorld.get_distance(sky) > 300.0 and PaintedCloudWorld.get_density(sky) == 0.0,
		"distance %.0f m" % PaintedCloudWorld.get_distance(sky))

	var front := core + Vector3(0, 0, 9000)
	var back := core - Vector3(0, 0, 9000)
	var through := PaintedCloudWorld.get_visibility(front, back)
	check("line of sight through the tower is blocked", through < 0.01, "visibility %.3f" % through)
	check("is_hidden agrees", PaintedCloudWorld.is_hidden(front, back), "")
	var above_a := Vector3(-20000, 12900, 0)
	var above_b := Vector3(20000, 12900, 0)
	var over := PaintedCloudWorld.get_visibility(above_a, above_b)
	check("line of sight above every cloud is clear", over > 0.99, "visibility %.3f" % over)

	var hit := PaintedCloudWorld.raycast(front, back)
	var surface_gap := absf(PaintedCloudWorld.get_distance(hit.position))
	check("raycast hits the tower's near side", hit.hit and hit.distance > 5000.0 and hit.distance < 9000.0 and surface_gap < 60.0,
		"hit %s at %.0f m, %.0f m off the surface" % [hit.hit, hit.distance, surface_gap])

	var beside := core + Vector3(tower.radius * 2.2, 0, 0)
	var to_cloud := PaintedCloudWorld.get_direction_to_cloud(beside)
	var expected := (Vector3(core.x, beside.y, core.z) - beside).normalized()
	check("cover direction points at the tower", to_cloud.dot(expected) > 0.6, "dot %.2f, dir %s" % [to_cloud.dot(expected), to_cloud])
	var out_dir := PaintedCloudWorld.get_direction_to_clear_air(core)
	check("clear-air direction from inside is a real direction", out_dir.length() > 0.9, "dir %s" % out_dir)

	for offset in [300.0, 0.0, -150.0]:
		var hold := PaintedCloudWorld.get_hold_point(beside, offset)
		var at := PaintedCloudWorld.get_distance(hold)
		check("hold point at %+d m" % offset, absf(at - offset) < 40.0 and hold.distance_to(beside) < tower.radius * 3.0,
			"reads %.0f m, moved %.0f m" % [at, hold.distance_to(beside)])

	var lit := PaintedCloudWorld.get_sunlight(Vector3(base.x, 12900, base.z))
	var shaded := PaintedCloudWorld.get_sunlight(core)
	check("sunlight: full above, shaded in the core", lit > 0.95 and shaded < 0.2, "above %.2f, core %.2f" % [lit, shaded])

	# Timings, as an AI would call them.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var n := 200
	var started := Time.get_ticks_usec()
	for i in n:
		var a := Vector3(rng.randf_range(-20000, 20000), rng.randf_range(800, 9000), rng.randf_range(-20000, 20000))
		var b := Vector3(rng.randf_range(-20000, 20000), rng.randf_range(800, 9000), rng.randf_range(-20000, 20000))
		PaintedCloudWorld.get_visibility(a, b)
	var los_ms := (Time.get_ticks_usec() - started) / 1000.0 / n
	started = Time.get_ticks_usec()
	for i in n:
		PaintedCloudWorld.get_hold_point(Vector3(rng.randf_range(-20000, 20000), rng.randf_range(800, 9000), rng.randf_range(-20000, 20000)), 300.0)
	var hold_ms := (Time.get_ticks_usec() - started) / 1000.0 / n
	started = Time.get_ticks_usec()
	for i in n * 10:
		PaintedCloudWorld.get_density(Vector3(rng.randf_range(-20000, 20000), rng.randf_range(800, 9000), rng.randf_range(-20000, 20000)))
	var density_us := float(Time.get_ticks_usec() - started) / (n * 10)
	print("test_queries: [3/3] timing")
	print("timing: line of sight %.2f ms (random ~30 km lines), hold point %.2f ms, density %.1f us" % [los_ms, hold_ms, density_us])
	print("test_queries: %s" % ("all passed" if failures == 0 else "%d failed" % failures))
	quit(failures)
