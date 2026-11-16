#[compute]
#version 450

// Paints the distant clouds into a panorama seen from one point: an equirectangular strip from
// lat_min (straight down at -90 degrees) to lat_max. Only the clouds outside the near cells (the
// loaded tiles the effect draws itself), fading in over the band inside their edge exactly as the
// near clouds fade out there, so every cloud is drawn once. Out through the far tiles (coarse, but under the near ones too), then on
// through the horizon tiles (very coarse), cross-fading between them over the far window's edge
// band, and thinning out towards the horizon window's edge. Shaded as the near clouds are, without
// the billow noise (too small to see this far). Also stores how far away each pixel's clouds are,
// so the effect can re-project them for a camera that has moved since. Rows first_row ..
// first_row + rows per dispatch, so a panorama is painted over several frames.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict writeonly image2D panorama;
// The far tiles' atlas: r = signed distance (m), g = sun, b = sky, a = noise scale.
layout(set = 0, binding = 1) uniform sampler3D far_atlas;
layout(set = 0, binding = 2) uniform sampler2D gradient_texture;

layout(set = 0, binding = 3, std140) uniform Params {
	vec4 centre; // 0, xyz = where it's painted from, w = lat_max (radians)
	vec4 near_min; // 16, xyz = the near tiles' window, w = start: the horizontal distance (m) it paints from
	vec4 near_size; // 32, xyz, w = max steps
	vec4 far_min; // 48, xyz = the far tiles' window, w = the band (m) inside its edge where far hands over to horizon
	vec4 far_size; // 64, xyz, w = inside step (m)
	vec4 tile_a; // 80, x = cell size, y = far voxel size, z = floor y, w = far grid
	vec4 tile_b; // 96, xyz = one far tile's voxels (with its border), w = floating origin offset (cells) on x, mod grid
	vec4 atlas_dims; // 112, xyz, w = floating origin offset (cells) on z, mod grid
	vec4 sun; // 128, xyz = towards the sun, w = wrap
	vec4 sun_color; // 144, rgb = linear colour * energy, w = rim strength
	vec4 shape; // 160, x = softness, y = extinction, z = min skip, w = step growth per m
	vec4 fade_color; // 176, rgb linear, w = haze amount at the end distance
	vec4 fade; // 192, x = haze start, y = haze end, z = lat_min (radians), w = 1 with horizon tiles
	vec4 shading; // 208, x = sun shadow, y = sky shadow, z = banding, w = rim power
	ivec4 rows; // 224, x = first row, y = rows, z = width, w = height
	vec4 horizon_min; // 240, xyz = the horizon tiles' window, w = their fade at its edge (m)
	vec4 horizon_size; // 256, xyz
	vec4 horizon_tile_a; // 272, x = cell size, y = voxel size, z = floor y, w = grid
	vec4 horizon_tile_b; // 288, xyz = one tile's voxels, w = offset (cells) on x, mod grid
	vec4 horizon_atlas_dims; // 304, xyz, w = offset (cells) on z, mod grid
	ivec4 near_cells; // 320, x = the near cells it leaves out (mask), y = their box's width (cells), zw = its first cell (local)
	vec4 near_cells_b; // 336, x = the box's depth (cells), y = the band (m) inside their edge where they hand over
} params;

// Per far slot (x + z * grid): xy = the local cell in it, z = 1 when baked.
layout(set = 0, binding = 4, std430) restrict readonly buffer Slots {
	ivec4 slots[];
};
// How far away (m) the clouds in each pixel are (weighted by how much each sample shows), so the
// effect can re-project them for a camera that has moved since. Where there's no cloud: the edge
// of what was painted.
layout(set = 0, binding = 5, r32f) uniform restrict writeonly image2D panorama_depth;
layout(set = 0, binding = 6) uniform sampler3D horizon_atlas;
layout(set = 0, binding = 7, std430) restrict readonly buffer HorizonSlots {
	ivec4 horizon_slots[];
};
// The same billow noise as the near clouds, so the two match where they hand over.
layout(set = 0, binding = 8) uniform sampler3D noise_texture;

layout(set = 0, binding = 9, std140) uniform NoiseParams {
	vec4 noise; // x = strength (m), y = scale (m), z = detail strength, w = how far out (m) it fades away
	vec4 offset; // xyz = the floating origin's offset (m), so the noise stays put in the world
} noise_params;

float billow(vec3 p, float scale) {
	vec3 uvw = (p + noise_params.offset.xyz) / (noise_params.noise.y * scale);
	float coarse = texture(noise_texture, uvw).r;
	float fine = texture(noise_texture, uvw * 3.7 + vec3(0.31, 0.17, 0.53)).r - 0.5;
	return coarse + fine * noise_params.noise.z;
}

const float PI = 3.14159265359;
const vec4 CLEAR = vec4(1e4, 1.0, 1.0, 1.0);

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec4 far_field(vec3 p) {
	float cell_size = params.tile_a.x;
	float n = params.tile_a.w;
	vec2 cell = floor(p.xz / cell_size);
	vec2 absolute = cell + vec2(params.tile_b.w, params.atlas_dims.w);
	vec2 slot = absolute - n * floor(absolute / n);
	ivec4 s = slots[int(slot.x + slot.y * n)];
	if (s.z == 0 || s.x != int(cell.x) || s.y != int(cell.y)) {
		return CLEAR;
	}
	vec3 local = vec3(p.x - cell.x * cell_size, p.y - params.tile_a.z, p.z - cell.y * cell_size) / params.tile_a.y + vec3(1.0, 0.0, 1.0);
	local = clamp(local, vec3(0.5), params.tile_b.xyz - 0.5);
	vec3 coord = local + vec3(slot.x * params.tile_b.x, 0.0, slot.y * params.tile_b.z);
	return texture(far_atlas, coord / params.atlas_dims.xyz);
}

vec4 horizon_field(vec3 p) {
	float cell_size = params.horizon_tile_a.x;
	float n = params.horizon_tile_a.w;
	vec2 cell = floor(p.xz / cell_size);
	vec2 absolute = cell + vec2(params.horizon_tile_b.w, params.horizon_atlas_dims.w);
	vec2 slot = absolute - n * floor(absolute / n);
	ivec4 s = horizon_slots[int(slot.x + slot.y * n)];
	if (s.z == 0 || s.x != int(cell.x) || s.y != int(cell.y)) {
		return CLEAR;
	}
	vec3 local = vec3(p.x - cell.x * cell_size, p.y - params.horizon_tile_a.z, p.z - cell.y * cell_size) / params.horizon_tile_a.y + vec3(1.0, 0.0, 1.0);
	local = clamp(local, vec3(0.5), params.horizon_tile_b.xyz - 0.5);
	vec3 coord = local + vec3(slot.x * params.horizon_tile_b.x, 0.0, slot.y * params.horizon_tile_b.z);
	return texture(horizon_atlas, coord / params.horizon_atlas_dims.xyz);
}


// The near cells (the loaded tiles the effect is drawing) as a bit mask over a box of cells:
// bit x + z * span.x for the cell at first + (x, z), in local cells.
bool in_cells(ivec2 r, int mask, ivec2 span) {
	return all(greaterThanEqual(r, ivec2(0))) && r.x < span.x && r.y < span.y && ((mask >> (r.x + r.y * span.x)) & 1) != 0;
}

// How much of the clouds at xz the near tiles draw: 1 inside the near cells, fading to 0 over band
// (m) inside their outer edge, 0 outside (the panorama draws 1 minus this, so they always add up).
float near_cells_weight(vec2 xz, int mask, ivec2 first, ivec2 span, float cell_size, float band) {
	vec2 c = floor(xz / cell_size);
	ivec2 r = ivec2(c) - first;
	if (!in_cells(r, mask, span)) {
		return 0.0;
	}
	vec2 local = xz - c * cell_size;
	float d = 1e9;
	for (int dz = -1; dz <= 1; dz++) {
		for (int dx = -1; dx <= 1; dx++) {
			if ((dx != 0 || dz != 0) && !in_cells(r + ivec2(dx, dz), mask, span)) {
				vec2 lo = vec2(dx, dz) * cell_size;
				vec2 q = max(max(lo - local, local - (lo + cell_size)), vec2(0.0));
				d = min(d, length(q));
			}
		}
	}
	return clamp(d / max(band, 1.0), 0.0, 1.0);
}

// Distance from p to the nearest side (x or z) of a box, inside it (negative outside).
float side_distance(vec3 p, vec3 box_min, vec3 box_size) {
	vec2 edge = min(p.xz - box_min.xz, box_min.xz + box_size.xz - p.xz);
	return min(edge.x, edge.y);
}

// How much of the far tiles to use at p (1 well inside their window, 0 beyond; the horizon
// tiles take the rest).
float far_weight(vec3 p) {
	if (params.fade.w < 0.5) {
		return 1.0;
	}
	return clamp(side_distance(p, params.far_min.xyz, params.far_size.xyz) / max(params.far_min.w, 1.0), 0.0, 1.0);
}

// The field at p: the far tiles, handing over to the horizon tiles towards (and past) their edge.
vec4 field(vec3 p, float w) {
	vec4 f = w > 0.0 ? far_field(p) : CLEAR;
	if (w >= 1.0) {
		return f;
	}
	vec4 h = horizon_field(p);
	return mix(h, f, w);
}

vec3 field_normal(vec3 p, float w) {
	float e = mix(params.horizon_tile_a.y, params.tile_a.y, w) * 0.75;
	const vec2 k = vec2(1.0, -1.0);
	return normalize(k.xyy * field(p + k.xyy * e, w).r + k.yyx * field(p + k.yyx * e, w).r
			+ k.yxy * field(p + k.yxy * e, w).r + k.xxx * field(p + k.xxx * e, w).r);
}

bool inside_xz(vec3 p, vec3 box_min, vec3 box_size) {
	return all(greaterThanEqual(p.xz, box_min.xz)) && all(lessThanEqual(p.xz, box_min.xz + box_size.xz));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.x, params.rows.x + int(gl_GlobalInvocationID.y));
	if (pixel.x >= params.rows.z || int(gl_GlobalInvocationID.y) >= params.rows.y || pixel.y >= params.rows.w) {
		return;
	}
	float lat_max = params.centre.w;
	float lat_min = params.fade.z;
	float lon = (float(pixel.x) + 0.5) / float(params.rows.z) * 2.0 * PI - PI;
	float lat = lat_max - (float(pixel.y) + 0.5) / float(params.rows.w) * (lat_max - lat_min);
	vec3 rd = vec3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));
	vec3 ro = params.centre.xyz;
	bool with_horizon = params.fade.w > 0.5;

	// Through the outer window (horizon's, else far's), from where the ray enters the near
	// window's fading band.
	vec3 outer_min = with_horizon ? params.horizon_min.xyz : params.far_min.xyz;
	vec3 outer_size = with_horizon ? params.horizon_size.xyz : params.far_size.xyz;
	vec3 inv = 1.0 / rd;
	vec3 a = (outer_min - ro) * inv;
	vec3 b = (outer_min + outer_size - ro) * inv;
	float t0 = max(max(min(a.x, b.x), min(a.y, b.y)), max(min(a.z, b.z), 0.0));
	float t1 = min(min(max(a.x, b.x), max(a.y, b.y)), max(a.z, b.z));
	float across = length(rd.xz);
	float start = params.near_min.w <= 0.0 ? 0.0 : (across > 1e-4 ? params.near_min.w / across : 1e30);
	float t = max(t0, start);
	ivec2 cells_span = ivec2(params.near_cells.y, int(params.near_cells_b.x));

	vec3 sun_dir = normalize(params.sun.xyz);
	float softness = params.shape.x;
	float sun_forward = pow(max(dot(rd, sun_dir), 0.0), 4.0);
	vec3 color = vec3(0.0);
	float transmittance = 1.0;
	float depth_sum = 0.0;
	float depth_weight = 0.0;
	float far_exit = t1 > 0.0 ? t1 : 1e6;
	int max_steps = int(params.near_size.w);
	for (int i = 0; i < max_steps && t < t1; i++) {
		vec3 p = ro + rd * t;
		float w = far_weight(p);
		vec4 voxel = field(p, w);
		float sdf = voxel.r;
		float coarse = mix(params.horizon_tile_a.y, params.tile_a.y, w);
		float step_length = max(params.far_size.w * (1.0 + t * params.shape.w), coarse * 0.5);
		// Billow noise, fading out with distance (it's too fine to see far out, and costs).
		float noise_amount = noise_params.noise.x * max(voxel.a, 0.05) * (1.0 - smoothstep(0.0, max(noise_params.noise.w, 1.0), t));
		if (sdf > softness + noise_amount * 1.5) {
			t += max(sdf - softness - noise_amount * 1.5, max(params.shape.z, step_length * 0.5));
			continue;
		}
		if (noise_amount > 0.0) {
			sdf -= noise_amount * billow(p, max(voxel.a, 0.05));
		}
		// Thin out towards the outer window's edge.
		float weight = clamp(side_distance(p, outer_min, outer_size) / max(with_horizon ? params.horizon_min.w : params.far_min.w, 1.0), 0.0, 1.0);
		// Leave the near cells to the near tiles (fading in over the band inside their edge).
		weight *= 1.0 - near_cells_weight(p.xz, params.near_cells.x, params.near_cells.zw, cells_span, params.tile_a.x, params.near_cells_b.y);
		float density = clamp(0.5 - sdf / (2.0 * softness), 0.0, 1.0) * weight;
		if (density > 0.002) {
			vec3 n = field_normal(p, w);
			float wrap = params.sun.w;
			float lit = clamp((dot(n, sun_dir) + wrap) / (1.0 + wrap), 0.0, 1.0);
			lit *= mix(1.0, voxel.g, params.shading.x);
			lit *= mix(1.0, voxel.b, params.shading.y);
			lit = mix(lit, lit * lit * (3.0 - 2.0 * lit), params.shading.z);
			vec3 sample_color = srgb_to_linear(texture(gradient_texture, vec2(lit, 0.5)).rgb) * params.sun_color.rgb;
			float rim = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), params.shading.w);
			sample_color += params.sun_color.rgb * rim * params.sun_color.w * (0.2 + sun_forward) * voxel.g;
			float haze = smoothstep(params.fade.x, params.fade.y, t) * params.fade_color.w;
			sample_color = mix(sample_color, params.fade_color.rgb, haze);
			float alpha = 1.0 - exp(-density * params.shape.y * step_length);
			color += transmittance * alpha * sample_color;
			depth_sum += transmittance * alpha * t;
			depth_weight += transmittance * alpha;
			transmittance *= 1.0 - alpha;
			if (transmittance < 0.01) {
				transmittance = 0.0;
				break;
			}
		}
		t += step_length;
	}
	imageStore(panorama, pixel, vec4(color, transmittance));
	// Only clouds that really show set the depth: a faint wisp would otherwise stand in front of
	// what's behind it as a surface the effect's re-projection stops at.
	imageStore(panorama_depth, pixel, vec4(depth_weight > 0.15 ? depth_sum / depth_weight : far_exit));
}
