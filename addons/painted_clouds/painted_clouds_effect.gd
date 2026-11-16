@tool
extends CompositorEffect
class_name PaintedCloudsEffect
## Draws the clouds over the scene, painterly. Add it to a Compositor on the WorldEnvironment or
## Camera3D. It draws its own bake if it has one, else the active PaintedCloudTileWorld's tiles, else the
## active bake (the last a PaintedCloudVolume baked or loaded). Works best with the Linear tonemapper: the colour
## gradient is the look, and filmic tonemappers wash it out.

## Optional: the bake to draw. Empty draws the active one.
@export var bake : PaintedCloudBake

@export_group("Look")
## The clouds' colours from shadow (left) to full sun (right).
@export var gradient : GradientTexture1D
## The sun's colour on the clouds (times the gradient).
@export var sun_color : Color = Color(1.0, 0.98, 0.94)
@export_range(0.0, 16.0, 0.01) var sun_energy : float = 1.0
## How far the lit side wraps round towards the shadow side: 0 = hard terminator.
@export_range(0.0, 2.0, 0.01) var wrap : float = 0.4
## How much the baked sun shadow (clouds shading each other) darkens: 0 = none.
@export_range(0.0, 1.0, 0.01) var sun_shadow : float = 0.6
## How much the baked sky shadow (cloud above) darkens: bluer undersides.
@export_range(0.0, 1.0, 0.01) var sky_shadow : float = 0.3
## Pulls the shading into soft bands: 0 = smooth, 1 = strongest.
@export_range(0.0, 1.0, 0.01) var banding : float = 0.8
## Silver lining on edges seen against the sun.
@export_range(0.0, 8.0, 0.01) var rim_strength : float = 1.2
@export_range(0.5, 16.0, 0.1) var rim_power : float = 4.0

@export_group("Shape")
## Width of the soft edge (m).
@export_range(1.0, 2000.0, 1.0, "suffix:m") var softness : float = 120.0
## How opaque the clouds are, per metre at full density.
@export_range(0.0, 0.2, 0.0001) var extinction : float = 0.02
## Billowy noise on the surface: 0..1 with this texture, pushed out by up to this (m).
@export var noise : NoiseTexture3D
@export_range(0.0, 2000.0, 1.0, "suffix:m") var noise_strength : float = 260.0
## A finer octave of the same noise, for small puffs up close: its strength as a fraction of
## noise_strength.
@export_range(0.0, 1.0, 0.01) var detail_strength : float = 0.45
## The noise texture's size in the world (m).
@export_range(10.0, 50000.0, 10.0, "suffix:m") var noise_scale : float = 2400.0

@export_group("March")
## Step length near and inside clouds (m), before growing with distance.
@export_range(5.0, 1000.0, 1.0, "suffix:m") var inside_step : float = 60.0
## How much the step grows per km of distance (0.1 = 10% longer per km).
@export_range(0.0, 1.0, 0.001) var step_growth_per_km : float = 0.08
## Smallest jump in clear air (m).
@export_range(1.0, 1000.0, 1.0, "suffix:m") var min_skip : float = 40.0
@export_range(16, 1024) var max_steps : int = 256
## Clouds thin out over this distance (m) from the box's sides.
@export_range(0.0, 20000.0, 10.0, "suffix:m") var edge_fade : float = 4000.0

@export_group("Haze")
@export var fade_color : Color = Color(0.62, 0.74, 0.92)
@export_range(0.0, 200000.0, 100.0, "suffix:m") var fade_start : float = 8000.0
@export_range(0.0, 200000.0, 100.0, "suffix:m") var fade_end : float = 40000.0
## How far into the haze colour the clouds go at fade_end.
@export_range(0.0, 1.0, 0.01) var fade_amount : float = 0.7

@export_group("Distant clouds")
## With a PaintedCloudTileWorld that has far tiles: paint them into a distant panorama, so the clouds
## reach the horizon beyond the loaded tiles.
@export var distant_clouds : bool = true
## The panorama's width (pixels round 360 degrees); it covers from straight down to 45 degrees
## above the horizon, so its height is 3/8 of this. Two are kept (old and new), at 12 bytes a pixel
## with their depth: 2048 is about 19 MB.
@export_range(512, 8192, 64) var panorama_width : int = 2048
## Rows painted per frame when the panorama is re-painted (on entering a new cell, or after the
## far tiles change): fewer spreads the work over more frames.
@export_range(8, 2048, 8) var panorama_rows_per_frame : int = 64
## Re-projects the distant clouds for where the camera is now (each panorama stores how far away
## its clouds are), so they keep their parallax as you move instead of sliding with you.
@export var panorama_parallax : bool = true
## Re-paint the panorama by itself as the camera moves (the distances below). Off, it only
## re-paints on entering a new cell, after the far tiles change, or on repaint_requested.
@export var panorama_auto_repaint : bool = true
## Re-paint once the camera has climbed or dropped this far (m) from where the panorama was
## painted (also on entering a new cell, and after the far tiles change).
@export_range(100.0, 20000.0, 50.0, "suffix:m") var panorama_repaint_height : float = 1000.0
## Re-paint once the camera has moved this far (m) sideways from where it was painted.
@export_range(500.0, 50000.0, 100.0, "suffix:m") var panorama_repaint_distance : float = 4000.0
## Every cloud is drawn once: inside the near cells (the loaded tiles the effect is drawing) by the
## near tiles, outside them by the panorama, which leaves those cells out. Over this band (m) just
## inside the near cells' outer edge, fixed in the world, the near clouds fade out exactly as the
## panorama's fade in, so a cloud straddling the edge is one cloud. When the near cells change (a new
## cell's tiles land, or old ones go), the panorama is re-painted for the new set first, and the
## near tiles switch over as it fades in.
@export_range(500.0, 10000.0, 100.0, "suffix:m") var handover_band : float = 4000.0
## The distant clouds get the same billow noise as the near ones, fading out to this distance (m).
@export_range(0.0, 200000.0, 1000.0, "suffix:m") var distant_noise_distance : float = 45000.0
## How long the new panorama takes to fade in over the old one (s).
@export_range(0.0, 10.0, 0.05, "suffix:s") var panorama_fade_seconds : float = 1.5
## Step length inside the distant clouds (m), before growing with distance.
@export_range(50.0, 5000.0, 10.0, "suffix:m") var far_inside_step : float = 300.0
@export_range(16, 2048) var far_max_steps : int = 384
## The distant clouds thin out over this distance (m) from the outermost tiles' edge, so they fade
## into the haze rather than stop; it's also the band where the far tiles hand over to the
## horizon tiles.
@export_range(0.0, 50000.0, 100.0, "suffix:m") var far_edge_fade : float = 12000.0

@export_group("Hidden swaps")
## Hold each newly painted panorama (and the hand-over of near cells that comes with it) until
## hardly any distant clouds are on screen, e.g. while the camera flies through a cloud or a near
## cloud fills the view, and swap it in then, quickly, where nobody can see. Off: it fades in as
## soon as it's painted.
@export var swap_when_hidden : bool = true
## Hidden: at most this share of the screen shows distant clouds (0.03 = 3%).
@export_range(0.0, 0.5, 0.005) var hidden_coverage : float = 0.03
## Clouds further than this (m, horizontally from the camera) count as distant.
@export_range(1000.0, 40000.0, 500.0, "suffix:m") var hidden_distance : float = 10000.0
## How quickly it swaps in once hidden (s).
@export_range(0.0, 5.0, 0.05, "suffix:s") var hidden_fade_seconds : float = 0.3
## The longest it waits for a hidden moment (s); then the wisp comes (or, without it, it fades in
## as usual). Keep it short enough that the camera can't fly far from where it was painted.
@export_range(0.5, 60.0, 0.5, "suffix:s") var swap_max_wait : float = 6.0
## Fallback: a wisp (a small cluster of puffs, a new random shape each time) fades in, still, on
## the camera's path ahead, for the player to fly through; the swap happens while they're in it.
## If they swerve past or turn away, the swap is forced (fading as usual). Gameplay can check
## get_wisp_density() (a boost for flying through, say), or connect wisp_appeared / wisp_entered /
## wisp_gone.
@export var fallback_wisp : bool = true
## The wisp's size (m): the radius its puffs gather in.
@export_range(100.0, 5000.0, 10.0, "suffix:m") var wisp_radius : float = 900.0
## Its height as a share of its width.
@export_range(0.2, 2.0, 0.01) var wisp_flatten : float = 0.6
## How many puffs make it (1 = one round puff).
@export_range(1, 8) var wisp_puffs : int = 6
## Each puff's size as a share of wisp_radius (varied a little per puff).
@export_range(0.15, 1.0, 0.01) var wisp_puff_size : float = 0.45
## Where it appears: where the camera will be in this many seconds at its current speed...
@export_range(0.5, 20.0, 0.1, "suffix:s") var wisp_ahead_seconds : float = 5.0
## ...but at least this far ahead (m; also where it goes when the camera is hovering)...
@export_range(200.0, 20000.0, 100.0, "suffix:m") var wisp_min_distance : float = 2000.0
## ...and at most this far.
@export_range(500.0, 40000.0, 100.0, "suffix:m") var wisp_max_distance : float = 9000.0
## How long it takes to fade in, and to fade away once passed (s).
@export_range(0.1, 10.0, 0.05, "suffix:s") var wisp_fade_in : float = 2.5
@export_range(0.1, 10.0, 0.05, "suffix:s") var wisp_fade_out : float = 2.0
## How thick it is (1 = like the other clouds).
@export_range(0.0, 4.0, 0.01) var wisp_density : float = 1.0
## If the camera hasn't reached it after this long (s), the swap is forced and it fades away.
@export_range(2.0, 120.0, 0.5, "suffix:s") var wisp_timeout : float = 20.0

## A wisp appeared at this (local) position, size radius.
signal wisp_appeared(position : Vector3, radius : float)
## The camera flew into the wisp.
signal wisp_entered
## The wisp faded away; flown_through is whether the camera went into it.
signal wisp_gone(flown_through : bool)

@export_group("Paint filters")
## Kuwahara: flattens the clouds into soft painted patches. Anisotropic follows the shapes, like
## brush strokes; classic is blockier.
@export var kuwahara : KuwaharaMode = KuwaharaMode.OFF
@export_range(0.0, 1.0, 0.01) var kuwahara_strength : float = 1.0
## Brush size (pixels at 1080p; scaled with the resolution).
@export_range(1.0, 12.0, 0.1) var kuwahara_radius : float = 5.0
## Anisotropic only: how strongly each stroke picks its calmest side (higher = crisper strokes).
@export_range(1.0, 18.0, 0.1) var kuwahara_sharpness : float = 8.0
## Anisotropic only: how much strokes stretch along the shapes (lower = more stretched).
@export_range(0.1, 4.0, 0.01) var kuwahara_anisotropy : float = 1.0
## Watercolour: pigment pools just inside the clouds' edges, a little deeper and richer.
@export_range(0.0, 1.0, 0.01) var watercolor_strength : float = 0.0
@export_range(0.5, 8.0, 0.1) var watercolor_width : float = 2.5
## Canvas grain: a fixed paper and weave texture over the clouds.
@export_range(0.0, 1.0, 0.01) var grain_strength : float = 0.0
@export_range(0.5, 6.0, 0.1) var grain_scale : float = 1.5
## Soft ink outlines on the clouds' silhouettes (and, fainter, where their shading turns sharply).
@export_range(0.0, 1.0, 0.01) var ink_strength : float = 0.0
@export_range(0.5, 6.0, 0.1) var ink_width : float = 1.5
@export_range(0.0, 1.0, 0.01) var ink_interior : float = 0.3
@export var ink_color : Color = Color(0.16, 0.18, 0.36)
## Hue-shifted shadows: shadows pushed towards one tint and lights towards another (brightness
## kept), beyond what the colour gradient does.
@export_range(0.0, 1.0, 0.01) var hue_shift_strength : float = 0.0
@export var shadow_tint : Color = Color(0.72, 0.68, 1.0)
@export var light_tint : Color = Color(1.0, 0.92, 0.78)
## Rim bloom: the brightest parts (silver linings) glow softly past themselves.
@export_range(0.0, 2.0, 0.01) var rim_bloom_strength : float = 0.0
## Brightness above which it glows (1 = a fully sunlit white).
@export_range(0.0, 4.0, 0.01) var rim_bloom_threshold : float = 0.9
@export_range(1.0, 32.0, 0.5) var rim_bloom_radius : float = 10.0

enum KuwaharaMode { OFF, CLASSIC, ANISOTROPIC }

var rd : RenderingDevice
var shader : RID
var pipeline : RID
var params_buffer : RID
var linear_clamp : RID
var linear_repeat : RID
var nearest : RID
var nearest_repeat : RID # The panorama depths: never blended across a silhouette.
var fallback_3d : RID
var fallback_2d : RID
var frame := 0

# The distant panorama (render thread only).
var pano_shader : RID
var pano_pipeline : RID
var pano_params : RID
var pano_slots : RID
var pano_horizon_slots : RID
var repaint_requested := false
var pano_noise_params : RID

# The paint filters (render thread only).
var paint_shader : RID
var paint_pipeline : RID
var tensor_shader : RID
var tensor_pipeline : RID
var paint_params : RID
const PAINT_PARAMS_SIZE := 160
const LAYER_CONTEXT := &"painted_clouds"
# Two panoramas (the front one shown, the other painted and then faded in), each with the near
# cells (absolute) it leaves to the near tiles.
var pano : Array[RID] = [RID(), RID()]
var pano_depth : Array[RID] = [RID(), RID()]
var pano_centre : Array[Vector3] = [Vector3.ZERO, Vector3.ZERO] # absolute: where each was painted from
var pano_cells := [[], []]
var pano_size := Vector2i.ZERO
var pano_front := 0
var pano_shown := false
var pano_key := []
var painting := false
var paint_row := 0
var paint_state := {}
var paint_centre := Vector3.ZERO # absolute
var paint_cells : Array = []
var paint_started_ms := 0
var fading := false
var fade_started_ms := 0
var fade_seconds := 1.5 # This fade's length.
# Hidden swaps: a painted panorama waiting for a hidden moment, the share of the screen showing
# distant clouds (measured on the GPU while waiting), and the fallback wisp.
var waiting := false
var wait_started_ms := 0
var coverage := 1.0
var coverage_valid := false
var coverage_reading := false
var coverage_buffer : RID
var wisp_active := false
var wisp_started_ms := 0
var wisp_centre := Vector3.ZERO # absolute
var wisp_direction := Vector3.FORWARD # The way the camera was heading when it appeared.
var wisp_puff_data : Array[Vector4] = [] # Per puff: offset from the centre (m), radius (m).
var wisp_fade_out_ms := -1 # When it started fading away (-1 = not yet).
var wisp_entered_it := false
var camera_velocity := Vector3.ZERO # absolute, smoothed (for placing the wisp)
var _last_camera := Vector3.ZERO
var _last_camera_ms := -1
# What get_wisp_density() reads (any thread): [absolute centre, flatten, puffs, density now, softness].
static var _wisp_mutex := Mutex.new()
static var _wisp_shared := []

const PARAMS_SIZE := 736
const MAX_WISP_PUFFS := 8
const PANO_PARAMS_SIZE := 352
const PANO_LAT_MAX := PI / 4.0
const PANO_LAT_MIN := -PI / 2.0
const MAX_FAR_SLOTS := 15 * 15
const MAX_HORIZON_SLOTS := 31 * 31


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize)


func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE and rd:
		for rid in [pipeline, shader, params_buffer, linear_clamp, linear_repeat, nearest, nearest_repeat, fallback_3d, fallback_2d,
				pano_pipeline, pano_shader, pano_params, pano_slots, pano_horizon_slots,
				pano[0], pano[1], pano_depth[0], pano_depth[1], coverage_buffer,
				paint_pipeline, paint_shader, tensor_pipeline, tensor_shader, paint_params, pano_noise_params]:
			if rid.is_valid():
				rd.free_rid(rid)


func _initialize() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return
	var file : RDShaderFile = load("res://addons/painted_clouds/shaders/raymarch.glsl")
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("PaintedCloudsEffect: " + spirv.compile_error_compute)
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	params_buffer = rd.uniform_buffer_create(PARAMS_SIZE)
	var zeros8 := PackedByteArray()
	zeros8.resize(8)
	coverage_buffer = rd.storage_buffer_create(8, zeros8)
	linear_clamp = _sampler(RenderingDevice.SAMPLER_FILTER_LINEAR, RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE)
	linear_repeat = _sampler(RenderingDevice.SAMPLER_FILTER_LINEAR, RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)
	nearest = _sampler(RenderingDevice.SAMPLER_FILTER_NEAREST, RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE)
	nearest_repeat = _sampler(RenderingDevice.SAMPLER_FILTER_NEAREST, RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)
	# Stand-ins while the noise or gradient isn't there (or still generating).
	fallback_3d = _solid_texture(RenderingDevice.TEXTURE_TYPE_3D, 128)
	fallback_2d = _solid_texture(RenderingDevice.TEXTURE_TYPE_2D, 255)
	paint_shader = _compile("res://addons/painted_clouds/shaders/paint.glsl")
	tensor_shader = _compile("res://addons/painted_clouds/shaders/paint_tensor.glsl")
	if paint_shader.is_valid():
		paint_pipeline = rd.compute_pipeline_create(paint_shader)
		paint_params = rd.uniform_buffer_create(PAINT_PARAMS_SIZE)
	if tensor_shader.is_valid():
		tensor_pipeline = rd.compute_pipeline_create(tensor_shader)
	var pano_file : RDShaderFile = load("res://addons/painted_clouds/shaders/panorama.glsl")
	var pano_spirv := pano_file.get_spirv()
	if pano_spirv.compile_error_compute != "":
		push_error("PaintedCloudsEffect: " + pano_spirv.compile_error_compute)
	else:
		pano_shader = rd.shader_create_from_spirv(pano_spirv)
		pano_pipeline = rd.compute_pipeline_create(pano_shader)
		pano_params = rd.uniform_buffer_create(PANO_PARAMS_SIZE)
		var zeros := PackedByteArray()
		zeros.resize(MAX_FAR_SLOTS * 16)
		pano_slots = rd.storage_buffer_create(zeros.size(), zeros)
		var horizon_zeros := PackedByteArray()
		horizon_zeros.resize(MAX_HORIZON_SLOTS * 16)
		pano_horizon_slots = rd.storage_buffer_create(horizon_zeros.size(), horizon_zeros)
		pano_noise_params = rd.uniform_buffer_create(32)


func _compile(path : String) -> RID:
	var file : RDShaderFile = load(path)
	var spirv := file.get_spirv() if file else null
	if spirv == null or spirv.compile_error_compute != "":
		push_error("PaintedCloudsEffect: %s: %s" % [path, spirv.compile_error_compute if spirv else "missing"])
		return RID()
	return rd.shader_create_from_spirv(spirv)


func _sampler(filter : RenderingDevice.SamplerFilter, repeat : RenderingDevice.SamplerRepeatMode) -> RID:
	var state := RDSamplerState.new()
	state.min_filter = filter
	state.mag_filter = filter
	state.repeat_u = repeat
	state.repeat_v = repeat
	state.repeat_w = repeat
	return rd.sampler_create(state)


func _solid_texture(type : RenderingDevice.TextureType, value : int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = type
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = 1
	format.height = 1
	format.depth = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [PackedByteArray([value, value, value, 255])])


func _texture_rid(texture : Texture, fallback : RID) -> RID:
	if texture == null:
		return fallback
	var rid := RenderingServer.texture_get_rd_texture(texture.get_rid())
	return rid if rid.is_valid() else fallback


func _render_callback(_callback_type : int, render_data : RenderData) -> void:
	if rd == null or !pipeline.is_valid():
		return
	# Tiles (a PaintedCloudTileWorld) unless this effect has a bake of its own, else the active bake.
	var tiles := {}
	if bake == null and PaintedCloudTileWorld.active:
		tiles = PaintedCloudTileWorld.active.get_render_state()
	var cloud_bake := bake if bake else PaintedCloudBake.active
	var volume : RID
	if !tiles.is_empty():
		volume = tiles.atlas
	elif cloud_bake and cloud_bake.has_data():
		volume = _texture_rid(cloud_bake.get_texture(), RID())
	if !volume.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	frame += 1
	var noise_rid := _texture_rid(noise, fallback_3d)
	var gradient_rid := _texture_rid(gradient, fallback_2d)
	var far_on := false
	var with_panorama := !tiles.is_empty() and tiles.has("far") and distant_clouds and pano_pipeline.is_valid()
	if with_panorama:
		_update_panorama(tiles, scene_data.get_cam_transform(), gradient_rid, noise_rid)
		far_on = pano_shown or fading
	# The near cells drawn: those the shown panorama leaves out, and (fading in) the new one's.
	var cells_a : Array = []
	var cells_b : Array = []
	var fade_ab := 0.0
	if !tiles.is_empty():
		if far_on:
			cells_a = pano_cells[pano_front] if pano_shown else tiles.ready_cells
			cells_b = pano_cells[1 - pano_front] if fading else cells_a
			fade_ab = _fade_weight()
		else:
			cells_a = tiles.ready_cells
			cells_b = cells_a
		var held : Array = []
		if with_panorama:
			held = cells_a + cells_b + (paint_cells if painting or waiting else [])
		PaintedCloudTileWorld.active.set_held_cells(held)

	for view in buffers.get_view_count():
		var bytes := PackedByteArray()
		bytes.resize(PARAMS_SIZE)
		_put_projection(bytes, 0, scene_data.get_view_projection(view).inverse())
		_put_transform(bytes, 64, scene_data.get_cam_transform())
		if tiles.is_empty():
			_put(bytes, 128, cloud_bake.origin, cloud_bake.voxel_size)
			_put(bytes, 144, cloud_bake.size, float(max_steps))
			_put(bytes, 160, cloud_bake.sun_direction.normalized(), wrap)
		else:
			# The box round the near cells drawn, and which cells they are.
			var cells := _cell_mask(cells_a, cells_b, tiles.offset_cells)
			var first : Vector2i = cells.first
			var span : Vector2i = cells.span
			_put(bytes, 128, Vector3(first.x * tiles.cell_size, tiles.floor, first.y * tiles.cell_size), tiles.voxel)
			_put(bytes, 144, Vector3(span.x * tiles.cell_size, tiles.window_size.y, span.y * tiles.cell_size), float(max_steps))
			_put(bytes, 160, tiles.sun, wrap)
			bytes.encode_s32(496, cells.a)
			bytes.encode_s32(500, cells.b)
			bytes.encode_s32(504, first.x)
			bytes.encode_s32(508, first.y)
			_put(bytes, 560, Vector3(span.x, span.y, handover_band), fade_ab)
			_put(bytes, 288, Vector3(tiles.cell_size, tiles.voxel, tiles.floor), float(tiles.grid))
			var shift : Vector2i = tiles.slot_shift
			_put(bytes, 304, Vector3(tiles.tile_dims), float(shift.x))
			_put(bytes, 320, Vector3(tiles.atlas_dims), float(shift.y))
			var slots : Array = tiles.slots
			for i in slots.size():
				var slot : Vector3i = slots[i]
				bytes.encode_s32(336 + i * 16, slot.x)
				bytes.encode_s32(340 + i * 16, slot.y)
				bytes.encode_s32(344 + i * 16, slot.z)
		var sun := sun_color.srgb_to_linear()
		_put(bytes, 176, Vector3(sun.r, sun.g, sun.b) * sun_energy, rim_strength)
		_put(bytes, 192, Vector3(softness, extinction, noise_strength if noise else 0.0), noise_scale)
		_put(bytes, 208, Vector3(inside_step, step_growth_per_km / 1000.0, edge_fade), min_skip)
		var fade := fade_color.srgb_to_linear()
		_put(bytes, 224, Vector3(fade.r, fade.g, fade.b), fade_amount)
		_put(bytes, 240, Vector3(fade_start, maxf(fade_end, fade_start + 1.0), float(frame % 64)), detail_strength)
		_put(bytes, 256, Vector3(sun_shadow, sky_shadow, banding), rim_power)
		_put(bytes, 512, Vector3(1.0 if far_on else 0.0, _fade_weight(), PANO_LAT_MAX), 1.0 if panorama_parallax else 0.0)
		# The noise is sampled in world (absolute) space, so a floating-origin shift doesn't move it.
		var noise_offset : Vector3 = tiles.offset if !tiles.is_empty() else Vector3.ZERO
		bytes.encode_float(480, PANO_LAT_MIN)
		bytes.encode_float(484, noise_offset.x)
		bytes.encode_float(488, noise_offset.y)
		bytes.encode_float(492, noise_offset.z)
		if far_on:
			var offset : Vector3 = tiles.offset
			_put(bytes, 528, pano_centre[pano_front] - offset, 0.0)
			_put(bytes, 544, pano_centre[1 - pano_front] - offset, 0.0)
		# The wisp and whether to measure the distant clouds on screen.
		var wisp_now := _wisp_density_now() if wisp_active and !tiles.is_empty() else 0.0
		var wisp_local : Vector3 = wisp_centre - tiles.offset if !tiles.is_empty() else Vector3.ZERO
		if wisp_now > 0.0:
			# Make sure the box reaches it, above or below the clouds.
			var box_y := bytes.decode_float(132)
			var box_h := bytes.decode_float(148)
			var reach := wisp_radius * maxf(wisp_flatten, 0.2) * 1.5
			var lo := minf(box_y, wisp_local.y - reach)
			var hi := maxf(box_y + box_h, wisp_local.y + reach)
			bytes.encode_float(132, lo)
			bytes.encode_float(148, hi - lo)
			for i in mini(wisp_puff_data.size(), MAX_WISP_PUFFS):
				var puff : Vector4 = wisp_puff_data[i]
				_put(bytes, 608 + i * 16, Vector3(puff.x, puff.y, puff.z), puff.w)
		_put(bytes, 576, wisp_local, wisp_radius)
		_put(bytes, 592, Vector3(wisp_flatten, wisp_now, 1.0 if waiting else 0.0), hidden_distance)
		bytes.encode_s32(272, size.x)
		bytes.encode_s32(276, size.y)
		rd.buffer_update(params_buffer, 0, PARAMS_SIZE, bytes)

		if !paint_pipeline.is_valid():
			return
		var cloud_layer := _layer_texture(buffers, &"cloud_layer_%d" % view, size)
		var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [cloud_layer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [nearest, buffers.get_depth_layer(view)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [linear_clamp, volume]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [linear_repeat, noise_rid]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [linear_clamp, gradient_rid]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 5, [params_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 7, [linear_repeat, _pano_texture(pano, 0, far_on)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8, [linear_repeat, _pano_texture(pano, 1, far_on)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 9, [nearest_repeat, _pano_texture(pano_depth, 0, far_on)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 10, [nearest_repeat, _pano_texture(pano_depth, 1, far_on)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 11, [coverage_buffer]),
		])
		var measure := waiting and view == 0 and !coverage_reading
		if measure:
			rd.buffer_clear(coverage_buffer, 0, 8)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		rd.compute_list_end()
		if measure:
			coverage_reading = true
			rd.buffer_get_data_async(coverage_buffer, _on_coverage, 0, 8)
		_paint(buffers, view, size, cloud_layer)


# A screen-sized texture kept in the viewport's render buffers (made again when it resizes).
func _layer_texture(buffers : RenderSceneBuffersRD, name : StringName, size : Vector2i) -> RID:
	if !buffers.has_texture(LAYER_CONTEXT, name):
		buffers.create_texture(LAYER_CONTEXT, name, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	return buffers.get_texture(LAYER_CONTEXT, name)


# The paint filters on the cloud layer, then the composite over the scene.
func _paint(buffers : RenderSceneBuffersRD, view : int, size : Vector2i, cloud_layer : RID) -> void:
	var anisotropic := kuwahara == KuwaharaMode.ANISOTROPIC and kuwahara_strength > 0.0 and tensor_pipeline.is_valid()
	var tensor := fallback_2d
	if anisotropic:
		tensor = _layer_texture(buffers, &"tensor_%d" % view, size)
		var tensor_set := UniformSetCacheRD.get_cache(tensor_shader, 0, [
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [nearest, cloud_layer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [tensor]),
		])
		var push := PackedByteArray()
		push.resize(16)
		push.encode_s32(0, size.x)
		push.encode_s32(4, size.y)
		var tensor_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(tensor_list, tensor_pipeline)
		rd.compute_list_bind_uniform_set(tensor_list, tensor_set, 0)
		rd.compute_list_set_push_constant(tensor_list, push, push.size())
		rd.compute_list_dispatch(tensor_list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		rd.compute_list_end()

	var bytes := PackedByteArray()
	bytes.resize(PAINT_PARAMS_SIZE)
	bytes.encode_s32(0, size.x)
	bytes.encode_s32(4, size.y)
	bytes.encode_s32(8, int(kuwahara) if kuwahara_strength > 0.0 and (kuwahara != KuwaharaMode.ANISOTROPIC or anisotropic) else 0)
	_put(bytes, 16, Vector3(kuwahara_radius, kuwahara_strength, kuwahara_sharpness), kuwahara_anisotropy)
	_put(bytes, 32, Vector3(watercolor_strength, watercolor_width, 0.0), 0.0)
	_put(bytes, 48, Vector3(grain_strength, grain_scale, 0.0), 0.0)
	_put(bytes, 64, Vector3(ink_strength, ink_width, ink_interior), 0.0)
	var ink := ink_color.srgb_to_linear()
	_put(bytes, 80, Vector3(ink.r, ink.g, ink.b), 0.0)
	_put(bytes, 96, Vector3(hue_shift_strength, 0.0, 0.0), 0.0)
	var dark := shadow_tint.srgb_to_linear()
	var light := light_tint.srgb_to_linear()
	_put(bytes, 112, Vector3(dark.r, dark.g, dark.b), 0.0)
	_put(bytes, 128, Vector3(light.r, light.g, light.b), 0.0)
	_put(bytes, 144, Vector3(rim_bloom_strength, rim_bloom_threshold, rim_bloom_radius), 0.0)
	rd.buffer_update(paint_params, 0, PAINT_PARAMS_SIZE, bytes)
	var paint_set := UniformSetCacheRD.get_cache(paint_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [buffers.get_color_layer(view)]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [linear_clamp, cloud_layer]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [linear_clamp, tensor]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [paint_params]),
	])
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, paint_pipeline)
	rd.compute_list_bind_uniform_set(list, paint_set, 0)
	rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	rd.compute_list_end()


# ---- The distant panorama ----

# Two sets of near cells (absolute) as bit masks over the box round both (in local cells): bit
# x + z * span.x for the cell at first + (x, z). The box is at most 5 x 5 cells (in practice the
# window or two overlapping windows).
func _cell_mask(cells_a : Array, cells_b : Array, offset_cells : Vector2i) -> Dictionary:
	var all := cells_a + cells_b
	if all.is_empty():
		return {"a": 0, "b": 0, "first": Vector2i.ZERO, "span": Vector2i.ONE}
	var lo : Vector2i = all[0]
	var hi : Vector2i = all[0]
	for cell in all:
		lo = lo.min(cell)
		hi = hi.max(cell)
	var span := (hi - lo + Vector2i.ONE).min(Vector2i(5, 5))
	var bits := [0, 0]
	var sets := [cells_a, cells_b]
	for k in 2:
		for cell in sets[k]:
			var r : Vector2i = cell - lo
			if r.x < span.x and r.y < span.y:
				bits[k] |= 1 << (r.x + r.y * span.x)
	return {"a": bits[0], "b": bits[1], "first": lo - offset_cells, "span": span}


static func _same_cells(a : Array, b : Array) -> bool:
	if a.size() != b.size():
		return false
	for cell in a:
		if !b.has(cell):
			return false
	return true


# The panorama's texture: which = 0 the front (shown) one, 1 the other.
func _pano_texture(textures : Array[RID], which : int, on : bool) -> RID:
	if !on:
		return fallback_2d
	return textures[pano_front if which == 0 else 1 - pano_front]


## Where the panorama now shown was painted from, as an absolute position.
func painted_from() -> Vector3:
	return pano_centre[pano_front]


func _make_pano_textures(size : Vector2i) -> void:
	for i in 2:
		for rid in [pano[i], pano_depth[i]]:
			if rid.is_valid():
				rd.free_rid(rid)
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.width = size.x
		format.height = size.y
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		pano[i] = rd.texture_create(format, RDTextureView.new())
		# Empty: no cloud, all of the sky behind shows through.
		rd.texture_clear(pano[i], Color(0.0, 0.0, 0.0, 1.0), 0, 1, 0, 1)
		var depth_format := RDTextureFormat.new()
		depth_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		depth_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		depth_format.width = size.x
		depth_format.height = size.y
		depth_format.usage_bits = format.usage_bits
		pano_depth[i] = rd.texture_create(depth_format, RDTextureView.new())
		rd.texture_clear(pano_depth[i], Color(1e5, 0.0, 0.0, 0.0), 0, 1, 0, 1)


# Starts re-painting (into the hidden one) when what the panorama shows has changed (the near
# cells it leaves out, the far tiles) or the camera has moved far enough, paints some rows each
# frame, then fades it in over the shown one and swaps them.
func _update_panorama(tiles : Dictionary, camera : Transform3D, gradient_rid : RID, noise_rid : RID) -> void:
	var camera_position := camera.origin
	var width := maxi(panorama_width, 64)
	var wanted_size := Vector2i(width, roundi(width * (PANO_LAT_MAX - PANO_LAT_MIN) / TAU))
	if wanted_size != pano_size:
		_make_pano_textures(wanted_size)
		pano_size = wanted_size
		pano_shown = false
		pano_key = []
		painting = false
		fading = false
		waiting = false
	var now := Time.get_ticks_msec()
	if fading and _fade_weight() >= 1.0:
		fading = false
		pano_front = 1 - pano_front
		pano_shown = true
	_track_camera(camera_position + tiles.offset, now)
	if waiting:
		_update_waiting(now, camera)
	if wisp_active:
		_update_wisp(now, camera_position + tiles.offset, tiles.offset)
	var key : Array = tiles.far.key
	var here : Vector3 = camera_position + tiles.offset
	var ready_cells : Array = tiles.ready_cells
	var repaint := repaint_requested
	if pano_shown and !painting and !fading and !waiting:
		# The near cells changed (tiles landed, or the window moved on): hand them over.
		if !_same_cells(ready_cells, pano_cells[pano_front]):
			repaint = true
		if panorama_auto_repaint:
			var moved : Vector3 = here - painted_from()
			if absf(moved.y) > panorama_repaint_height or Vector2(moved.x, moved.z).length() > panorama_repaint_distance:
				repaint = true
	# The first panorama is painted from whatever has landed; after that, only from complete rings.
	if key != pano_key and (!pano_shown or tiles.far.complete):
		repaint = true
	if !painting and !fading and !waiting and repaint:
		repaint_requested = false
		painting = true
		paint_row = 0
		paint_state = tiles.duplicate()
		paint_centre = here
		paint_cells = ready_cells.duplicate()
		pano_centre[1 - pano_front] = paint_centre
		pano_cells[1 - pano_front] = paint_cells
		paint_started_ms = now
		pano_key = key
	if painting:
		_paint_rows(gradient_rid, noise_rid)
		paint_row += panorama_rows_per_frame
		if paint_row >= pano_size.y:
			painting = false
			var hold := swap_when_hidden and pano_shown
			print("PaintedCloudsEffect: distant panorama painted (%d x %d, leaving %d near cells to the tiles) in %d ms, %s" % [
				pano_size.x, pano_size.y, paint_cells.size(), now - paint_started_ms,
				"waiting for a hidden moment to swap it in" if hold else "fading in"])
			if hold:
				waiting = true
				wait_started_ms = now
				coverage_valid = false
			else:
				_start_fade(panorama_fade_seconds, now)


## True while a panorama is being painted, waiting for a hidden moment, faded in or waiting to
## re-paint.
func is_busy() -> bool:
	return painting or waiting or fading or repaint_requested


func _start_fade(seconds : float, now : int) -> void:
	waiting = false
	fading = true
	fade_seconds = seconds
	fade_started_ms = now


# A painted panorama waiting to swap in: swaps when the screen shows hardly any distant clouds;
# after swap_max_wait puts the wisp on the camera's path (the swap then happens while the camera is
# in it, or is forced if it misses), or fades in anyway.
func _update_waiting(now : int, camera : Transform3D) -> void:
	var waited := (now - wait_started_ms) / 1000.0
	if coverage_valid and coverage <= hidden_coverage:
		print("PaintedCloudsEffect: swapped the panorama in while hidden (%.1f%% of the screen showing distant clouds) after %.1f s%s" % [
			coverage * 100.0, waited, ", in the wisp" if wisp_active else ""])
		_start_fade(hidden_fade_seconds, now)
	elif !wisp_active and waited > swap_max_wait:
		if fallback_wisp and PaintedCloudTileWorld.active != null:
			_spawn_wisp(now, camera)
			print("PaintedCloudsEffect: no hidden moment in %.1f s: a wisp on the camera's path, %.0f m ahead" % [
				waited, (wisp_centre - (camera.origin + _world_offset())).length()])
		else:
			print("PaintedCloudsEffect: no hidden moment in %.1f s: fading the panorama in" % waited)
			_start_fade(panorama_fade_seconds, now)


# The camera's velocity (absolute, smoothed over about half a second), to put the wisp in its path.
func _track_camera(here : Vector3, now : int) -> void:
	if _last_camera_ms >= 0 and now > _last_camera_ms:
		var dt := (now - _last_camera_ms) / 1000.0
		var v := (here - _last_camera) / dt
		if v.length() < 50000.0: # Not a teleport (or an origin shift).
			camera_velocity = camera_velocity.lerp(v, clampf(dt / 0.5, 0.0, 1.0))
	_last_camera = here
	_last_camera_ms = now


# Puts the wisp, still, where the camera will be in wisp_ahead_seconds (or ahead along its view
# when hovering): a new random cluster of puffs, fading in.
func _spawn_wisp(now : int, camera : Transform3D) -> void:
	var here : Vector3 = camera.origin + _world_offset()
	var speed := camera_velocity.length()
	var direction : Vector3 = camera_velocity / speed if speed > 20.0 else -camera.basis.z.normalized()
	var distance := clampf(speed * wisp_ahead_seconds, wisp_min_distance, maxf(wisp_max_distance, wisp_min_distance))
	wisp_centre = here + direction * distance
	wisp_direction = direction
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	wisp_puff_data.clear()
	var count := clampi(wisp_puffs, 1, MAX_WISP_PUFFS)
	for i in count:
		var size := wisp_radius * wisp_puff_size * rng.randf_range(0.7, 1.25)
		var offset := Vector3.ZERO
		if i == 0:
			size = wisp_radius * maxf(wisp_puff_size, 0.4) * 1.2 # A core, so flying through the middle is always in it.
		else:
			var spread := maxf(wisp_radius - size, 0.0)
			var a := rng.randf() * TAU
			var r := sqrt(rng.randf()) * spread
			offset = Vector3(cos(a) * r, rng.randf_range(-0.5, 0.6) * spread, sin(a) * r)
		wisp_puff_data.append(Vector4(offset.x, offset.y, offset.z, size))
	wisp_active = true
	wisp_started_ms = now
	wisp_fade_out_ms = -1
	wisp_entered_it = false
	_share_wisp()
	var local := wisp_centre - _world_offset()
	call_deferred("emit_signal", "wisp_appeared", local, wisp_radius)


# The wisp after it appeared: notices the camera flying in, forces the swap if the camera passes it
# by or turns away, and fades it away once it's behind (or the time's up).
func _update_wisp(now : int, here : Vector3, offset : Vector3) -> void:
	var inside := _wisp_density_at(here) > 0.3
	if inside and !wisp_entered_it:
		wisp_entered_it = true
		print("PaintedCloudsEffect: the camera flew into the wisp")
		call_deferred("emit_signal", "wisp_entered")
	if wisp_fade_out_ms < 0:
		var along := (here - wisp_centre).dot(wisp_direction)
		var passed := along > wisp_radius * 0.8 and !inside
		var lost := (here - wisp_centre).length() > maxf(wisp_max_distance, wisp_min_distance) * 2.0 + wisp_radius
		var too_long := (now - wisp_started_ms) / 1000.0 > wisp_timeout
		if passed or lost or too_long:
			if waiting:
				print("PaintedCloudsEffect: the camera %s the wisp: fading the panorama in" % (
					"went past" if passed else ("left" if lost else "never reached")))
				_start_fade(panorama_fade_seconds, now)
			wisp_fade_out_ms = now
	elif _wisp_density_now() <= 0.0:
		wisp_active = false
		_share_wisp()
		call_deferred("emit_signal", "wisp_gone", wisp_entered_it)
	if wisp_active:
		_share_wisp()


# The wisp's thickness now: fading in after it appears, and away once passed.
func _wisp_density_now() -> float:
	var now := Time.get_ticks_msec()
	var appear := smoothstep(0.0, 1.0, (now - wisp_started_ms) / (maxf(wisp_fade_in, 0.01) * 1000.0))
	var leave := 1.0
	if wisp_fade_out_ms >= 0:
		leave = 1.0 - smoothstep(0.0, 1.0, (now - wisp_fade_out_ms) / (maxf(wisp_fade_out, 0.01) * 1000.0))
	return wisp_density * appear * leave


# How thick the wisp is at an absolute point (0..about 1, times its fade).
func _wisp_density_at(p : Vector3) -> float:
	return _density_in(p, wisp_centre, wisp_flatten, wisp_puff_data, _wisp_density_now(), softness, wisp_radius)


static func _density_in(p : Vector3, centre : Vector3, flatten : float, puffs : Array, density : float, soft : float, radius : float) -> float:
	if density <= 0.0 or puffs.is_empty():
		return 0.0
	var q := p - centre
	q.y /= maxf(flatten, 0.01)
	var k := 0.35 * radius * 0.5
	var d := 1e9
	for puff in puffs:
		var di : float = (q - Vector3(puff.x, puff.y, puff.z)).length() - puff.w
		var h := clampf(0.5 + 0.5 * (di - d) / k, 0.0, 1.0)
		d = lerpf(di, d, h) - k * h * (1.0 - h)
	d *= minf(1.0, flatten)
	return clampf(0.5 - d / (2.0 * soft), 0.0, 1.0) * density


func _share_wisp() -> void:
	_wisp_mutex.lock()
	_wisp_shared = [wisp_centre, wisp_flatten, wisp_puff_data.duplicate(), _wisp_density_now(), softness, wisp_radius] if wisp_active else []
	_wisp_mutex.unlock()


## How thick the wisp is at a (local, scene) position: 0 outside it (or with no wisp), up to about
## wisp_density deep inside. Any thread. For gameplay: a boost for flying through, say.
static func get_wisp_density(position : Vector3) -> float:
	_wisp_mutex.lock()
	var shared := _wisp_shared
	_wisp_mutex.unlock()
	if shared.is_empty() or !PaintedCloudTileWorld.active != null:
		return 0.0
	return _density_in(position + _world_offset(), shared[0], shared[1], shared[2], shared[3], shared[4], shared[5])


# The floating origin's offset (absolute = local + this).
static func _world_offset() -> Vector3:
	var world := PaintedCloudTileWorld.active
	return world.to_absolute(Vector3.ZERO) if world else Vector3.ZERO


## Whether a wisp is out (fading in, waiting to be flown through, or fading away).
static func is_wisp_out() -> bool:
	_wisp_mutex.lock()
	var out := !_wisp_shared.is_empty()
	_wisp_mutex.unlock()
	return out


# The GPU's count of distant clouds on screen (render thread, a frame or so later).
func _on_coverage(data : PackedByteArray) -> void:
	coverage_reading = false
	if data.size() < 8:
		return
	var total := data.decode_u32(0)
	var count := data.decode_u32(4)
	if count > 0:
		coverage = total / (255.0 * count)
		coverage_valid = true


# How far the new panorama has faded in over the shown one (0 when it isn't fading).
func _fade_weight() -> float:
	if !fading:
		return 0.0
	if fade_seconds <= 0.0:
		return 1.0
	return clampf((Time.get_ticks_msec() - fade_started_ms) / (fade_seconds * 1000.0), 0.0, 1.0)


func _paint_rows(gradient_rid : RID, noise_rid : RID) -> void:
	var state := paint_state
	var far_state : Dictionary = state.far
	var offset : Vector3 = state.offset
	var bytes := PackedByteArray()
	bytes.resize(PANO_PARAMS_SIZE)
	_put(bytes, 0, paint_centre - offset, PANO_LAT_MAX)
	_put(bytes, 16, state.window_min, 0.0)
	_put(bytes, 32, state.window_size, float(far_max_steps))
	_put(bytes, 48, far_state.window_min, far_edge_fade)
	_put(bytes, 64, far_state.window_size, far_inside_step)
	_put(bytes, 80, Vector3(state.cell_size, far_state.voxel, state.floor), float(far_state.grid))
	var shift : Vector2i = far_state.slot_shift
	_put(bytes, 96, Vector3(far_state.tile_dims), float(shift.x))
	_put(bytes, 112, Vector3(far_state.atlas_dims), float(shift.y))
	_put(bytes, 128, state.sun, wrap)
	var sun := sun_color.srgb_to_linear()
	_put(bytes, 144, Vector3(sun.r, sun.g, sun.b) * sun_energy, rim_strength)
	_put(bytes, 160, Vector3(softness, extinction, min_skip), step_growth_per_km / 1000.0)
	var fade := fade_color.srgb_to_linear()
	_put(bytes, 176, Vector3(fade.r, fade.g, fade.b), fade_amount)
	var horizon_state : Dictionary = state.get("horizon", {})
	var with_horizon := !horizon_state.is_empty()
	_put(bytes, 192, Vector3(fade_start, maxf(fade_end, fade_start + 1.0), PANO_LAT_MIN), 1.0 if with_horizon else 0.0)
	_put(bytes, 208, Vector3(sun_shadow, sky_shadow, banding), rim_power)
	var rows := mini(panorama_rows_per_frame, pano_size.y - paint_row)
	bytes.encode_s32(224, paint_row)
	bytes.encode_s32(228, rows)
	bytes.encode_s32(232, pano_size.x)
	bytes.encode_s32(236, pano_size.y)
	var horizon_atlas : RID = far_state.atlas
	if with_horizon:
		_put(bytes, 240, horizon_state.window_min, far_edge_fade)
		_put(bytes, 256, horizon_state.window_size, 0.0)
		var horizon_shift : Vector2i = horizon_state.slot_shift
		_put(bytes, 272, Vector3(state.cell_size, horizon_state.voxel, state.floor), float(horizon_state.grid))
		_put(bytes, 288, Vector3(horizon_state.tile_dims), float(horizon_shift.x))
		_put(bytes, 304, Vector3(horizon_state.atlas_dims), float(horizon_shift.y))
		horizon_atlas = horizon_state.atlas
		var horizon_bytes : PackedByteArray = (horizon_state.slots as PackedInt32Array).to_byte_array()
		if horizon_bytes.size() > MAX_HORIZON_SLOTS * 16:
			horizon_bytes = horizon_bytes.slice(0, MAX_HORIZON_SLOTS * 16)
		rd.buffer_update(pano_horizon_slots, 0, horizon_bytes.size(), horizon_bytes)
	# The near cells it leaves out (fading in over the band inside their edge).
	var cells := _cell_mask(paint_cells, paint_cells, state.offset_cells)
	var first : Vector2i = cells.first
	var span : Vector2i = cells.span
	bytes.encode_s32(320, cells.a)
	bytes.encode_s32(324, span.x)
	bytes.encode_s32(328, first.x)
	bytes.encode_s32(332, first.y)
	_put(bytes, 336, Vector3(span.y, handover_band, 0.0), 0.0)
	rd.buffer_update(pano_params, 0, PANO_PARAMS_SIZE, bytes)
	var noise_bytes := PackedByteArray()
	noise_bytes.resize(32)
	_put(noise_bytes, 0, Vector3(noise_strength if noise else 0.0, noise_scale, detail_strength), distant_noise_distance)
	_put(noise_bytes, 16, offset, 0.0)
	rd.buffer_update(pano_noise_params, 0, 32, noise_bytes)
	var slots : PackedInt32Array = far_state.slots
	var slot_bytes := slots.to_byte_array()
	if slot_bytes.size() > MAX_FAR_SLOTS * 16:
		slot_bytes = slot_bytes.slice(0, MAX_FAR_SLOTS * 16)
	rd.buffer_update(pano_slots, 0, slot_bytes.size(), slot_bytes)
	var target : RID = pano[1 - pano_front]
	var uniform_set := UniformSetCacheRD.get_cache(pano_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [target]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [linear_clamp, far_state.atlas]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [linear_clamp, gradient_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [pano_params]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [pano_slots]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 5, [pano_depth[1 - pano_front]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6, [linear_clamp, horizon_atlas]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 7, [pano_horizon_slots]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8, [linear_repeat, noise_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 9, [pano_noise_params]),
	])
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pano_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, ceili(pano_size.x / 8.0), ceili(rows / 8.0), 1)
	rd.compute_list_end()


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


static func _put_projection(bytes : PackedByteArray, offset : int, p : Projection) -> void:
	for c in 4:
		var column : Vector4 = p[c]
		for r in 4:
			bytes.encode_float(offset + (c * 4 + r) * 4, column[r])


static func _put_transform(bytes : PackedByteArray, offset : int, t : Transform3D) -> void:
	var columns := [t.basis.x, t.basis.y, t.basis.z, t.origin]
	for c in 4:
		var v : Vector3 = columns[c]
		bytes.encode_float(offset + c * 16, v.x)
		bytes.encode_float(offset + c * 16 + 4, v.y)
		bytes.encode_float(offset + c * 16 + 8, v.z)
		bytes.encode_float(offset + c * 16 + 12, 1.0 if c == 3 else 0.0)
