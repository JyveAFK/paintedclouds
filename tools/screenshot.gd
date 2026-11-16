extends SceneTree
## Renders the demo from a few viewpoints to user://shots/ (for checking the look).

var views := [
	["start", Vector3(0, 2400, 16000), Vector3(6, 0, 0)],
	["high", Vector3(-9000, 9000, 20000), Vector3(-14, -20, 0)],
	["above_deck", Vector3(5900, 2600, 21000), Vector3(-14, 0, 0)],
	["under_deck", Vector3(5900, 250, 19000), Vector3(6, 0, 0)],
	["alto_above", Vector3(-1000, 7600, 17500), Vector3(-16, 0, 0)],
	["alto_below", Vector3(-1000, 3700, 15500), Vector3(16, 0, 0)],
]

func _initialize() -> void:
	var scene : PackedScene = load("res://demo/demo.tscn")
	var demo := scene.instantiate()
	get_root().add_child(demo)
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	for i in 40:
		await process_frame
	for view in views:
		camera.position = view[1]
		camera.rotation_degrees = view[2]
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var image := get_root().get_texture().get_image()
		var path := OS.get_user_data_dir() + "/shots/%s.png" % view[0]
		image.save_png(path)
		print("shot ", path)
	quit()
