@tool
extends Node3D
class_name PaintedCloudScatter
## Scatters PaintedCloudPoints over an area from 2D noise: a jittered grid of candidates, each matched
## against the rules in order (first fit wins) or left as a gap. The noise is sampled in world
## space, so neighbouring scatters (and later, tiles) line up. Use several scatters at different
## heights for layers: a low deck, the main cumulus layer, an altocumulus layer above.
## The clouds it makes are ordinary PaintedCloudPoint children: move, resize or delete any afterwards.
## Pressing Scatter replaces only its own children; PaintedCloudPoints elsewhere are never touched.

## The noise that decides where clouds go. Preview it by putting the same FastNoiseLite in a
## NoiseTexture2D. Its frequency sets how big the cloud groups and gaps are.
@export var noise : FastNoiseLite

## The area to scatter over (m), centred on this node.
@export var area_size := Vector2(40000.0, 40000.0)

## Distance between candidate points (m). Smaller packs clouds closer.
@export_range(100.0, 30000.0, 10.0, "or_greater", "suffix:m") var spacing : float = 2200.0

## Seeds the noise, the jitter and every cloud's lobes.
@export var scatter_seed : int = 1

## Optional black and white mask over the area: black keeps the sky clear there (e.g. around a
## city or along a flight path). Its top edge is -Z.
@export var mask : Texture2D

## What to place, checked in order. Empty uses the defaults: towers on the peaks, cumulus around
## them, low patches at the fringes.
@export var rules : Array[PaintedCloudScatterRule] = []

@export_tool_button("Scatter", "RandomNumberGenerator") var scatter_action = scatter
@export_tool_button("Clear", "Remove") var clear_action = clear


## The default rules (used when rules is empty).
static func default_rules() -> Array[PaintedCloudScatterRule]:
	var dir := "res://addons/painted_clouds/recipes/"
	var tower := PaintedCloudScatterRule.new()
	tower.recipe = load(dir + "tower.tres")
	tower.noise_range = Vector2(0.68, 1.0)
	tower.radius = Vector2(1200.0, 2200.0)
	tower.height = Vector2(5000.0, 9000.0)
	tower.size_from_noise = 0.7
	var cumulus := PaintedCloudScatterRule.new()
	cumulus.recipe = load(dir + "cumulus.tres")
	cumulus.noise_range = Vector2(0.52, 0.68)
	cumulus.radius = Vector2(600.0, 1300.0)
	cumulus.height = Vector2(1200.0, 3000.0)
	var low := PaintedCloudScatterRule.new()
	low.recipe = load(dir + "low_patch.tres")
	low.noise_range = Vector2(0.42, 0.52)
	low.radius = Vector2(500.0, 1100.0)
	low.height = Vector2(250.0, 500.0)
	low.size_from_noise = 0.5
	return [tower, cumulus, low]


func clear() -> void:
	for child in get_children():
		if child is PaintedCloudPoint:
			remove_child(child)
			child.queue_free()


func scatter() -> void:
	var started := Time.get_ticks_msec()
	print("PaintedCloudScatter '%s': [1/3] clearing previous scatter" % name)
	clear()
	if noise == null:
		noise = FastNoiseLite.new()
		noise.frequency = 0.00006
		noise.fractal_octaves = 3
	noise.seed = scatter_seed
	var use_rules := rules if !rules.is_empty() else default_rules()
	var rng := RandomNumberGenerator.new()
	rng.seed = scatter_seed
	var mask_image : Image = null
	if mask:
		mask_image = mask.get_image()
		if mask_image and mask_image.is_compressed():
			mask_image.decompress()
	var cols := maxi(int(area_size.x / spacing), 1)
	var rows := maxi(int(area_size.y / spacing), 1)
	var total := cols * rows
	print("PaintedCloudScatter '%s': [2/3] sampling %d x %d = %d candidates, %d rules" % [name, cols, rows, total, use_rules.size()])
	var owner_node := get_tree().edited_scene_root if Engine.is_editor_hint() and is_inside_tree() else owner
	var origin := global_position if is_inside_tree() else position
	var counts := {}
	var placed := 0
	var done := 0
	var next_report := 0.25
	for gx in cols:
		for gz in rows:
			done += 1
			if float(done) / total >= next_report:
				print("PaintedCloudScatter '%s':       %d%% (%d / %d, %d placed)" % [name, roundi(next_report * 100.0), done, total, placed])
				next_report += 0.25
			var x := (gx + rng.randf()) * spacing - area_size.x * 0.5
			var z := (gz + rng.randf()) * spacing - area_size.y * 0.5
			# Spend random numbers in the same order whatever is kept, so tweaking a rule doesn't
			# reshuffle every other cloud.
			var size_roll := rng.randf()
			var height_roll := rng.randf()
			var altitude_roll := rng.randf()
			var chance_roll := rng.randf()
			var lobe_seed := rng.randi()
			var v := (noise.get_noise_2d(origin.x + x, origin.z + z) + 1.0) * 0.5
			if mask_image:
				var uv := Vector2(x / area_size.x + 0.5, z / area_size.y + 0.5)
				var px := Vector2i((uv * Vector2(mask_image.get_size() - Vector2i.ONE)).round())
				v *= mask_image.get_pixelv(px.clamp(Vector2i.ZERO, mask_image.get_size() - Vector2i.ONE)).r
			var rule : PaintedCloudScatterRule = null
			for candidate in use_rules:
				if candidate and v >= candidate.noise_range.x and v < candidate.noise_range.y and chance_roll < candidate.chance:
					rule = candidate
					break
			if rule == null:
				continue
			var strength := inverse_lerp(rule.noise_range.x, rule.noise_range.y, v)
			var cloud := PaintedCloudPoint.new()
			cloud.recipe = rule.recipe
			cloud.lobe_seed = lobe_seed
			cloud.detail = rule.detail
			cloud.radius = lerpf(rule.radius.x, rule.radius.y, clampf(lerpf(size_roll, strength, rule.size_from_noise), 0.0, 1.0))
			cloud.height = lerpf(rule.height.x, rule.height.y, clampf(lerpf(height_roll, strength, rule.size_from_noise), 0.0, 1.0))
			var kind := rule.recipe.display_name if rule.recipe else "Cloud"
			counts[kind] = counts.get(kind, 0) + 1
			cloud.name = "%s_%d" % [kind.to_pascal_case(), counts[kind] - 1]
			cloud.position = Vector3(x, lerpf(rule.altitude.x, rule.altitude.y, altitude_roll), z)
			add_child(cloud)
			if owner_node:
				cloud.owner = owner_node
			placed += 1
	var summary := PackedStringArray()
	for kind in counts:
		summary.append("%d %s" % [counts[kind], kind])
	print("PaintedCloudScatter '%s': [3/3] placed %d clouds (%s) from %d candidates in %d ms" % [
		name, placed, ", ".join(summary), total, Time.get_ticks_msec() - started])
