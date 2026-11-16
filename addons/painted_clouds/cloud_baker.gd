extends RefCounted
class_name PaintedCloudBaker
## Bakes clouds (lists of PaintedCloudPoint primitives) into voxels on the GPU, through its own local
## RenderingDevice, so it can run on any thread: PaintedCloudVolume bakes on the main thread,
## PaintedCloudTileWorld on its background thread. Make it, and use it, on the same thread.
##
## settings keys: blend, max_distance, sun_direction, light_distance, light_steps, sky_distance,
## softness, extinction.

const CHUNK_SIZE := 24 # Most primitives per culling chunk of a big cloud. 8-64: smaller culls tighter, but more chunks to test per voxel.
const SLAB := 8 # Voxel slices per dispatch: each one is submitted and waited for, for progress and to avoid GPU timeouts. 4-32.

var rd : RenderingDevice
var _sdf_shader : RID
var _light_shader : RID
var _sdf_pipeline : RID
var _light_pipeline : RID
var _sampler : RID


func _init() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		return
	_sdf_shader = _load_shader("res://addons/painted_clouds/shaders/bake_sdf.glsl")
	_light_shader = _load_shader("res://addons/painted_clouds/shaders/bake_light.glsl")
	if _sdf_shader.is_valid():
		_sdf_pipeline = rd.compute_pipeline_create(_sdf_shader)
	if _light_shader.is_valid():
		_light_pipeline = rd.compute_pipeline_create(_light_shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)


func is_valid() -> bool:
	return rd != null and _sdf_pipeline.is_valid() and _light_pipeline.is_valid()


## Frees the GPU resources (call before dropping it, on its thread).
func free_resources() -> void:
	if rd == null:
		return
	for rid in [_sdf_pipeline, _light_pipeline, _sampler, _sdf_shader, _light_shader]:
		if rid.is_valid():
			rd.free_rid(rid)
	rd.free()
	rd = null


## Packs clouds' primitives (an Array of PaintedCloudPoint.build_primitives() results) for bake(),
## positions made relative to offset. Big clouds are split into chunks of nearby primitives, each
## with its own bounding sphere, so the bake skips most of them for most voxels.
static func pack(clouds : Array, offset : Vector3 = Vector3.ZERO) -> Dictionary:
	var prim_data := PackedFloat32Array()
	var chunk_data := PackedFloat32Array()
	var prim_count := 0
	for prims in clouds:
		if prims.is_empty():
			continue
		for chunk in _chunk(prims):
			var centre := Vector3.ZERO
			for p in chunk:
				centre += (p[0] + p[1]) * 0.5
			centre /= chunk.size()
			var bound := 0.0
			for p in chunk:
				bound = maxf(bound, maxf(centre.distance_to(p[0]), centre.distance_to(p[1])) + p[2])
			centre -= offset
			chunk_data.append_array([centre.x, centre.y, centre.z, bound, float(prim_count), float(chunk.size()), 0.0, 0.0])
			for p in chunk:
				var a : Vector3 = p[0] - offset
				var b : Vector3 = p[1] - offset
				var floor_y : float = p[4] - offset.y if p[4] > PaintedCloudPoint.NO_FLOOR * 0.5 else PaintedCloudPoint.NO_FLOOR
				prim_data.append_array([a.x, a.y, a.z, p[2], b.x, b.y, b.z, p[3], floor_y, p[5], 0.0, 0.0])
				prim_count += 1
	if prim_count == 0:
		# Keep the buffers valid: one primitive far away.
		prim_data.append_array([0.0, -1e7, 0.0, 1.0, 0.0, -1e7, 0.0, 1.0, PaintedCloudPoint.NO_FLOOR, 1.0, 0.0, 0.0])
		chunk_data.append_array([0.0, -1e7, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0])
	return {"primitives": prim_data, "chunks": chunk_data, "primitive_count": prim_count, "chunk_count": chunk_data.size() / 8}


## Bakes packed clouds into dims voxels of voxel_size from origin (in the packed clouds' space):
## returns the voxels (RGBA half floats, 8 bytes each, x fastest), or an empty array on failure.
## margin: extra voxels round the box the distance field covers (so clouds just outside it still
## shadow it). report, if valid, is called as report(stage : String, fraction : float).
func bake(packed : Dictionary, origin : Vector3, dims : Vector3i, voxel_size : float, settings : Dictionary,
		margin : Vector3i = Vector3i.ZERO, report : Callable = Callable()) -> PackedByteArray:
	if !is_valid():
		return PackedByteArray()
	var sdf_dims := dims + margin * 2
	var sdf_origin := origin - Vector3(margin) * voxel_size
	var sdf_tex := rd.texture_create(_format(sdf_dims), RDTextureView.new())
	var out_tex := rd.texture_create(_format(dims), RDTextureView.new())
	var prim_bytes : PackedByteArray = packed.primitives.to_byte_array()
	var chunk_bytes : PackedByteArray = packed.chunks.to_byte_array()
	var prim_buffer := rd.storage_buffer_create(prim_bytes.size(), prim_bytes)
	var chunk_buffer := rd.storage_buffer_create(chunk_bytes.size(), chunk_bytes)
	var sdf_set := rd.uniform_set_create([
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [sdf_tex]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, [prim_buffer]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, [chunk_buffer]),
	], _sdf_shader, 0)
	var light_set := rd.uniform_set_create([
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, sdf_tex]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [out_tex]),
	], _light_shader, 0)

	var blend : float = maxf(settings.get("blend", 220.0), 0.001)
	var max_distance : float = settings.get("max_distance", 4000.0)
	var sun : Vector3 = settings.get("sun_direction", Vector3(0.4, 0.6, 0.3)).normalized()
	var chunk_count : int = packed.chunk_count
	var sdf_push := func(z0 : int) -> PackedByteArray:
		var pc := PackedByteArray()
		pc.resize(48)
		_put(pc, 0, sdf_origin, voxel_size)
		_put_dims(pc, 16, sdf_dims, z0)
		_put(pc, 32, Vector3(blend, float(chunk_count), max_distance), 0.0)
		return pc
	_run(sdf_dims, _sdf_pipeline, sdf_set, sdf_push, report, "distance field")
	var light_extra := Vector3(settings.get("softness", 300.0), settings.get("extinction", 0.0012), float(settings.get("light_steps", 24)))
	var light_distance : float = settings.get("light_distance", 5000.0)
	var sky_distance : float = settings.get("sky_distance", 3000.0)
	var light_push := func(z0 : int) -> PackedByteArray:
		var pc := PackedByteArray()
		pc.resize(96)
		_put(pc, 0, origin, voxel_size)
		_put_dims(pc, 16, dims, z0)
		_put(pc, 32, sun, light_distance)
		_put(pc, 48, light_extra, sky_distance)
		_put(pc, 64, sdf_origin, 0.0)
		_put_dims(pc, 80, sdf_dims, 0)
		return pc
	_run(dims, _light_pipeline, light_set, light_push, report, "sun and sky light")
	var bytes := rd.texture_get_data(out_tex, 0)
	for rid in [sdf_set, light_set, sdf_tex, out_tex, prim_buffer, chunk_buffer]:
		rd.free_rid(rid)
	return bytes


func _run(dims : Vector3i, pipeline : RID, uniform_set : RID, push : Callable, report : Callable, stage : String) -> void:
	var slabs := ceili(dims.z / float(SLAB))
	for s in slabs:
		var z0 := s * SLAB
		var pc : PackedByteArray = push.call(z0)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, pc, pc.size())
		rd.compute_list_dispatch(list, ceili(dims.x / 4.0), ceili(dims.y / 4.0), ceili(mini(SLAB, dims.z - z0) / 4.0))
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		if report.is_valid():
			report.call(stage, float(s + 1) / slabs)


func _format(dims : Vector3i) -> RDTextureFormat:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = dims.x
	format.height = dims.y
	format.depth = dims.z
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return format


func _load_shader(path : String) -> RID:
	var file : RDShaderFile = load(path)
	if file == null:
		return RID()
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("%s: %s" % [path, spirv.compile_error_compute])
		return RID()
	return rd.shader_create_from_spirv(spirv)


static func _chunk(prims : Array) -> Array:
	if prims.size() <= CHUNK_SIZE:
		return [prims]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in prims:
		var c : Vector3 = p[0]
		lo = lo.min(Vector2(c.x, c.z))
		hi = hi.max(Vector2(c.x, c.z))
	var cells := ceili(sqrt(prims.size() / float(CHUNK_SIZE)))
	var cell := maxf((hi - lo).x, (hi - lo).y) / cells + 1.0
	var buckets := {}
	for p in prims:
		var c : Vector3 = p[0]
		var key := Vector2i(floori((c.x - lo.x) / cell), floori((c.z - lo.y) / cell))
		if !buckets.has(key):
			buckets[key] = []
		buckets[key].append(p)
	return buckets.values()


static func _uniform(type : RenderingDevice.UniformType, binding : int, ids : Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u


static func _put(bytes : PackedByteArray, offset : int, v : Vector3, w : float) -> void:
	bytes.encode_float(offset, v.x)
	bytes.encode_float(offset + 4, v.y)
	bytes.encode_float(offset + 8, v.z)
	bytes.encode_float(offset + 12, w)


static func _put_dims(bytes : PackedByteArray, offset : int, dims : Vector3i, w : int) -> void:
	bytes.encode_s32(offset, dims.x)
	bytes.encode_s32(offset + 4, dims.y)
	bytes.encode_s32(offset + 8, dims.z)
	bytes.encode_s32(offset + 12, w)
