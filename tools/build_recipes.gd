extends SceneTree
## Writes the built-in cloud recipes to res://addons/painted_clouds/recipes/. Run:
##   godot --headless --path . -s res://tools/build_recipes.gd
## (They're ordinary .tres files: edit them in the inspector afterwards.)

const DIR := "res://addons/painted_clouds/recipes/"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var recipes := {
		"cumulus": _cumulus(),
		"tower": _tower(),
		"low_patch": _low_patch(),
		"stratocumulus_deck": _stratocumulus_deck(),
		"altocumulus_field": _altocumulus_field(),
	}
	var i := 0
	for key in recipes:
		i += 1
		var err := ResourceSaver.save(recipes[key], DIR + key + ".tres")
		print("build_recipes: [%d/%d] %s -> %s" % [i, recipes.size(), key, "ok" if err == OK else "error %d" % err])
	quit()


func _part(shape : int, radius_scale : float, height_at : float, radius_lift : float, top_at := 1.0, top_lift := -1.0, squash := 1.0) -> PaintedCloudPart:
	var p := PaintedCloudPart.new()
	p.shape = shape
	p.radius_scale = radius_scale
	p.height_at = height_at
	p.radius_lift = radius_lift
	p.top_height_at = top_at
	p.top_radius_lift = top_lift
	p.squash = squash
	return p


func _lobes(placement : int, count : int, size : Vector2, outward : Vector2, up_bias : float, part_index := 0) -> PaintedCloudLobeRule:
	var l := PaintedCloudLobeRule.new()
	l.placement = placement
	l.count = count
	l.size = size
	l.outward = outward
	l.up_bias = up_bias
	l.part_index = part_index
	return l


func _cumulus() -> PaintedCloudRecipe:
	var r := PaintedCloudRecipe.new()
	r.display_name = "Cumulus"
	r.gizmo_color = Color(1.0, 1.0, 1.0, 0.8)
	r.parts = [_part(PaintedCloudPart.Shape.CAPSULE, 1.0, 0.0, 0.6, 1.0, -1.0)]
	var big := _lobes(PaintedCloudLobeRule.Placement.PART, 12, Vector2(0.33, 0.55), Vector2(0.6, 0.95), 0.9)
	var small := _lobes(PaintedCloudLobeRule.Placement.PREVIOUS_LOBES, 16, Vector2(0.3, 0.55), Vector2(0.7, 0.95), 0.8)
	small.outward_bias = 1.0
	r.lobes = [big, small]
	return r


func _tower() -> PaintedCloudRecipe:
	var r := PaintedCloudRecipe.new()
	r.display_name = "Tower"
	r.gizmo_color = Color(1.0, 0.7, 0.4, 0.8)
	r.noise_scale = 1.2
	r.parts = [
		_part(PaintedCloudPart.Shape.CAPSULE, 1.0, 0.0, 0.8, 1.0, -0.9),
		_part(PaintedCloudPart.Shape.SPHERE, 1.27, 0.68, 0.0, 1.0, -1.0, 0.8), # shoulder
		_part(PaintedCloudPart.Shape.SPHERE, 1.6, 1.0, -0.64, 1.0, -1.0, 0.42), # anvil
	]
	var column := _lobes(PaintedCloudLobeRule.Placement.PART, 20, Vector2(0.33, 0.55), Vector2(0.6, 0.95), 0.9)
	column.height_range = Vector2(0.15, 1.0)
	var anvil_top := _lobes(PaintedCloudLobeRule.Placement.PART, 7, Vector2(0.25, 0.4), Vector2(0.3, 0.8), 1.0, 2)
	anvil_top.squash_scale = 1.55
	var small := _lobes(PaintedCloudLobeRule.Placement.PREVIOUS_LOBES, 28, Vector2(0.3, 0.55), Vector2(0.7, 0.95), 0.8)
	small.outward_bias = 1.0
	# Order matters: the small lobes sit on the rule just before them, the column's billows.
	r.lobes = [anvil_top, column, small]
	return r


func _low_patch() -> PaintedCloudRecipe:
	var r := PaintedCloudRecipe.new()
	r.display_name = "Low Patch"
	r.gizmo_color = Color(0.55, 0.75, 1.0, 0.8)
	r.noise_scale = 0.8
	var core := _part(PaintedCloudPart.Shape.SPHERE, 1.0, 0.45, 0.0)
	core.squash_from_height = true
	r.parts = [core]
	var big := _lobes(PaintedCloudLobeRule.Placement.PART, 6, Vector2(0.33, 0.55), Vector2(0.6, 0.95), 0.9)
	big.flatten = 0.6
	big.squash_scale = 1.6
	var small := _lobes(PaintedCloudLobeRule.Placement.PREVIOUS_LOBES, 6, Vector2(0.3, 0.55), Vector2(0.7, 0.95), 0.8)
	small.outward_bias = 1.0
	r.lobes = [big, small]
	return r


func _stratocumulus_deck() -> PaintedCloudRecipe:
	var r := PaintedCloudRecipe.new()
	r.display_name = "Stratocumulus Deck"
	r.gizmo_color = Color(0.75, 0.8, 0.95, 0.7)
	r.noise_scale = 0.7
	r.sheet = true
	r.sheet_cell = 0.11
	r.sheet_coverage = 0.85
	r.sheet_puff_size = Vector2(0.65, 1.0)
	r.sheet_edge = 0.3
	r.sheet_clumping = 0.45
	r.sheet_height_jitter = 0.25
	# Lumpy tops: a rounded hump on many of the puffs.
	var humps := _lobes(PaintedCloudLobeRule.Placement.SHEET_PUFFS, 0, Vector2(0.4, 0.65), Vector2(0.3, 0.7), 1.0)
	humps.count_per_parent = 0.6
	humps.squash_scale = 1.4
	r.lobes = [humps]
	return r


func _altocumulus_field() -> PaintedCloudRecipe:
	var r := PaintedCloudRecipe.new()
	r.display_name = "Altocumulus Field"
	r.gizmo_color = Color(0.85, 0.75, 1.0, 0.7)
	r.flat_base = false
	r.noise_scale = 0.3
	r.sheet = true
	# Small puffs well apart, in loose clumps: a field with sky between, not one raft.
	r.sheet_cell = 0.17
	r.sheet_coverage = 0.55
	r.sheet_puff_size = Vector2(0.3, 0.45)
	r.sheet_edge = 0.45
	r.sheet_clumping = 0.6
	r.sheet_height_jitter = 1.2
	var tops := _lobes(PaintedCloudLobeRule.Placement.SHEET_PUFFS, 0, Vector2(0.5, 0.7), Vector2(0.3, 0.6), 1.0)
	tops.count_per_parent = 0.4
	r.lobes = [tops]
	return r
