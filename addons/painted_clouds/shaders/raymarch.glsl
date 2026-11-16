#[compute]
#version 450

// Raymarches the baked cloud volume over the rendered scene, painterly: in clear air each step
// jumps the distance the field says is empty; near and inside the clouds it steps finely, adds
// billowy noise to the surface, and shades each sample like a soft solid (how much its surface
// faces the sun, the baked sun and sky light) through a colour gradient, with a silver lining
// on edges towards the sun.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// The cloud layer this writes: rgb = the clouds' colour (premultiplied), a = how much they cover.
// The paint pass filters it and composites it over the scene.
layout(set = 0, binding = 0, rgba16f) uniform restrict writeonly image2D cloud_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
// r = signed distance (m), g = sun transmittance, b = sky transmittance, a = noise scale (the
// clouds' recipes': smaller for small puffy types).
layout(set = 0, binding = 2) uniform sampler3D volume_texture;
layout(set = 0, binding = 3) uniform sampler3D noise_texture;
layout(set = 0, binding = 4) uniform sampler2D gradient_texture;
// The distant clouds (PaintedCloudTileWorld's far tiles, outside the near cells), painted into two
// panoramas (a shown, b fading in over it): rgb = their colour, a = how much of what's behind
// shows through.
layout(set = 0, binding = 7) uniform sampler2D panorama_a;
layout(set = 0, binding = 8) uniform sampler2D panorama_b;
// How far away the clouds in each panorama pixel are (m), to re-project them for where the camera
// is now rather than where each panorama was painted from.
layout(set = 0, binding = 9) uniform sampler2D panorama_depth_a;
layout(set = 0, binding = 10) uniform sampler2D panorama_depth_b;
// While a new panorama waits for a hidden moment: how much of the screen shows distant clouds
// (summed over every 4th pixel each way, 0..255 a pixel), read back by the effect.
layout(set = 0, binding = 11, std430) restrict buffer Coverage {
	uint coverage_sum;
	uint coverage_count;
};


layout(set = 0, binding = 5, std140) uniform Params {
	mat4 inv_projection; // 0
	mat4 camera; // 64, camera to world
	vec4 box_min; // 128, xyz, w = voxel size
	vec4 box_size; // 144, xyz, w = max steps
	vec4 sun; // 160, xyz = towards the sun, w = wrap
	vec4 sun_color; // 176, rgb = linear colour * energy, w = rim strength
	vec4 shape; // 192, x = softness, y = extinction, z = noise strength, w = noise scale
	vec4 march; // 208, x = inside step, y = step growth per m, z = edge fade, w = min skip
	vec4 fade_color; // 224, rgb linear, w = fade amount at the end distance
	vec4 fade; // 240, x = start, y = end, z = frame, w = detail noise strength (fraction of noise strength)
	vec4 shading; // 256, x = sun shadow strength, y = sky shadow strength, z = banding, w = rim power
	ivec4 screen; // 272, xy = size
	// Tiles (PaintedCloudTileWorld): volume_texture is then an atlas of grid x grid tiles, each cell in
	// the slot (cell mod grid), with a one voxel border on x and z.
	vec4 tile_a; // 288, x = cell size, y = voxel size, z = floor y, w = grid (0 = one bake, box_min/box_size)
	vec4 tile_b; // 304, xyz = one tile's voxels (with its border), w = floating origin offset (cells) on x, mod grid
	vec4 atlas_dims; // 320, xyz = the atlas's voxels, w = floating origin offset (cells) on z, mod grid
	ivec4 slots[9]; // 336, per slot (x + z * grid): xy = the local cell in it, z = 1 when baked
	vec4 panorama_range; // 480, x = the panoramas' lat_min (radians), yzw = the floating origin's offset (m), so the noise stays put in the world when it shifts
	ivec4 near_cells; // 496, x = the near cells drawn (mask) with panorama a, y = with b, zw = the first cell (local)
	vec4 far; // 512, x = 1 with distant clouds, y = how far faded from panorama a to b, z = their lat_max (radians), w = 1 to correct parallax
	vec4 panorama_centre_a; // 528, xyz = where panorama a was painted from
	vec4 panorama_centre_b; // 544, xyz = where panorama b was painted from
	vec4 near_cells_b; // 560, xy = the near cells' box (cells), z = the band (m) inside their edge where they hand over, w = how far faded from a's cells to b's
	vec4 wisp_centre; // 576, xyz = the wisp's centre, w = its radius (m)
	vec4 wisp; // 592, x = its height / width, y = how thick (0 = none), z = 1 to measure the distant clouds on screen, w = from how far (m, horizontally) clouds count as distant
	vec4 wisp_puffs[8]; // 608, per puff: offset from the wisp's centre (m), radius (m; 0 = unused)
} params;

const float PI = 3.14159265359;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 to_uvw(vec3 p) {
	return (p - params.box_min.xyz) / params.box_size.xyz;
}

// The baked field at p: r = signed distance (m), g = sun, b = sky, a = noise scale. From the one
// bake, or the tile holding p (clear air where none is baked yet).
vec4 coarse_field(vec3 p) {
	if (params.tile_a.w < 0.5) {
		return texture(volume_texture, to_uvw(p));
	}
	float cell_size = params.tile_a.x;
	float n = params.tile_a.w;
	vec2 cell = floor(p.xz / cell_size);
	// Tiles sit in the slot of their absolute cell (local cell + the floating origin's offset).
	vec2 absolute = cell + vec2(params.tile_b.w, params.atlas_dims.w);
	vec2 slot = absolute - n * floor(absolute / n);
	ivec4 s = params.slots[int(slot.x + slot.y * n)];
	if (s.z == 0 || s.x != int(cell.x) || s.y != int(cell.y)) {
		return vec4(1e4, 1.0, 1.0, 1.0);
	}
	// In voxels, centres at i + 0.5, past the tile's one voxel border.
	vec3 local = vec3(p.x - cell.x * cell_size, p.y - params.tile_a.z, p.z - cell.y * cell_size) / params.tile_a.y + vec3(1.0, 0.0, 1.0);
	local = clamp(local, vec3(0.5), params.tile_b.xyz - 0.5);
	vec3 coord = local + vec3(slot.x * params.tile_b.x, 0.0, slot.y * params.tile_b.z);
	return texture(volume_texture, coord / params.atlas_dims.xyz);
}

// The wisp (put on the camera's path to hide a panorama swap): a cluster of soft puffs blended
// together, squashed to its height. A lower bound on the distance to it (m).
float wisp_sdf(vec3 p) {
	vec3 q = (p - params.wisp_centre.xyz) / vec3(1.0, params.wisp.x, 1.0);
	float k = 0.175 * params.wisp_centre.w;
	float d = 1e9;
	for (int i = 0; i < 8; i++) {
		vec4 puff = params.wisp_puffs[i];
		if (puff.w <= 0.0) {
			break;
		}
		float di = length(q - puff.xyz) - puff.w;
		// Smooth union, so the puffs swell into one another.
		float h = clamp(0.5 + 0.5 * (di - d) / k, 0.0, 1.0);
		d = mix(di, d, h) - k * h * (1.0 - h);
	}
	return d * min(1.0, params.wisp.x);
}

// The field at p: the tiles (or the one bake), and the wisp while it flies, lit softly (it isn't
// baked, so it takes nearly full sun and sky light).
vec4 field(vec3 p) {
	vec4 f = coarse_field(p);
	if (params.wisp.y > 0.0) {
		float w = wisp_sdf(p);
		if (w < f.r) {
			f = vec4(w, 0.85, 0.9, 1.0);
		}
	}
	return f;
}

float sdf_at(vec3 p) {
	return field(p).r;
}

// The surface normal: the distance field's gradient, from four taps.
vec3 sdf_normal(vec3 p) {
	float e = params.box_min.w * 0.75;
	const vec2 k = vec2(1.0, -1.0);
	return normalize(k.xyy * sdf_at(p + k.xyy * e) + k.yyx * sdf_at(p + k.yyx * e)
			+ k.yxy * sdf_at(p + k.yxy * e) + k.xxx * sdf_at(p + k.xxx * e));
}

// 0..1 billows: bright bumps where the clouds puff out, plus a finer octave (centred on 0) for
// the smaller puffs seen up close.
float billow(vec3 p, float scale) {
	vec3 uvw = (p + params.panorama_range.yzw) / (params.shape.w * scale);
	float coarse = texture(noise_texture, uvw).r;
	float fine = texture(noise_texture, uvw * 3.7 + vec3(0.31, 0.17, 0.53)).r - 0.5;
	return coarse + fine * params.fade.w;
}

float interleaved_gradient_noise(vec2 pixel, float frame) {
	pixel += 5.588238 * mod(frame, 64.0);
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

vec2 panorama_uv(vec3 dir, out bool inside) {
	float lat = asin(clamp(dir.y, -1.0, 1.0));
	float lat_max = params.far.z;
	float lat_min = params.panorama_range.x;
	inside = lat <= lat_max && lat >= lat_min;
	return vec2(atan(dir.x, dir.z) / (2.0 * PI) + 0.5, (lat_max - lat) / (lat_max - lat_min));
}

// The distant clouds a panorama shows along the camera's ray. With parallax correction, the
// panorama's depth is treated as a surface seen from its centre: step out along the camera's ray
// (geometrically, 300 m to 300 km), and at the first point that's as far from the centre as the
// panorama's clouds are that way, the ray has reached them; refine that by bisection, and look
// them up from the centre in that direction. Unlike re-projecting by the depth straight ahead,
// silhouettes keep their shape as the camera moves (the sky beside a cloud doesn't drag its edge).
const int PARALLAX_STEPS = 28;
const int PARALLAX_REFINE = 5;

// Whether q is inside a cloud, for the clouds the near tiles hold (clear air elsewhere).
bool inside_cloud(vec3 q) {
	return coarse_field(q).r < params.shape.x;
}

float panorama_gap(sampler2D depth, vec3 centre, vec3 q) {
	bool inside;
	vec3 v = q - centre;
	float d = length(v);
	return d - textureLod(depth, panorama_uv(v / max(d, 1e-3), inside), 0.0).r;
}

vec4 panorama_sample(sampler2D colour, sampler2D depth, vec3 centre, vec3 ro, vec3 rd, out float t) {
	bool inside;
	vec3 dir = rd;
	if (params.far.w > 0.5) {
		const float t_first = 300.0;
		const float t_last = 300000.0;
		float ratio = pow(t_last / t_first, 1.0 / float(PARALLAX_STEPS - 1));
		float t_prev = t_first;
		float gap_prev = panorama_gap(depth, centre, ro + rd * t_first);
		t = t_last;
		bool found = gap_prev >= 0.0;
		if (found) {
			t = t_first;
		}
		for (int i = 1; i < PARALLAX_STEPS && !found; i++) {
			float t_step = t_prev * ratio;
			float gap = panorama_gap(depth, centre, ro + rd * t_step);
			if (gap >= 0.0 && gap_prev < 0.0) {
				// Crossed the panorama's surface somewhere in [t_prev, t_step]: find where.
				float lo = t_prev;
				float hi = t_step;
				float gap_hi = gap;
				for (int k = 0; k < PARALLAX_REFINE; k++) {
					float mid = sqrt(lo * hi);
					float g = panorama_gap(depth, centre, ro + rd * mid);
					if (g >= 0.0) {
						hi = mid;
						gap_hi = g;
					} else {
						lo = mid;
					}
				}
				// A real surface: the ray meets it (the gap closes to nothing). Otherwise it jumped
				// at a silhouette, the ray passing behind a nearer cloud's edge (what the panorama
				// couldn't see from its centre): carry on to whatever is further out.
				if (gap_hi < 800.0 + 0.04 * hi) {
					t = hi;
					found = true;
				}
			}
			if (!found && gap >= 0.0 && inside_cloud(ro + rd * t_step)) {
				// Behind what the panorama saw, but inside a cloud (one the near tiles hold, entered
				// from a side the panorama's centre couldn't see): the ray has reached it.
				t = t_step;
				found = true;
			}
			t_prev = t_step;
			gap_prev = gap;
		}
		dir = normalize(ro + rd * t - centre);
	} else {
		t = textureLod(depth, panorama_uv(rd, inside), 0.0).r;
	}
	vec2 uv = panorama_uv(dir, inside);
	return inside ? textureLod(colour, uv, 0.0) : vec4(0.0, 0.0, 0.0, 1.0);
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

// How much of the clouds at p the near tiles draw (cross-fading between panorama a's near cells
// and b's as b fades in).
float near_weight(vec3 p) {
	ivec2 span = ivec2(params.near_cells_b.xy);
	float wa = near_cells_weight(p.xz, params.near_cells.x, params.near_cells.zw, span, params.tile_a.x, params.near_cells_b.z);
	if (params.near_cells_b.w <= 0.0) {
		return wa;
	}
	float wb = near_cells_weight(p.xz, params.near_cells.y, params.near_cells.zw, span, params.tile_a.x, params.near_cells_b.z);
	return mix(wa, wb, params.near_cells_b.w);
}

bool box_hit(vec3 ro, vec3 rd, out float t0, out float t1) {
	vec3 inv = 1.0 / rd;
	vec3 a = (params.box_min.xyz - ro) * inv;
	vec3 b = (params.box_min.xyz + params.box_size.xyz - ro) * inv;
	vec3 lo = min(a, b);
	vec3 hi = max(a, b);
	t0 = max(max(lo.x, lo.y), max(lo.z, 0.0));
	t1 = min(min(hi.x, hi.y), hi.z);
	return t0 < t1;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.screen.xy))) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.screen.xy);
	float depth = texture(depth_texture, uv).r;
	vec2 ndc = uv * 2.0 - 1.0;
	// Reverse Z: the near plane is at 1, the sky at 0.
	vec4 near_view = params.inv_projection * vec4(ndc, 1.0, 1.0);
	vec3 view_dir = normalize(near_view.xyz / near_view.w);
	vec3 rd = normalize(mat3(params.camera) * view_dir);
	vec3 ro = params.camera[3].xyz;
	float scene_distance = 1e30;
	if (depth > 0.0) {
		vec4 scene_view = params.inv_projection * vec4(ndc, depth, 1.0);
		scene_distance = length(scene_view.xyz / scene_view.w);
	}

	float t0, t1;
	float window_exit = 0.0;
	if (box_hit(ro, rd, t0, t1)) {
		window_exit = t1;
		t1 = min(t1, scene_distance);
	} else {
		// Misses the near tiles (e.g. from above them): no near march, but the distant clouds may
		// still be there.
		t0 = 0.0;
		t1 = 0.0;
	}
	if (t0 >= t1 && params.far.x < 0.5) {
		imageStore(cloud_image, pixel, vec4(0.0));
		return;
	}

	vec3 sun_dir = normalize(params.sun.xyz);
	float softness = params.shape.x;
	float noise_strength = params.shape.z;
	float reach_noise = noise_strength * (1.0 + 0.5 * params.fade.w);
	vec3 box_max = params.box_min.xyz + params.box_size.xyz;
	float sun_forward = pow(max(dot(rd, sun_dir), 0.0), 4.0);
	float jitter = interleaved_gradient_noise(vec2(pixel), params.fade.z);

	vec3 color = vec3(0.0);
	float transmittance = 1.0;
	float distant_seen = 0.0; // How much of this pixel shows distant clouds (for hidden swaps).
	float t = t0;
	bool jittered = false;
	int max_steps = int(params.box_size.w);
	for (int i = 0; i < max_steps && t < t1; i++) {
		vec3 p = ro + rd * t;
		vec4 voxel = field(p);
		float sdf = voxel.r;
		float scale = max(voxel.a, 0.05);
		float reach = reach_noise * scale + softness;
		if (sdf > reach) {
			// Clear air: jump the distance that's certainly empty.
			t += max(sdf - reach, params.march.w);
			continue;
		}
		float step_length = params.march.x * (1.0 + t * params.march.y);
		if (!jittered) {
			// Offset the fine steps per pixel, so their slices don't band.
			jittered = true;
			t += step_length * jitter;
			p = ro + rd * t;
			voxel = field(p);
			sdf = voxel.r;
			scale = max(voxel.a, 0.05);
		}
		float d = sdf - noise_strength * scale * billow(p, scale);
		if (d > softness) {
			// Near a cloud but outside its soft edge: step towards it.
			t += max(step_length, (d - softness) * 0.6);
			continue;
		}
		// Tiles: only the near cells drawn, handing over to the panorama inside their edge. One bake:
		// thin out at the box's sides so it never shows as a wall.
		float edge_fade;
		if (params.wisp.y > 0.0 && wisp_sdf(p) <= coarse_field(p).r) {
			edge_fade = params.wisp.y; // The wisp: wherever it is.
		} else if (params.tile_a.w > 0.5) {
			edge_fade = near_weight(p);
		} else {
			vec2 edge = min(p.xz - params.box_min.xz, box_max.xz - p.xz);
			edge_fade = clamp(min(edge.x, edge.y) / max(params.march.z, 1.0), 0.0, 1.0);
		}
		float density = clamp(0.5 - d / (2.0 * softness), 0.0, 1.0) * edge_fade;
		if (density > 0.002) {
			vec3 n = sdf_normal(p);
			// Lit side: how much the surface faces the sun, wrapped round the edges.
			float wrap = params.sun.w;
			float lit = clamp((dot(n, sun_dir) + wrap) / (1.0 + wrap), 0.0, 1.0);
			lit *= mix(1.0, voxel.g, params.shading.x);
			lit *= mix(1.0, voxel.b, params.shading.y);
			// Soft banding: an S-curve towards the painted look.
			lit = mix(lit, lit * lit * (3.0 - 2.0 * lit), params.shading.z);
			vec3 sample_color = srgb_to_linear(texture(gradient_texture, vec2(lit, 0.5)).rgb) * params.sun_color.rgb;
			// Silver lining: edges seen against the sun.
			float rim = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), params.shading.w);
			sample_color += params.sun_color.rgb * rim * params.sun_color.w * (0.2 + sun_forward) * voxel.g;
			// Fade into the haze with distance.
			float haze = smoothstep(params.fade.x, params.fade.y, t) * params.fade_color.w;
			sample_color = mix(sample_color, params.fade_color.rgb, haze);

			float alpha = 1.0 - exp(-density * params.shape.y * step_length);
			if (length(p.xz - ro.xz) > params.wisp.w) {
				distant_seen += transmittance * alpha;
			}
			color += transmittance * alpha * sample_color;
			transmittance *= 1.0 - alpha;
			if (transmittance < 0.01) {
				transmittance = 0.0;
				break;
			}
		}
		t += step_length;
	}

	// The distant clouds (outside the near cells, so behind the near ones), where their
	// re-projected position puts them, unless the scene is in front.
	if (params.far.x > 0.5 && transmittance > 0.0) {
		float t_a;
		vec4 distant = panorama_sample(panorama_a, panorama_depth_a, params.panorama_centre_a.xyz, ro, rd, t_a);
		float t_hit = t_a;
		if (params.far.y > 0.0) {
			float t_b;
			distant = mix(distant, panorama_sample(panorama_b, panorama_depth_b, params.panorama_centre_b.xyz, ro, rd, t_b), params.far.y);
			t_hit = mix(t_a, t_b, params.far.y);
		}
		if (t_hit < scene_distance) {
			distant_seen += transmittance * (1.0 - distant.a);
			color += transmittance * distant.rgb;
			transmittance *= distant.a;
		}
	}
	if (params.wisp.z > 0.5 && (pixel.x & 3) == 0 && (pixel.y & 3) == 0) {
		atomicAdd(coverage_sum, uint(clamp(distant_seen, 0.0, 1.0) * 255.0 + 0.5));
		atomicAdd(coverage_count, 1u);
	}

	if (transmittance >= 1.0) {
		imageStore(cloud_image, pixel, vec4(0.0));
		return;
	}
	imageStore(cloud_image, pixel, vec4(color, 1.0 - transmittance));
}
