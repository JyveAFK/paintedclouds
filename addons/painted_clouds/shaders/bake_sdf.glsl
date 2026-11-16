#[compute]
#version 450

// Bake pass 1: the signed distance (m) from each voxel's centre to the clouds, every cloud's
// primitives (squashed capsules cut off at a floor) merged with a smooth union. Clouds whose
// bounding sphere is further than the nearest surface found so far (plus the blend) are skipped
// (big clouds, such as sheets, arrive split into spatial chunks, each with its own sphere).
// Alpha carries the clouds' noise scale, blended as their shapes are.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict writeonly image3D out_texture;

// Per primitive, 3 vec4: a (xyz), radius (w); b (xyz), squash (w); floor y (x), noise scale (y).
layout(set = 0, binding = 1, std430) restrict readonly buffer Primitives {
	vec4 primitives[];
};

// Per cloud, 2 vec4: bounding sphere centre (xyz), radius (w); first primitive (x), count (y).
layout(set = 0, binding = 2, std430) restrict readonly buffer Clouds {
	vec4 clouds[];
};

layout(push_constant, std430) uniform Params {
	vec4 origin_voxel; // xyz = box minimum corner, w = voxel size
	ivec4 dims; // xyz = voxels, w = first z slice of this dispatch
	vec4 misc; // x = blend, y = cloud count, z = max distance
} pc;


float capsule(vec3 p, vec3 a, vec3 b, float r) {
	vec3 pa = p - a;
	vec3 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
	return length(pa - ba * h) - r;
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID) + ivec3(0, 0, pc.dims.w);
	if (any(greaterThanEqual(id, pc.dims.xyz))) {
		return;
	}
	vec3 p = pc.origin_voxel.xyz + (vec3(id) + 0.5) * pc.origin_voxel.w;
	float k = pc.misc.x;
	float d = pc.misc.z;
	// The noise scale of the clouds here, blended as their shapes are.
	float noise_scale = 1.0;
	int cloud_count = int(pc.misc.y);
	for (int c = 0; c < cloud_count; c++) {
		vec4 bound = clouds[c * 2];
		if (distance(p, bound.xyz) - bound.w > d + k) {
			continue;
		}
		vec4 range = clouds[c * 2 + 1];
		int first = int(range.x);
		int count = int(range.y);
		for (int i = first; i < first + count; i++) {
			vec4 a = primitives[i * 3];
			vec4 b = primitives[i * 3 + 1];
			vec4 extra = primitives[i * 3 + 2];
			float floor_y = extra.x;
			// Squash vertically about a: stretch the space instead, then scale the distance back
			// (a conservative distance, as squash <= 1).
			float squash = max(b.w, 0.01);
			vec3 q = p;
			q.y = a.y + (p.y - a.y) / squash;
			vec3 bb = b.xyz;
			bb.y = a.y + (b.y - a.y) / squash;
			float pd = capsule(q, a.xyz, bb, a.w) * squash;
			pd = max(pd, floor_y - p.y);
			// Smooth union, carrying the noise scale along with the blend.
			float h = clamp(0.5 + 0.5 * (d - pd) / k, 0.0, 1.0);
			d = mix(d, pd, h) - k * h * (1.0 - h);
			noise_scale = mix(noise_scale, extra.y, h);
		}
	}
	imageStore(out_texture, id, vec4(min(d, pc.misc.z), 0.0, 0.0, noise_scale));
}
