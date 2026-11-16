extends SceneTree
## Bakes one of each built-in recipe side by side (into user://, leaving the demo's bake alone)
## and renders them to user://shots/gallery_*.png. Handy for tuning recipes. Run with Vulkan:
##   godot --path . -s res://tools/recipe_gallery.gd

const DIR := "res://addons/painted_clouds/recipes/"


func _initialize() -> void:
	print("recipe_gallery: [1/4] setting up")
	var demo : Node = (load("res://demo/demo.tscn") as PackedScene).instantiate()
	for name in ["PaintedCloudVolume", "HUD", "Beacon", "HoldMarker", "FloatingIsland"]:
		var n := demo.get_node_or_null(name)
		if n:
			demo.remove_child(n)
			n.free()
	var volume := PaintedCloudVolume.new()
	volume.name = "GalleryVolume"
	volume.size = Vector3(48000.0, 12000.0, 16000.0)
	volume.position = Vector3(0.0, 5000.0, 0.0)
	volume.bake_path = "user://gallery_bake.res"
	demo.add_child(volume)
	volume.sun = demo.get_node("Sun")
	# [recipe, x, base y, radius, height]
	var row := [
		["low_patch", -18000.0, 1200.0, 1000.0, 450.0],
		["cumulus", -12500.0, 1200.0, 1200.0, 2600.0],
		["tower", -4500.0, 1200.0, 1900.0, 8000.0],
		["stratocumulus_deck", 6500.0, 800.0, 4500.0, 600.0],
		["altocumulus_field", 17000.0, 4200.0, 4000.0, 400.0],
	]
	for entry in row:
		var cloud := PaintedCloudPoint.new()
		cloud.name = entry[0]
		cloud.recipe = load(DIR + entry[0] + ".tres")
		cloud.radius = entry[3]
		cloud.height = entry[4]
		cloud.lobe_seed = 5
		cloud.position = Vector3(entry[1], entry[2] - 5000.0, 0.0)
		volume.add_child(cloud)
	get_root().add_child(demo)
	var camera : Camera3D = demo.get_node("FlyCamera")
	camera.set_process(false)
	await process_frame
	print("recipe_gallery: [2/4] baking")
	volume.bake()
	print("recipe_gallery: [3/4] rendering")
	for i in 30:
		await process_frame
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/shots")
	var views := [
		["gallery_row", Vector3(0, 3500, 26000), Vector3(-2, 0, 0), 75.0],
		["gallery_sheets", Vector3(11000, 6500, 9000), Vector3(-28, 0, 0), 75.0],
	]
	for view in views:
		camera.position = view[1]
		camera.rotation_degrees = view[2]
		camera.fov = view[3]
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := OS.get_user_data_dir() + "/shots/%s.png" % view[0]
		get_root().get_texture().get_image().save_png(path)
		print("recipe_gallery: shot ", path)
	print("recipe_gallery: [4/4] done")
	quit()
