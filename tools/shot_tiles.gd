extends SceneTree
## Renders the tile demo after a floating-origin shift (from above, and close up beside a cloud,
## placed with PaintedCloudWorld.get_hold_point) to user://shots/. Needs Vulkan.

func _wait(world : PaintedCloudTileWorld) -> void:
	# process_frame comes before the nodes' _process: give the world a few frames to see changes.
	for i in 3:
		await process_frame
	while true:
		await process_frame
		var s := world.get_status()
		if s.ready == s.wanted and s.jobs == 0:
			return


func _shot(name : String) -> void:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := OS.get_user_data_dir() + "/shots/%s.png" % name
	get_root().get_texture().get_image().save_png(path)
	print("shot_tiles: ", path)


func _initialize() -> void:
	var demo : Node = (load("res://demo/demo_tiles.tscn") as PackedScene).instantiate()
	get_root().add_child(demo)
	var world : PaintedCloudTileWorld = demo.get_node("PaintedCloudTileWorld")
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	camera.position = Vector3(47000.0, 9500.0, 33000.0) # past the threshold: shifts
	camera.rotation_degrees = Vector3(-16.0, 30.0, 0.0)
	await _wait(world)
	print("shot_tiles: offset %s, camera %s" % [world.offset_cells, camera.position])
	await _shot("shifted_above")
	# Close up: 500 m off the nearest cloud, placed with PaintedCloudWorld.get_hold_point.
	camera.position.y = 2600.0
	await _wait(world)
	var hold := PaintedCloudWorld.get_hold_point(camera.position, 500.0)
	camera.position = hold
	var to_cloud := PaintedCloudWorld.get_direction_to_cloud(hold)
	if to_cloud != Vector3.ZERO:
		camera.look_at(hold + to_cloud * 1000.0 + Vector3.UP * 150.0)
	await _wait(world)
	print("shot_tiles: close-up at %s, cloud %.0f m away" % [hold, PaintedCloudWorld.get_distance(hold)])
	await _shot("closeup")
	quit()
