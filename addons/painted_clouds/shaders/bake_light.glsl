#[compute]
#version 450

// Bake pass 2: for each voxel, how much sunlight and sky light reach it through the clouds,
// marched through the distance field from pass 1. The field can cover a bigger box than the
// output (a margin round a tile), so clouds just outside still cast their shadows in.
// Writes r = signed distance (m), g = sun transmittance, b = sky transmittance, a = noise scale.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0) uniform sampler3D sdf_texture;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image3D out_texture;

layout(push_constant, std430) uniform Params {
	vec4 origin_voxel; // xyz = output box minimum corner, w = voxel size
	ivec4 dims; // xyz = output voxels, w = first z slice of this dispatch
	vec4 sun; // xyz = towards the sun, w = march distance
	vec4 misc; // x = softness, y = extinction, z = steps, w = sky march distance
	vec4 sdf_origin; // xyz = the field's box minimum corner
	ivec4 sdf_dims; // xyz = the field's voxels
} pc;

float sdf_at(vec3 p) {
	vec3 uvw = (p - pc.sdf_origin.xyz) / (vec3(pc.sdf_dims.xyz) * pc.origin_voxel.w);
	if (any(lessThan(uvw, vec3(0.0))) || any(greaterThan(uvw, vec3(1.0)))) {
		return 1e4; // Clear air outside the field.
	}
	return texture(sdf_texture, uvw).r;
}

float density_at(vec3 p) {
	return clamp(0.5 - sdf_at(p) / (2.0 * pc.misc.x), 0.0, 1.0);
}

float transmittance(vec3 p, vec3 direction, float distance_total) {
	int steps = max(int(pc.misc.z), 1);
	float step_length = distance_total / float(steps);
	float optical_depth = 0.0;
	for (int i = 0; i < steps; i++) {
		// Steps grow away from the voxel: near detail matters most.
		float t = (float(i) + 0.5) / float(steps);
		optical_depth += density_at(p + direction * t * t * distance_total) * step_length * 2.0 * t;
	}
	return exp(-optical_depth * pc.misc.y);
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID) + ivec3(0, 0, pc.dims.w);
	if (any(greaterThanEqual(id, pc.dims.xyz))) {
		return;
	}
	vec3 p = pc.origin_voxel.xyz + (vec3(id) + 0.5) * pc.origin_voxel.w;
	ivec3 margin = ivec3(round((pc.origin_voxel.xyz - pc.sdf_origin.xyz) / pc.origin_voxel.w));
	vec4 field = texelFetch(sdf_texture, id + margin, 0);
	float sun = transmittance(p, normalize(pc.sun.xyz), pc.sun.w);
	float sky = transmittance(p, vec3(0.0, 1.0, 0.0), pc.misc.w);
	imageStore(out_texture, id, vec4(field.r, sun, sky, field.a));
}
