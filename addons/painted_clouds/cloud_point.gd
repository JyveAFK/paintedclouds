@tool
extends Node3D
class_name PaintedCloudPoint
## One authored cloud. Its position is the centre of the cloud's base; it grows upward. Its
## recipe (a PaintedCloudRecipe) says what kind of cloud it is; radius and height size it, and the seed
## places its lobes (or a sheet's puffs). On bake it becomes primitives that the bake merges with
## every other cloud into one smooth signed distance field. Its rotation and scale are ignored.

const DEFAULT_RECIPE := "res://addons/painted_clouds/recipes/cumulus.tres"
const NO_FLOOR := -1.0e9

## The kind of cloud. Empty uses the cumulus recipe.
@export var recipe : PaintedCloudRecipe:
	set(value):
		if recipe and recipe.changed.is_connected(update_gizmos):
			recipe.changed.disconnect(update_gizmos)
		recipe = value
		if recipe and is_inside_tree():
			recipe.changed.connect(update_gizmos)
		update_gizmos()

## Core radius (m). For a sheet, the radius of the whole field.
@export_range(50.0, 30000.0, 10.0, "or_greater", "suffix:m") var radius : float = 1200.0:
	set(value):
		radius = value
		update_gizmos()

## Height from the base to the top (m). For a sheet, its thickness.
@export_range(50.0, 20000.0, 10.0, "or_greater", "suffix:m") var height : float = 3000.0:
	set(value):
		height = value
		update_gizmos()

## Scales the recipe's lobe counts: 0 = core only, 1 = as the recipe says, 2 = twice as many.
@export_range(0.0, 3.0, 0.01) var detail : float = 1.0:
	set(value):
		detail = value
		update_gizmos()

## Seeds the lobe (and sheet puff) placement. The same seed always gives the same cloud.
@export var lobe_seed : int = 0:
	set(value):
		lobe_seed = value
		update_gizmos()


func _enter_tree() -> void:
	if recipe and !recipe.changed.is_connected(update_gizmos):
		recipe.changed.connect(update_gizmos)


func get_recipe() -> PaintedCloudRecipe:
	if recipe:
		return recipe
	return load(DEFAULT_RECIPE) if ResourceLoader.exists(DEFAULT_RECIPE) else PaintedCloudRecipe.new()


## The cloud's primitives in world space: an Array of [a : Vector3, b : Vector3, radius : float,
## squash : float, floor_y : float, noise_scale : float, role : int]. Each is a capsule from a to b
## (a sphere when a == b) whose vertical extent is squashed by squash (1 = round), cut off below
## floor_y. role: 0 = core part, 1 = sheet puff, 2 = lobe (for the gizmo).
func build_primitives() -> Array:
	var base := global_position if is_inside_tree() else position
	return build_primitives_for(get_recipe(), base, radius, height, detail, lobe_seed)


## As build_primitives(), without a node: for a cloud of recipe at base (world), radius, height,
## detail and seed. Safe on any thread.
static func build_primitives_for(r : PaintedCloudRecipe, base : Vector3, radius : float, height : float, detail : float, lobe_seed : int) -> Array:
	if r == null:
		r = load(DEFAULT_RECIPE) if ResourceLoader.exists(DEFAULT_RECIPE) else PaintedCloudRecipe.new()
	var floor_y := base.y if r.flat_base else NO_FLOOR
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([lobe_seed, r.resource_path if r.resource_path != "" else r.display_name])
	var prims : Array = []
	# What lobes can sit on: [a, b, radius, squash].
	var parts : Array = []
	var puffs : Array = []

	for part in r.parts:
		if part == null:
			continue
		var pr := radius * part.radius_scale
		var squash := part.squash
		if part.squash_from_height:
			squash = clampf(height / (2.0 * pr), 0.02, 1.0) * part.squash
		var side := Vector3(part.offset.x * radius, 0.0, part.offset.y * radius)
		var a := base + side + Vector3.UP * (height * part.height_at + radius * part.radius_lift)
		var b := a
		if part.shape == PaintedCloudPart.Shape.CAPSULE:
			b = base + side + Vector3.UP * (height * part.top_height_at + radius * part.top_radius_lift)
			b.y = maxf(b.y, a.y)
		parts.append([a, b, pr, squash])
		prims.append([a, b, pr, squash, floor_y, r.noise_scale, 0])

	if r.sheet:
		_build_sheet(r, base, radius, height, lobe_seed, floor_y, rng, puffs, prims)

	var cloud_centre := base + Vector3.UP * height * 0.5
	var previous : Array = []
	for rule in r.lobes:
		if rule == null:
			continue
		var parents : Array
		match rule.placement:
			PaintedCloudLobeRule.Placement.PART:
				parents = [parts[clampi(rule.part_index, 0, parts.size() - 1)]] if !parts.is_empty() else []
			PaintedCloudLobeRule.Placement.PREVIOUS_LOBES:
				parents = previous
			PaintedCloudLobeRule.Placement.SHEET_PUFFS:
				parents = puffs
		var count := roundi((rule.count + rule.count_per_parent * parents.size()) * detail)
		var made : Array = []
		if parents.is_empty():
			count = 0
		for i in count:
			var parent : Array = parents[rng.randi() % parents.size()]
			var t := rng.randf_range(rule.height_range.x, rule.height_range.y)
			var on : Vector3 = (parent[0] as Vector3).lerp(parent[1], clampf(t, 0.0, 1.0))
			var dir := _random_dir(rng)
			var bias := rule.up_bias
			if bias >= 0.0:
				dir.y = lerpf(dir.y, absf(dir.y), bias) + bias * 0.15
			else:
				dir.y = lerpf(dir.y, -absf(dir.y), -bias) + bias * 0.15
			dir.y *= 1.0 - rule.flatten
			if rule.outward_bias > 0.0:
				var away := on - cloud_centre
				away.y = maxf(away.y, 0.0) if bias >= 0.0 else away.y
				if away.length_squared() > 1.0:
					dir += away.normalized() * rule.outward_bias
			dir = dir.normalized() if dir.length_squared() > 1e-6 else Vector3.UP
			var parent_radius : float = parent[2]
			var parent_squash : float = parent[3]
			var offset := dir * parent_radius * rng.randf_range(rule.outward.x, rule.outward.y)
			offset.y *= parent_squash
			var lobe_radius := parent_radius * rng.randf_range(rule.size.x, rule.size.y)
			var lobe_squash := minf(parent_squash * rule.squash_scale, 1.0)
			var centre := on + offset
			made.append([centre, centre, lobe_radius, lobe_squash])
			prims.append([centre, centre, lobe_radius, lobe_squash, floor_y, r.noise_scale, 2])
		previous = made
	return prims


static func _build_sheet(r : PaintedCloudRecipe, base : Vector3, radius : float, height : float, lobe_seed : int, floor_y : float,
		rng : RandomNumberGenerator, puffs : Array, prims : Array) -> void:
	var cell := maxf(radius * r.sheet_cell, 10.0)
	var n := ceili(radius / cell)
	var clumps := FastNoiseLite.new()
	clumps.seed = lobe_seed
	clumps.frequency = 1.0 / (cell * 3.5)
	for gx in range(-n, n + 1):
		for gz in range(-n, n + 1):
			var jitter := Vector2(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.4, 0.4))
			var roll := rng.randf()
			var size_roll := rng.randf()
			var height_roll := rng.randf_range(-1.0, 1.0)
			var local := (Vector2(gx, gz) + jitter) * cell
			var rim := local.length() / radius
			if rim > 1.0:
				continue
			var edge := 1.0 - smoothstep(1.0 - r.sheet_edge, 1.0, rim) if r.sheet_edge > 0.0 else 1.0
			# Clumps follow the cloud's own seed, not where it is, so a cloud looks the same
			# wherever it's placed (and in every tile that bakes it).
			var clump := clumps.get_noise_2d(local.x, local.y) * 0.5 + 0.5
			var chance := r.sheet_coverage * edge * lerpf(1.0, clump * 2.0, r.sheet_clumping)
			if roll >= chance:
				continue
			var puff_radius := cell * lerpf(r.sheet_puff_size.x, r.sheet_puff_size.y, size_roll) * lerpf(0.6, 1.0, edge)
			var squash := clampf(height / (2.0 * puff_radius), 0.02, 1.0)
			var centre := base + Vector3(local.x, height * 0.5 + height_roll * height * r.sheet_height_jitter * 0.5, local.y)
			puffs.append([centre, centre, puff_radius, squash])
			prims.append([centre, centre, puff_radius, squash, floor_y, r.noise_scale, 1])


static func _random_dir(rng : RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf() * TAU
	var s := sqrt(1.0 - z * z)
	return Vector3(s * cos(a), z, s * sin(a))
