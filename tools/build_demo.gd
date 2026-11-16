extends SceneTree
## Builds res://demo/demo.tscn: sky, sun, a floating island to show the clouds hiding scenery,
## a PaintedCloudVolume with three scatter layers (low decks, the main cumulus layer, high altocumulus)
## plus a hand-placed tower, a beacon and hold marker for the gameplay queries, the compositor
## effect, a fly camera and the HUD. Then scatters and bakes. Run with a Vulkan renderer:
##   godot --path . -s res://tools/build_demo.gd


func _initialize() -> void:
	print("build_demo: [1/5] building scene")
	var root := Node3D.new()
	root.name = "Demo"

	var env := Environment.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.09, 0.30, 0.74)
	sky_material.sky_horizon_color = Color(0.50, 0.68, 0.92)
	sky_material.sky_curve = 0.12
	sky_material.ground_bottom_color = Color(0.20, 0.38, 0.72)
	sky_material.ground_horizon_color = Color(0.50, 0.68, 0.92)
	sky_material.sun_angle_max = 8.0
	var sky := Sky.new()
	sky.sky_material = sky_material
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.3, 0.55, 0.78, 1.0])
	gradient.colors = PackedColorArray([
		Color("3558aa"), Color("7d88cf"), Color("cdb3dc"), Color("f8e9f0"), Color("fffbf3")])
	var gradient_texture := GradientTexture1D.new()
	gradient_texture.gradient = gradient
	gradient_texture.width = 256

	var fast_noise := FastNoiseLite.new()
	fast_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	fast_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	fast_noise.frequency = 0.07
	fast_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	fast_noise.fractal_octaves = 2
	var noise_texture := NoiseTexture3D.new()
	noise_texture.width = 64
	noise_texture.height = 64
	noise_texture.depth = 64
	noise_texture.seamless = true
	noise_texture.invert = true
	noise_texture.normalize = true
	noise_texture.noise = fast_noise

	var effect := PaintedCloudsEffect.new()
	effect.gradient = gradient_texture
	effect.noise = noise_texture
	var compositor := Compositor.new()
	compositor.compositor_effects = [effect]

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	world_env.compositor = compositor
	_add(root, world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-32.0, 35.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	_add(root, sun)

	# A floating island in the clouds, to show them hiding scenery.
	var island := MeshInstance3D.new()
	island.name = "FloatingIsland"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1400.0
	mesh.bottom_radius = 300.0
	mesh.height = 900.0
	var island_material := StandardMaterial3D.new()
	island_material.albedo_color = Color(0.55, 0.42, 0.32)
	mesh.material = island_material
	island.mesh = mesh
	island.position = Vector3(-2500.0, 2600.0, 6000.0)
	_add(root, island)

	var volume := PaintedCloudVolume.new()
	volume.name = "PaintedCloudVolume"
	volume.position = Vector3(0.0, 6000.0, 0.0)
	volume.bake_path = "res://clouds/sky_bake.res"
	_add(root, volume)
	volume.sun = sun

	var recipes := "res://addons/painted_clouds/recipes/"
	# Layer 1: the main cumulus layer (default rules: towers, cumulus, low patches), bases at 1500 m.
	var scatter := PaintedCloudScatter.new()
	scatter.name = "MainLayer"
	scatter.position = Vector3(0.0, -4500.0, 0.0)
	scatter.area_size = Vector2(44000.0, 44000.0)
	var scatter_noise := FastNoiseLite.new()
	scatter_noise.frequency = 0.00007
	scatter_noise.fractal_octaves = 3
	scatter.noise = scatter_noise
	scatter.scatter_seed = 7
	_add(volume, scatter)

	# Layer 2: a few stratocumulus decks underneath, bases around 600 m.
	var deck_layer := PaintedCloudScatter.new()
	deck_layer.name = "LowDeckLayer"
	deck_layer.position = Vector3(0.0, -5400.0, 0.0)
	deck_layer.area_size = Vector2(44000.0, 44000.0)
	deck_layer.spacing = 13000.0
	var deck_noise := FastNoiseLite.new()
	deck_noise.frequency = 0.00004
	deck_layer.noise = deck_noise
	deck_layer.scatter_seed = 21
	var deck := PaintedCloudScatterRule.new()
	deck.recipe = load(recipes + "stratocumulus_deck.tres")
	deck.noise_range = Vector2(0.45, 1.0)
	deck.chance = 0.85
	deck.radius = Vector2(5000.0, 8500.0)
	deck.height = Vector2(450.0, 750.0)
	deck.altitude = Vector2(-100.0, 100.0)
	deck_layer.rules = [deck]
	_add(volume, deck_layer)

	# Layer 3: altocumulus fields high above, bases around 5500 m.
	var high_layer := PaintedCloudScatter.new()
	high_layer.name = "HighLayer"
	high_layer.position = Vector3(0.0, -500.0, 0.0)
	high_layer.area_size = Vector2(44000.0, 44000.0)
	high_layer.spacing = 9000.0
	var high_noise := FastNoiseLite.new()
	high_noise.frequency = 0.00005
	high_layer.noise = high_noise
	high_layer.scatter_seed = 33
	var field := PaintedCloudScatterRule.new()
	field.recipe = load(recipes + "altocumulus_field.tres")
	field.noise_range = Vector2(0.5, 1.0)
	field.chance = 0.8
	field.radius = Vector2(3500.0, 5500.0)
	field.height = Vector2(300.0, 500.0)
	field.altitude = Vector2(-300.0, 300.0)
	field.size_from_noise = 0.3
	high_layer.rules = [field]
	_add(volume, high_layer)

	var hand := Node3D.new()
	hand.name = "HandPlaced"
	_add(volume, hand)
	var tower := PaintedCloudPoint.new()
	tower.name = "HeroTower"
	tower.recipe = load(recipes + "tower.tres")
	tower.radius = 2000.0
	tower.height = 8500.0
	tower.detail = 1.2
	tower.lobe_seed = 3
	tower.position = Vector3(3000.0, -4500.0, -4000.0)
	_add(hand, tower)

	# A beacon behind the hero tower, for the line of sight readout.
	var beacon := MeshInstance3D.new()
	beacon.name = "Beacon"
	var beacon_mesh := SphereMesh.new()
	beacon_mesh.radius = 120.0
	beacon_mesh.height = 240.0
	var beacon_material := StandardMaterial3D.new()
	beacon_material.albedo_color = Color(1.0, 0.3, 0.2)
	beacon_material.emission_enabled = true
	beacon_material.emission = Color(1.0, 0.3, 0.2)
	beacon_material.emission_energy_multiplier = 4.0
	beacon_mesh.material = beacon_material
	beacon.mesh = beacon_mesh
	beacon.position = Vector3(4500.0, 4000.0, -13000.0)
	_add(root, beacon)

	# Where the hold-point query puts a ship near the camera.
	var hold := MeshInstance3D.new()
	hold.name = "HoldMarker"
	var hold_mesh := SphereMesh.new()
	hold_mesh.radius = 40.0
	hold_mesh.height = 80.0
	var hold_material := StandardMaterial3D.new()
	hold_material.albedo_color = Color(1.0, 0.85, 0.2)
	hold_material.emission_enabled = true
	hold_material.emission = Color(1.0, 0.85, 0.2)
	hold_material.emission_energy_multiplier = 3.0
	hold_mesh.material = hold_material
	hold.mesh = hold_mesh
	_add(root, hold)

	var camera := Camera3D.new()
	camera.name = "FlyCamera"
	camera.set_script(load("res://demo/fly_camera.gd"))
	camera.far = 120000.0
	camera.fov = 70.0
	camera.position = Vector3(0.0, 2400.0, 16000.0)
	camera.rotation_degrees = Vector3(6.0, 0.0, 0.0)
	_add(root, camera)

	var hud := Label.new()
	hud.name = "HUD"
	hud.set_script(load("res://demo/hud.gd"))
	hud.position = Vector2(12, 8)
	hud.add_theme_color_override("font_color", Color.WHITE)
	hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_add(root, hud)
	hud.beacon = beacon
	hud.hold_marker = hold

	get_root().add_child(root)
	await process_frame
	print("build_demo: [2/5] scattering 3 layers")
	for layer in [scatter, deck_layer, high_layer]:
		layer.scatter()
		for child in layer.get_children():
			child.owner = root
	print("build_demo: [3/5] baking")
	volume.bake()
	print("build_demo: [4/5] saving demo/demo.tscn")
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err == OK:
		err = ResourceSaver.save(packed, "res://demo/demo.tscn")
	print("build_demo: [5/5] done (error %d)" % err)
	quit()


func _add(parent : Node, child : Node) -> void:
	parent.add_child(child)
	child.owner = parent if parent.owner == null else parent.owner
