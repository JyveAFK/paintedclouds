@tool
extends Node3D
class_name PaintedCloudTileWorld
## An endless sky: square cells of cloud generated from a seed (by its PaintedCloudLayers) or hand-made
## (a scene of PaintedCloudPoints for chosen cells), baked in the background into tiles around the
## target as it travels, 2x2 or 3x3 of them. Nothing is saved: the same seed always bakes the
## same clouds. Tiles are drawn by a PaintedCloudsEffect, and answer PaintedCloudWorld queries.
##
## Also: rings of coarse far tiles and very coarse horizon tiles beyond them, which the effect paints
## into a distant panorama so the clouds reach the horizon (and which answer queries further out, roughly); a background
## re-bake of the light as the sun moves; and an optional floating origin that moves shift_root's children back by whole cells (no re-bake).
## This node's own transform is ignored: the world is laid out from the origin.

signal tile_ready(cell : Vector2i)
## A far tile is baked (or re-lit).
signal far_tile_ready(cell : Vector2i)
## After a floating-origin shift: everything under shift_root moved by offset.
signal origin_shifted(offset : Vector3)

enum Grid { TWO_BY_TWO = 2, THREE_BY_THREE = 3 }

## The PaintedCloudTileWorld drawing now (a PaintedCloudsEffect draws it in preference to a bake).
static var active : PaintedCloudTileWorld

## What the tiles follow. Empty: the viewport's camera.
@export var target : Node3D
## Size of a cell (m), square.
@export_range(10000.0, 50000.0, 1000.0, "suffix:m") var cell_size : float = 20000.0
@export var grid : Grid = Grid.THREE_BY_THREE
## Voxel size of the tiles (m), rounded so a whole number fit a cell. Each 3x3 of 20 km tiles at
## 200 m with a 13 km ceiling is about 50 MB on the GPU (and as much again on the CPU, for queries).
@export_range(50.0, 1000.0, 5.0, "suffix:m") var voxel_size : float = 200.0
## The lowest and highest the clouds reach (m).
@export var floor_height : float = 0.0
@export var ceiling_height : float = 13000.0
@export var world_seed : int = 1
## The layers of generated cloud (each a scatter, as data).
@export var layers : Array[PaintedCloudLayer] = []
## Hand-made cells: a scene of PaintedCloudPoints (positions relative to the cell's corner, x and z
## 0..cell_size) used in place of the generated clouds for that cell.
@export var hand_made_cells : Dictionary[Vector2i, PackedScene] = {}

@export_group("Shape")
@export_range(0.0, 2000.0, 5.0, "suffix:m") var blend : float = 220.0
@export_range(500.0, 20000.0, 50.0, "suffix:m") var max_distance : float = 4000.0

@export_group("Light")
## The sun. When it turns more than relight_angle, the tiles re-bake their light in the background.
@export var sun : DirectionalLight3D
@export_range(0.0, 45.0, 0.1, "suffix:°") var relight_angle : float = 1.0
@export_range(100.0, 20000.0, 50.0, "suffix:m") var light_distance : float = 5000.0
@export_range(4, 64) var light_steps : int = 24
@export_range(100.0, 20000.0, 50.0, "suffix:m") var sky_distance : float = 3000.0
@export_range(10.0, 2000.0, 5.0, "suffix:m") var softness : float = 300.0
@export_range(0.0, 0.02, 0.0001) var extinction : float = 0.0012

@export_group("Distant clouds")
## Rings of coarse far tiles round the near ones, painted into a distant panorama so the clouds
## reach the horizon: 2 rings of 20 km cells show clouds about 50-70 km out. 0 = off.
@export_range(0, 6) var far_rings : int = 2
## Voxel size of the far tiles (m). Finer looks closer to the near clouds where they hand over: a
## 7x7 of 20 km at 600 m is about 11 MB.
@export_range(200.0, 4000.0, 10.0, "suffix:m") var far_voxel_size : float = 600.0
## Lobe detail of far clouds (times each cloud's own): small lobes don't show from far away, and
## fewer bake faster.
@export_range(0.0, 1.0, 0.01) var far_detail : float = 0.6
@export_range(1, 32) var far_light_steps : int = 10

@export_group("Horizon clouds")
## Rings of very coarse tiles beyond the far ones, painted into the distant panorama past them so
## that from altitude the clouds carry on towards the horizon, fading into the haze. 0 = off.
## 3 rings of 20 km cells reach about 130 km out.
@export_range(0, 8) var horizon_rings : int = 3
## Voxel size of the horizon tiles (m): only their general shape shows that far out.
@export_range(500.0, 8000.0, 50.0, "suffix:m") var horizon_voxel_size : float = 2000.0
## Lobe detail of horizon clouds (times each cloud's own).
@export_range(0.0, 1.0, 0.01) var horizon_detail : float = 0.12
@export_range(1, 32) var horizon_light_steps : int = 5

@export_group("Floating origin")
## When the target gets this far (m, on x or z) from the origin, everything under shift_root
## moves back by whole cells. 0 = off (use your own system and call shift_origin()).
@export_range(0.0, 1000000.0, 100.0, "suffix:m") var shift_threshold : float = 0.0
@export var shift_root : Node3D

@export_group("Editor")
## Stream and draw tiles in the editor too (round the editor camera).
@export var run_in_editor : bool = false

## Whole cells the world has been shifted by: absolute cell = local cell + offset_cells.
var offset_cells := Vector2i.ZERO
## The near tiles (full detail), the far ring (coarse) and the horizon ring (very coarse); the far
## and horizon rings are for the distant panorama.
var near : TileGrid
var far : TileGrid
var horizon : TileGrid


## A set of tiles round the target: which cells it wants, the ones baked, the bakes in flight,
## and their GPU atlas (grid_n x grid_n slots, each cell in slot cell mod grid_n).
class TileGrid:
	var name : String
	var tier : int
	var grid_n : int
	var across : int
	var voxel : float
	var dims : Vector3i
	var detail_scale : float
	var light_steps : int
	var priority_base : float
	var max_distance : float # What its distance field is capped at (coarser tiles reach further).
	var tiles := {} # absolute cell -> {bake, sun}
	var wanted : Array[Vector2i] = []
	var queued := {} # absolute cell -> true
	var atlas : RID
	var version := 0 # bumped whenever a tile lands

	func _init(p_name : String, p_tier : int, p_grid : int, cell_size : float, voxel_size : float, height : float,
			p_detail : float, p_light_steps : int, p_priority : float) -> void:
		name = p_name
		tier = p_tier
		grid_n = p_grid
		across = maxi(roundi(cell_size / voxel_size), 4)
		voxel = cell_size / across
		dims = Vector3i(across + 2, maxi(ceili(height / voxel), 4), across + 2)
		detail_scale = p_detail
		light_steps = p_light_steps
		priority_base = p_priority
		max_distance = 4000.0

	func ready_count() -> int:
		var count := 0
		for cell in wanted:
			if tiles.has(cell):
				count += 1
		return count

	func slot_of(cell : Vector2i) -> Vector2i:
		return Vector2i(posmod(cell.x, grid_n), posmod(cell.y, grid_n))


var _rules : Array = [] # per layer, resolved on the main thread
var _hand_made := {} # absolute cell -> specs (relative to the cell's corner)

var _thread : Thread
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _jobs : Array = []
var _results : Array = []
var _quit := false
# Background thread only: each cell's clouds and their primitives, per detail level.
var _cell_cache := {}
var _cell_cache_order : Array = []
const CELL_CACHE_SIZE := 600 # Cells' primitives (per detail level) kept by the bake thread. 100-1000: more re-bakes faster (relights, revisits, the rings' overlapping neighbours), at some memory.

var _render_mutex := Mutex.new()
var _render_state := {}
var _started := false
# Near cells the effect is drawing (absolute; set from the render thread): kept loaded and never
# overwritten until it lets them go, so a cloud is always drawn by exactly one of the near tiles
# and the distant panorama. Results for a slot still held wait in _deferred.
var _held := {}
var _deferred : Array = []


## For PaintedCloudsEffect (any thread): the near cells it's drawing, as absolute cells. They stay
## loaded (even once out of the window) until it stops holding them.
func set_held_cells(cells : Array) -> void:
	var held := {}
	for cell in cells:
		held[cell] = true
	_render_mutex.lock()
	_held = held
	_render_mutex.unlock()


func _is_held(cell : Vector2i) -> bool:
	_render_mutex.lock()
	var held := _held.has(cell)
	_render_mutex.unlock()
	return held


func _enter_tree() -> void:
	if Engine.is_editor_hint() and !run_in_editor:
		return
	_start()


func _exit_tree() -> void:
	_stop()


func _start() -> void:
	if _started:
		return
	_started = true
	active = self
	_rules.clear()
	for layer in layers:
		if layer:
			if layer.noise:
				layer.noise.seed = world_seed + layer.seed_offset
			_rules.append(layer.resolved_rules())
		else:
			_rules.append([])
	_read_hand_made()
	var height := ceiling_height - floor_height
	near = TileGrid.new("near", 0, grid, cell_size, voxel_size, height, 1.0, light_steps, 0.0)
	near.max_distance = max_distance
	far = TileGrid.new("far", 1, grid + 2 * far_rings, cell_size, far_voxel_size, height, far_detail, far_light_steps, 1000.0) if far_rings > 0 else null
	if far:
		far.max_distance = maxf(max_distance, far.voxel * 6.0)
	horizon = TileGrid.new("horizon", 2, far.grid_n + 2 * horizon_rings, cell_size, horizon_voxel_size, height, horizon_detail,
		horizon_light_steps, 2000.0) if far and horizon_rings > 0 else null
	if horizon:
		horizon.max_distance = maxf(max_distance, horizon.voxel * 6.0)
	_quit = false
	_thread = Thread.new()
	_thread.start(_thread_loop)
	print("PaintedCloudTileWorld: started, %d x %d tiles of %.0f km, %s, %d layers, %d hand-made cells" % [
		grid, grid, cell_size / 1000.0,
		("%d x %d far tiles at %.0f m" % [far.grid_n, far.grid_n, far.voxel] if far else "no far tiles")
			+ (", %d x %d horizon tiles at %.0f m" % [horizon.grid_n, horizon.grid_n, horizon.voxel] if horizon else ""),
		layers.size(), _hand_made.size()])


func _stop() -> void:
	if !_started:
		return
	_started = false
	_mutex.lock()
	_quit = true
	_jobs.clear()
	_mutex.unlock()
	_semaphore.post()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	var textures : Array[RID] = []
	for tile_set in [near, far, horizon]:
		if tile_set == null:
			continue
		for cell in tile_set.tiles:
			PaintedCloudWorld.unregister_bake(tile_set.tiles[cell].bake)
		tile_set.tiles.clear()
		tile_set.queued.clear()
		textures.append(tile_set.atlas)
		tile_set.atlas = RID()
	_render_mutex.lock()
	_render_state = {}
	_render_mutex.unlock()
	var free_textures := func() -> void:
		var rd := RenderingServer.get_rendering_device()
		if rd:
			for rid in textures:
				if rid.is_valid():
					rd.free_rid(rid)
	RenderingServer.call_on_render_thread(free_textures)
	if active == self:
		active = null


## Drops every tile and starts again (after changing cell size, grid, seed or layers at runtime).
func rebuild() -> void:
	_stop()
	_start()


## How many of the wanted near (and far) tiles are baked, and how many bakes are waiting or running.
func get_status() -> Dictionary:
	if near == null:
		return {"ready": 0, "wanted": 0, "jobs": 0, "far_ready": 0, "far_wanted": 0, "horizon_ready": 0, "horizon_wanted": 0,
			"offset_cells": offset_cells}
	_mutex.lock()
	var jobs := _jobs.size()
	_mutex.unlock()
	var far_queued := far.queued.size() if far else 0
	var horizon_queued := horizon.queued.size() if horizon else 0
	return {"ready": near.ready_count(), "wanted": near.wanted.size(), "jobs": jobs + near.queued.size() + far_queued + horizon_queued,
		"far_ready": far.ready_count() if far else 0, "far_wanted": far.wanted.size() if far else 0,
		"horizon_ready": horizon.ready_count() if horizon else 0, "horizon_wanted": horizon.wanted.size() if horizon else 0,
		"offset_cells": offset_cells}


## Moves the world back by offset (whole cells only: offset is rounded to cells on x and z, y is
## left alone): everything under shift_root moves, tiles re-anchor without re-baking. Returns the
## offset actually applied.
func shift_origin(offset : Vector3) -> Vector3:
	var cells := Vector2i(roundi(offset.x / cell_size), roundi(offset.z / cell_size))
	if cells == Vector2i.ZERO:
		return Vector3.ZERO
	var shift := Vector3(cells.x * cell_size, 0.0, cells.y * cell_size)
	offset_cells += cells
	if shift_root:
		for child in shift_root.get_children():
			if child is Node3D:
				child.global_position -= shift
	for tile_set in [near, far, horizon]:
		if tile_set:
			for cell in tile_set.tiles:
				tile_set.tiles[cell].bake.origin -= shift
	print("PaintedCloudTileWorld: floating origin shifted by %s (offset now %s cells)" % [-shift, offset_cells])
	origin_shifted.emit(-shift)
	return shift


## The absolute position (independent of floating origin shifts) of a local position.
func to_absolute(local_position : Vector3) -> Vector3:
	return local_position + _offset_vector()


func _process(_delta : float) -> void:
	if !_started:
		return
	var focus := _focus()
	if focus == null:
		return
	var p := focus.global_position
	if shift_threshold > 0.0 and (absf(p.x) > shift_threshold or absf(p.z) > shift_threshold):
		shift_origin(Vector3(p.x, 0.0, p.z))
		p = focus.global_position
	_drop_unwanted(near)
	_take_results()
	var first := _near_first(p)
	_update_wanted(near, first, p)
	if far:
		_update_wanted(far, first - Vector2i(far_rings, far_rings), p)
	if horizon:
		_update_wanted(horizon, first - Vector2i(far_rings + horizon_rings, far_rings + horizon_rings), p)
	_update_relight(near)
	if far:
		_update_relight(far)
	if horizon:
		_update_relight(horizon)
	_publish_render_state()


func _focus() -> Node3D:
	if target and is_instance_valid(target):
		return target
	if Engine.is_editor_hint():
		var editor := Engine.get_singleton("EditorInterface")
		if editor:
			var viewport : SubViewport = editor.get_editor_viewport_3d(0)
			return viewport.get_camera_3d() if viewport else null
		return null
	return get_viewport().get_camera_3d() if is_inside_tree() else null


# The near window's first (lowest) absolute cell round local position p.
func _near_first(p : Vector3) -> Vector2i:
	var local := Vector2(p.x, p.z) / cell_size
	if grid == Grid.THREE_BY_THREE:
		return Vector2i(local.floor()) - Vector2i.ONE + offset_cells
	return Vector2i((local - Vector2(0.5, 0.5)).floor()) + offset_cells


# A set's cells from first (grid_n square), nearest p first; queues the missing ones and drops
# the rest.
func _update_wanted(tile_set : TileGrid, first : Vector2i, p : Vector3) -> void:
	var wanted : Array[Vector2i] = []
	for x in tile_set.grid_n:
		for z in tile_set.grid_n:
			wanted.append(first + Vector2i(x, z))
	var centre := Vector2(p.x, p.z) / cell_size + Vector2(offset_cells)
	var nearer := func(a : Vector2i, b : Vector2i) -> bool:
		return (Vector2(a) + Vector2(0.5, 0.5)).distance_squared_to(centre) < (Vector2(b) + Vector2(0.5, 0.5)).distance_squared_to(centre)
	wanted.sort_custom(nearer)
	if wanted != tile_set.wanted:
		tile_set.wanted = wanted
		var set_name := tile_set.name
		_drop_unwanted(tile_set)
		_mutex.lock()
		_jobs = _jobs.filter(func(job : Dictionary) -> bool: return job.kind != "tile" or job.set != set_name or wanted.has(job.cell))
		_mutex.unlock()
		for cell in tile_set.queued.keys():
			if !wanted.has(cell):
				tile_set.queued.erase(cell)
	for i in wanted.size():
		var cell := wanted[i]
		if !tile_set.tiles.has(cell) and !tile_set.queued.has(cell):
			_queue_tile(tile_set, cell, tile_set.priority_base + i, false)


# Drops the tiles no longer wanted (near ones only once the effect has let go of them).
func _drop_unwanted(tile_set : TileGrid) -> void:
	for cell in tile_set.tiles.keys():
		if !tile_set.wanted.has(cell) and !(tile_set == near and _is_held(cell)):
			PaintedCloudWorld.unregister_bake(tile_set.tiles[cell].bake)
			tile_set.tiles.erase(cell)


func _queue_tile(tile_set : TileGrid, cell : Vector2i, priority : float, relight : bool) -> void:
	tile_set.queued[cell] = true
	var sun_dir := _sun_direction()
	var settings := _settings(sun_dir)
	settings.light_steps = tile_set.light_steps
	settings.max_distance = tile_set.max_distance
	_push_job({"kind": "tile", "set": tile_set.name, "cell": cell, "priority": priority, "sun": sun_dir, "settings": settings,
		"relight": relight, "across": tile_set.across, "voxel": tile_set.voxel, "dims": tile_set.dims,
		"detail_scale": tile_set.detail_scale})


func _update_relight(tile_set : TileGrid) -> void:
	if relight_angle <= 0.0 or sun == null:
		return
	var current := _sun_direction()
	var limit := deg_to_rad(relight_angle)
	for cell in tile_set.tiles:
		if !tile_set.queued.has(cell) and tile_set.tiles[cell].sun.angle_to(current) > limit:
			_queue_tile(tile_set, cell, tile_set.priority_base + 100.0 + tile_set.wanted.find(cell), true)


func _push_job(job : Dictionary) -> void:
	_mutex.lock()
	_jobs.append(job)
	_jobs.sort_custom(_job_before)
	_mutex.unlock()
	_semaphore.post()


static func _job_before(a : Dictionary, b : Dictionary) -> bool:
	return a.priority < b.priority


func _take_results() -> void:
	_mutex.lock()
	var results := _deferred + _results
	_results = []
	_deferred = []
	_mutex.unlock()
	for result in results:
		if result.kind == "tile":
			var tile_set : TileGrid = near if result.set == "near" else (far if result.set == "far" else horizon)
			if tile_set == null:
				continue
			if !tile_set.wanted.has(result.cell) or result.voxels.is_empty():
				tile_set.queued.erase(result.cell)
				continue
			if tile_set == near and _slot_taken(result.cell):
				# Its slot still holds a tile the effect is drawing: wait until it lets go.
				_deferred.append(result)
				continue
			tile_set.queued.erase(result.cell)
			var bake : PaintedCloudBake = tile_set.tiles[result.cell].bake if tile_set.tiles.has(result.cell) else PaintedCloudBake.new()
			bake.set_voxels(result.voxels, result.dims)
			bake.origin = result.origin - _offset_vector()
			bake.size = Vector3(result.dims) * result.voxel
			bake.voxel_size = result.voxel
			bake.sun_direction = result.sun
			bake.softness = softness
			bake.max_distance = tile_set.max_distance
			bake.cloud_count = result.clouds
			bake.primitive_count = result.primitives
			bake.tier = tile_set.tier
			bake.answer_margin = result.voxel # The shared border: each tile answers for its own cell.
			tile_set.tiles[result.cell] = {"bake": bake, "sun": result.sun}
			tile_set.version += 1
			PaintedCloudWorld.register_bake(bake)
			_upload_tile(tile_set, result.cell, result.voxels)
			var verb := "relit" if result.relight else "ready"
			if tile_set == near:
				print("PaintedCloudTileWorld: tile %s %s in %d ms (%d clouds, %d primitives)  [%d / %d ready]" % [
					result.cell, verb, result.ms, result.clouds, result.primitives, near.ready_count(), near.wanted.size()])
				tile_ready.emit(result.cell)
			else:
				var count := tile_set.ready_count()
				if count == tile_set.wanted.size() or count % 16 == 0:
					print("PaintedCloudTileWorld: %s tile %s %s in %d ms  [%d / %d %s tiles ready]" % [
						tile_set.name, result.cell, verb, result.ms, count, tile_set.wanted.size(), tile_set.name])
				far_tile_ready.emit(result.cell)


# Whether a near cell's atlas slot holds another tile that's still loaded.
func _slot_taken(cell : Vector2i) -> bool:
	var slot := near.slot_of(cell)
	for other in near.tiles:
		if other != cell and near.slot_of(other) == slot:
			return true
	return false


func _offset_vector() -> Vector3:
	return Vector3(offset_cells.x * cell_size, 0.0, offset_cells.y * cell_size)


func _sun_direction() -> Vector3:
	return sun.global_transform.basis.z.normalized() if sun and sun.is_inside_tree() else Vector3(0.4, 0.6, 0.3).normalized()


func _settings(sun_dir : Vector3) -> Dictionary:
	return {"blend": blend, "max_distance": max_distance, "sun_direction": sun_dir, "light_distance": light_distance,
		"light_steps": light_steps, "sky_distance": sky_distance, "softness": softness, "extinction": extinction}


# ---- GPU side (render thread) ----

func _upload_tile(tile_set : TileGrid, cell : Vector2i, voxels : PackedByteArray) -> void:
	var slot := tile_set.slot_of(cell)
	var dims := tile_set.dims
	var n := tile_set.grid_n
	var upload := func() -> void:
		var rd := RenderingServer.get_rendering_device()
		if rd == null:
			return
		if !tile_set.atlas.is_valid():
			tile_set.atlas = rd.texture_create(_format(Vector3i(dims.x * n, dims.y, dims.z * n),
				RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT), RDTextureView.new())
		var temp := rd.texture_create(_format(dims, RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT), RDTextureView.new(), [voxels])
		rd.texture_copy(temp, tile_set.atlas, Vector3.ZERO, Vector3(slot.x * dims.x, 0, slot.y * dims.z), Vector3(dims), 0, 0, 0, 0)
		rd.free_rid(temp)
	RenderingServer.call_on_render_thread(upload)


static func _format(dims : Vector3i, extra_usage : int) -> RDTextureFormat:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = dims.x
	format.height = dims.y
	format.depth = dims.z
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | extra_usage
	return format


# A set's slot table: per slot (x + z * grid_n), the local cell in it and whether it's baked.
func _slots(tile_set : TileGrid) -> PackedInt32Array:
	var slots := PackedInt32Array()
	slots.resize(tile_set.grid_n * tile_set.grid_n * 4)
	slots.fill(0)
	for cell in tile_set.tiles:
		var slot := tile_set.slot_of(cell)
		var i : int = (slot.x + slot.y * tile_set.grid_n) * 4
		var local : Vector2i = cell - offset_cells
		slots[i] = local.x
		slots[i + 1] = local.y
		slots[i + 2] = 1
	return slots


func _window_min(tile_set : TileGrid) -> Vector3:
	var lo := Vector2i(1 << 30, 1 << 30)
	for cell in tile_set.wanted:
		lo = lo.min(cell)
	var local := lo - offset_cells
	return Vector3(local.x * cell_size, floor_height, local.y * cell_size)


# What the effect needs to draw the tiles, as of this frame (built on the main thread).
func _publish_render_state() -> void:
	var near_slots := _slots(near)
	var slots := []
	for i in near.grid_n * near.grid_n:
		slots.append(Vector3i(near_slots[i * 4], near_slots[i * 4 + 1], near_slots[i * 4 + 2]))
	var window_min := _window_min(near)
	var state := {
		"cell_size": cell_size, "voxel": near.voxel, "floor": floor_height, "grid": grid, "tile_dims": near.dims,
		"atlas_dims": Vector3i(near.dims.x * grid, near.dims.y, near.dims.z * grid), "slots": slots,
		"window_min": window_min, "window_size": Vector3(grid * cell_size, ceiling_height - floor_height, grid * cell_size),
		"sun": _sun_direction(), "voxel_size": near.voxel,
		"slot_shift": near.slot_of(offset_cells),
		"offset": _offset_vector(),
		"offset_cells": offset_cells,
		# The wanted near cells that are baked (absolute): what the effect can draw next.
		"ready_cells": near.wanted.filter(func(c : Vector2i) -> bool: return near.tiles.has(c)),
	}
	if far and far.ready_count() > 0:
		state.far = _ring_state(far)
		# What the panorama depends on: re-painted when this changes (once the rings are complete:
		# not for every tile as they stream in or re-light).
		state.far.key = [far.version, horizon.version if horizon else 0, near.wanted[0] if !near.wanted.is_empty() else Vector2i.ZERO, far.wanted.size()]
		state.far.complete = far.ready_count() == far.wanted.size() and far.queued.is_empty() \
			and (horizon == null or (horizon.ready_count() == horizon.wanted.size() and horizon.queued.is_empty()))
		if horizon and horizon.ready_count() > 0:
			state.horizon = _ring_state(horizon)
	_render_mutex.lock()
	_render_state = state
	_render_mutex.unlock()


func _ring_state(tile_set : TileGrid) -> Dictionary:
	return {
		"grid": tile_set.grid_n, "voxel": tile_set.voxel, "tile_dims": tile_set.dims,
		"atlas_dims": Vector3i(tile_set.dims.x * tile_set.grid_n, tile_set.dims.y, tile_set.dims.z * tile_set.grid_n),
		"slots": _slots(tile_set), "slot_shift": tile_set.slot_of(offset_cells),
		"window_min": _window_min(tile_set),
		"window_size": Vector3(tile_set.grid_n * cell_size, ceiling_height - floor_height, tile_set.grid_n * cell_size),
	}


## For PaintedCloudsEffect (render thread): this frame's state plus the GPU textures, or empty.
func get_render_state() -> Dictionary:
	_render_mutex.lock()
	var state := _render_state
	_render_mutex.unlock()
	if state.is_empty() or near == null or !near.atlas.is_valid():
		return {}
	state = state.duplicate()
	state.atlas = near.atlas
	for ring in [["far", far], ["horizon", horizon]]:
		if state.has(ring[0]):
			var tile_set : TileGrid = ring[1]
			if tile_set and tile_set.atlas.is_valid():
				var ring_state : Dictionary = state[ring[0]].duplicate()
				ring_state.atlas = tile_set.atlas
				state[ring[0]] = ring_state
			else:
				state.erase(ring[0])
	return state


# ---- Generation and baking (background thread) ----

func _read_hand_made() -> void:
	_hand_made.clear()
	for cell in hand_made_cells:
		var scene : PackedScene = hand_made_cells[cell]
		if scene == null:
			continue
		var root := scene.instantiate()
		var specs : Array = []
		_collect_points(root, Transform3D.IDENTITY, specs)
		root.free()
		_hand_made[cell] = specs


func _collect_points(node : Node, parent : Transform3D, specs : Array) -> void:
	var xform := parent
	if node is Node3D:
		xform = parent * (node as Node3D).transform
	if node is PaintedCloudPoint and node.visible:
		specs.append({"recipe": node.get_recipe(), "base": xform.origin, "radius": node.radius, "height": node.height,
			"detail": node.detail, "seed": node.lobe_seed})
	for child in node.get_children():
		_collect_points(child, xform, specs)


func _cell_specs(cell : Vector2i) -> Array:
	if _hand_made.has(cell):
		var corner := Vector3(cell.x * cell_size, 0.0, cell.y * cell_size)
		var specs : Array = []
		for spec in _hand_made[cell]:
			var placed : Dictionary = spec.duplicate()
			placed.base = corner + spec.base
			specs.append(placed)
		return specs
	var specs : Array = []
	for i in layers.size():
		if layers[i]:
			specs.append_array(layers[i].generate_cell(cell, cell_size, world_seed, _rules[i]))
	return specs


# A cell's clouds as [spec, primitives] pairs at a detail level (background thread), cached.
func _cell_clouds(cell : Vector2i, detail_scale : float) -> Array:
	var key := [cell, detail_scale]
	if _cell_cache.has(key):
		return _cell_cache[key]
	var clouds : Array = []
	for spec in _cell_specs(cell):
		clouds.append([spec, PaintedCloudPoint.build_primitives_for(spec.recipe, spec.base, spec.radius, spec.height,
			spec.detail * detail_scale, spec.seed)])
	_cell_cache[key] = clouds
	_cell_cache_order.append(key)
	if _cell_cache_order.size() > CELL_CACHE_SIZE:
		_cell_cache.erase(_cell_cache_order.pop_front())
	return clouds


func _thread_loop() -> void:
	var baker := PaintedCloudBaker.new()
	if !baker.is_valid():
		push_error("PaintedCloudTileWorld: can't bake (needs the Forward+ or Mobile renderer).")
	while true:
		_semaphore.wait()
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			break
		var job : Dictionary = _jobs.pop_front() if !_jobs.is_empty() else {}
		_mutex.unlock()
		if job.is_empty() or !baker.is_valid():
			continue
		var started := Time.get_ticks_msec()
		var result : Dictionary
		result = _bake_tile(baker, job)
		result.ms = Time.get_ticks_msec() - started
		_mutex.lock()
		_results.append(result)
		_mutex.unlock()
	baker.free_resources()


func _bake_tile(baker : PaintedCloudBaker, job : Dictionary) -> Dictionary:
	var cell : Vector2i = job.cell
	var voxel : float = job.voxel
	var dims : Vector3i = job.dims
	var corner := Vector3(cell.x * cell_size, 0.0, cell.y * cell_size)
	# Clouds from this cell and its neighbours that can reach the tile or its shadow margin (so
	# those reaching over the border are whole, and cast their shadows in).
	var margin_m := light_distance + blend
	var near_lo := Vector2(corner.x, corner.z) - Vector2(margin_m, margin_m)
	var near_hi := Vector2(corner.x, corner.z) + Vector2(cell_size, cell_size) + Vector2(margin_m, margin_m)
	var cloud_prims : Array = []
	var prim_count := 0
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for pair in _cell_clouds(cell + Vector2i(dx, dz), job.detail_scale):
				var spec : Dictionary = pair[0]
				var flat := Vector2(spec.base.x, spec.base.z)
				if flat.distance_to(flat.clamp(near_lo, near_hi)) > spec.radius * 3.0 + spec.height:
					continue
				prim_count += pair[1].size()
				cloud_prims.append(pair[1])
	# Bake in the tile's own space (its corner at the origin) for precision far from the origin.
	var packed := PaintedCloudBaker.pack(cloud_prims, corner)
	var origin := Vector3(-voxel, floor_height, -voxel)
	var margin_cells := mini(ceili(light_distance / voxel), dims.x)
	var bytes := baker.bake(packed, origin, dims, voxel, job.settings, Vector3i(margin_cells, 0, margin_cells))
	return {"kind": "tile", "set": job.set, "cell": cell, "voxels": bytes, "dims": dims, "voxel": voxel, "origin": corner + origin,
		"sun": job.sun, "clouds": cloud_prims.size(), "primitives": prim_count, "relight": job.relight}
