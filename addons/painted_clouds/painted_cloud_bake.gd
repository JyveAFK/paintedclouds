@tool
extends Resource
class_name PaintedCloudBake
## A baked cloud volume over an axis-aligned box: RGBA half floats per voxel, r = signed distance
## to the cloud surface (m, negative inside), g = sunlight reaching the voxel through the clouds
## (0..1), b = sky light reaching it from above (0..1), a = the clouds' noise scale.
## The voxels are stored here as raw bytes, so gameplay queries (through PaintedCloudWorld) work with
## no renderer at all (headless, dedicated servers); the GPU texture is built from them on demand.

## The bake the clouds render from when a PaintedCloudsEffect has none of its own: the last one a
## PaintedCloudVolume baked or loaded.
static var active : PaintedCloudBake

## The voxels: RGBA half floats (8 bytes each), x fastest, then y, then z.
@export var voxels : PackedByteArray:
	set(value):
		voxels = value
		_check_ready()
@export var dimensions : Vector3i:
	set(value):
		dimensions = value
		_check_ready()
## The box's minimum corner (world, m).
@export var origin : Vector3:
	set(value):
		origin = value
		_update_box()
## The box's size (world, m).
@export var size : Vector3:
	set(value):
		size = value
		_update_box()
## A border (m, on x and z) inside the box that it doesn't answer for (contains() is false there):
## tiles carry a one-voxel border shared with their neighbours, and each answers only for its own
## cell, so exactly one tile answers anywhere.
var answer_margin := 0.0:
	set(value):
		answer_margin = value
		_update_box()
@export var voxel_size : float = 200.0
## Towards the sun when it was baked.
@export var sun_direction : Vector3 = Vector3(0.4, 0.6, 0.3).normalized()
## The edge softness the light bake used (m): density queries use it too.
@export var softness : float = 300.0
## The distance the field was capped at (m): beyond this the field only says "at least this far".
@export var max_distance : float = 4000.0
@export var cloud_count : int = 0
@export var primitive_count : int = 0

## Which answers win where bakes overlap: lower first (0 = near tiles and volumes, 1 = far tiles).
var tier := 0

var _texture : ImageTexture3D
var _ready := false
var _box_max := Vector3.ZERO
var _answer_min := Vector3.ZERO
var _answer_max := Vector3.ZERO

const CHANNEL_DISTANCE := 0
const CHANNEL_SUN := 1
const CHANNEL_SKY := 2
const CHANNEL_NOISE_SCALE := 3


func has_data() -> bool:
	return _ready


func _check_ready() -> void:
	_ready = dimensions.x > 0 and voxels.size() == dimensions.x * dimensions.y * dimensions.z * 8


## The voxels as a 3D texture for rendering, built on first use (and after set_voxels()).
func get_texture() -> ImageTexture3D:
	if _texture == null and has_data():
		var slice_bytes := dimensions.x * dimensions.y * 8
		var images : Array[Image] = []
		for z in dimensions.z:
			images.append(Image.create_from_data(dimensions.x, dimensions.y, false, Image.FORMAT_RGBAH,
				voxels.slice(z * slice_bytes, (z + 1) * slice_bytes)))
		_texture = ImageTexture3D.new()
		_texture.create(Image.FORMAT_RGBAH, dimensions.x, dimensions.y, dimensions.z, false, images)
	return _texture


## Replaces the voxels (and drops the texture, rebuilt on next use).
func set_voxels(data : PackedByteArray, dims : Vector3i) -> void:
	dimensions = Vector3i.ZERO # Not ready while the two disagree.
	voxels = data
	dimensions = dims
	_texture = null


func _update_box() -> void:
	_box_max = origin + size
	_answer_min = origin + Vector3(answer_margin, 0.0, answer_margin)
	_answer_max = _box_max - Vector3(answer_margin, 0.0, answer_margin)


## Whether this bake answers for p: inside its box, less its answer_margin.
func contains(p : Vector3) -> bool:
	return p.x >= _answer_min.x and p.y >= _answer_min.y and p.z >= _answer_min.z \
		and p.x < _answer_max.x and p.y < _answer_max.y and p.z < _answer_max.z


## Distance (m) from position to this bake's box (0 inside).
func distance_to_box(world_position : Vector3) -> float:
	return world_position.clamp(origin, origin + size).distance_to(world_position)


## One channel at position, blended between the nearest voxels (positions outside the box read
## its edge).
func sample_channel(world_position : Vector3, channel : int) -> float:
	if !has_data():
		return INF if channel == CHANNEL_DISTANCE else 1.0
	var local := (world_position - origin) / voxel_size - Vector3(0.5, 0.5, 0.5)
	var top := Vector3(dimensions - Vector3i.ONE)
	local = local.clamp(Vector3.ZERO, top)
	var i0 := Vector3i(local.floor())
	var i1 := (i0 + Vector3i.ONE).min(dimensions - Vector3i.ONE)
	var f := local - Vector3(i0)
	var row := dimensions.x * 8
	var slice := row * dimensions.y
	var c := channel * 2
	var x0 := i0.x * 8 + c
	var x1 := i1.x * 8 + c
	var y0 := i0.y * row
	var y1 := i1.y * row
	var z0 := i0.z * slice
	var z1 := i1.z * slice
	var near := lerpf(
		lerpf(voxels.decode_half(z0 + y0 + x0), voxels.decode_half(z0 + y0 + x1), f.x),
		lerpf(voxels.decode_half(z0 + y1 + x0), voxels.decode_half(z0 + y1 + x1), f.x), f.y)
	var far := lerpf(
		lerpf(voxels.decode_half(z1 + y0 + x0), voxels.decode_half(z1 + y0 + x1), f.x),
		lerpf(voxels.decode_half(z1 + y1 + x0), voxels.decode_half(z1 + y1 + x1), f.x), f.y)
	return lerpf(near, far, f.z)


## Signed distance (m) from position to the nearest cloud surface: negative inside a cloud.
## Outside the box: the distance to the box plus what's at its edge.
func get_distance(world_position : Vector3) -> float:
	return sample_channel(world_position, CHANNEL_DISTANCE) + distance_to_box(world_position)


## Rough cloud density at position: 0 in clear air, rising through the soft edge to 1 inside.
func get_density(world_position : Vector3) -> float:
	return clampf(0.5 - get_distance(world_position) / (2.0 * softness), 0.0, 1.0)
