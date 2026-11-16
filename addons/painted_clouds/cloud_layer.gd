@tool
extends Resource
class_name PaintedCloudLayer
## One altitude layer of an endless PaintedCloudTileWorld: the same idea as a PaintedCloudScatter (noise, a
## jittered grid of candidates, rules), but as data, generated per cell on a fixed world grid so
## every tile gets exactly the same clouds for the same seed, wherever it's asked from.

@export var layer_name : String = "Layer"
@export var enabled : bool = true
## The noise that decides where clouds go (sampled in absolute world space). Its frequency sets
## how big the cloud groups and gaps are.
@export var noise : FastNoiseLite
## Distance between candidate points (m).
@export_range(100.0, 50000.0, 10.0, "or_greater", "suffix:m") var spacing : float = 2200.0
## The layer's base altitude (m); each rule's altitude range is added to it.
@export var altitude : float = 1500.0
## Added to the world seed for this layer, so layers don't line up with each other.
@export var seed_offset : int = 0
## What to place, checked in order (first fit wins). Empty uses PaintedCloudScatter's defaults.
@export var rules : Array[PaintedCloudScatterRule] = []


## The rules to use (call on the main thread: the defaults load recipes).
func resolved_rules() -> Array[PaintedCloudScatterRule]:
	return rules if !rules.is_empty() else PaintedCloudScatter.default_rules()


## The clouds whose candidate point falls in cell (cell_size square, absolute world space), as
## specs: {recipe, base : Vector3 (absolute), radius, height, detail, seed}. Safe on any thread
## once noise.seed is set.
func generate_cell(cell : Vector2i, cell_size : float, world_seed : int, use_rules : Array) -> Array:
	var specs : Array = []
	if !enabled or noise == null or use_rules.is_empty():
		return specs
	var lo := Vector2(cell) * cell_size
	var hi := lo + Vector2(cell_size, cell_size)
	var g0 := Vector2i((lo / spacing).floor())
	var g1 := Vector2i((hi / spacing).floor())
	var rng := RandomNumberGenerator.new()
	for gx in range(g0.x, g1.x + 1):
		for gz in range(g0.y, g1.y + 1):
			rng.seed = hash([world_seed, seed_offset, gx, gz])
			var x := (gx + rng.randf()) * spacing
			var z := (gz + rng.randf()) * spacing
			var size_roll := rng.randf()
			var height_roll := rng.randf()
			var altitude_roll := rng.randf()
			var chance_roll := rng.randf()
			var lobe_seed := rng.randi()
			if x < lo.x or x >= hi.x or z < lo.y or z >= hi.y:
				continue
			var v := (noise.get_noise_2d(x, z) + 1.0) * 0.5
			var rule : PaintedCloudScatterRule = null
			for candidate in use_rules:
				if candidate and v >= candidate.noise_range.x and v < candidate.noise_range.y and chance_roll < candidate.chance:
					rule = candidate
					break
			if rule == null:
				continue
			var strength := inverse_lerp(rule.noise_range.x, rule.noise_range.y, v)
			specs.append({
				"recipe": rule.recipe,
				"base": Vector3(x, altitude + lerpf(rule.altitude.x, rule.altitude.y, altitude_roll), z),
				"radius": lerpf(rule.radius.x, rule.radius.y, clampf(lerpf(size_roll, strength, rule.size_from_noise), 0.0, 1.0)),
				"height": lerpf(rule.height.x, rule.height.y, clampf(lerpf(height_roll, strength, rule.size_from_noise), 0.0, 1.0)),
				"detail": rule.detail,
				"seed": lobe_seed,
			})
	return specs
