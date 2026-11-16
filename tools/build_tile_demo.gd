extends SceneTree
## Builds res://demo/demo_tiles.tscn from the demo scene: the fixed PaintedCloudVolume replaced by an
## endless PaintedCloudTileWorld (3x3 tiles of 20 km, the same three layers as data), floating origin on
## at 30 km, the sun turnable with T. Nothing to bake: tiles bake as you fly. Run:
##   godot --headless --path . -s res://tools/build_tile_demo.gd

const RECIPES := "res://addons/painted_clouds/recipes/"


func _initialize() -> void:
	print("build_tile_demo: [1/3] building from demo.tscn")
	var root : Node3D = (load("res://demo/demo.tscn") as PackedScene).instantiate()
	var volume := root.get_node("PaintedCloudVolume")
	root.remove_child(volume)
	volume.free()
	var sun : DirectionalLight3D = root.get_node("Sun")
	sun.set_script(load("res://demo/sun_spinner.gd"))

	var world := PaintedCloudTileWorld.new()
	world.name = "PaintedCloudTileWorld"
	world.cell_size = 20000.0
	world.grid = PaintedCloudTileWorld.Grid.THREE_BY_THREE
	world.floor_height = 0.0
	world.ceiling_height = 13000.0
	world.world_seed = 7
	world.sun = sun
	world.target = root.get_node("FlyCamera")
	world.shift_threshold = 30000.0
	world.shift_root = root

	var main := PaintedCloudLayer.new()
	main.layer_name = "Main cumulus"
	main.noise = _noise(0.00007, 3)
	main.spacing = 2200.0
	main.altitude = 1500.0
	main.seed_offset = 0

	var decks := PaintedCloudLayer.new()
	decks.layer_name = "Low decks"
	decks.noise = _noise(0.00004, 2)
	decks.spacing = 13000.0
	decks.altitude = 600.0
	decks.seed_offset = 100
	var deck := PaintedCloudScatterRule.new()
	deck.recipe = load(RECIPES + "stratocumulus_deck.tres")
	deck.noise_range = Vector2(0.45, 1.0)
	deck.chance = 0.85
	deck.radius = Vector2(5000.0, 8500.0)
	deck.height = Vector2(450.0, 750.0)
	deck.altitude = Vector2(-100.0, 100.0)
	decks.rules = [deck]

	var high := PaintedCloudLayer.new()
	high.layer_name = "High altocumulus"
	high.noise = _noise(0.00005, 2)
	high.spacing = 9000.0
	high.altitude = 5500.0
	high.seed_offset = 200
	var field := PaintedCloudScatterRule.new()
	field.recipe = load(RECIPES + "altocumulus_field.tres")
	field.noise_range = Vector2(0.5, 1.0)
	field.chance = 0.8
	field.radius = Vector2(3500.0, 5500.0)
	field.height = Vector2(300.0, 500.0)
	field.altitude = Vector2(-300.0, 300.0)
	field.size_from_noise = 0.3
	high.rules = [field]

	world.layers = [main, decks, high]
	root.add_child(world)
	world.owner = root
	print("build_tile_demo: [2/3] saving demo/demo_tiles.tscn")
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err == OK:
		err = ResourceSaver.save(packed, "res://demo/demo_tiles.tscn")
	print("build_tile_demo: [3/3] done (error %d)" % err)
	root.free()
	quit()


func _noise(frequency : float, octaves : int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.frequency = frequency
	n.fractal_octaves = octaves
	return n
