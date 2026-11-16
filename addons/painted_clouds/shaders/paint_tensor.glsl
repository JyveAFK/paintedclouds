#[compute]
#version 450

// For the anisotropic Kuwahara filter: the cloud layer's structure tensor (which way its shapes
// run, and how strongly) from Sobel gradients of its brightness and coverage, lightly blurred.
// Writes (E, F, G) = (gx*gx, gx*gy, gy*gy).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D cloud_texture;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2D tensor_image;

layout(push_constant, std430) uniform Params {
	ivec4 size; // xy = pixels
} pc;

float value_at(ivec2 p) {
	vec4 c = texelFetch(cloud_texture, clamp(p, ivec2(0), pc.size.xy - 1), 0);
	return dot(c.rgb, vec3(0.299, 0.587, 0.114)) + c.a * 0.5;
}

vec3 tensor_at(ivec2 p) {
	float tl = value_at(p + ivec2(-1, -1)), t = value_at(p + ivec2(0, -1)), tr = value_at(p + ivec2(1, -1));
	float l = value_at(p + ivec2(-1, 0)), r = value_at(p + ivec2(1, 0));
	float bl = value_at(p + ivec2(-1, 1)), b = value_at(p + ivec2(0, 1)), br = value_at(p + ivec2(1, 1));
	float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
	float gy = (bl + 2.0 * b + br) - (tl + 2.0 * t + tr);
	return vec3(gx * gx, gx * gy, gy * gy);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, pc.size.xy))) {
		return;
	}
	// A small blur (a 3x3 of every other pixel) steadies the directions.
	vec3 sum = vec3(0.0);
	float weight = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float w = (x == 0 && y == 0) ? 4.0 : ((x == 0 || y == 0) ? 2.0 : 1.0);
			sum += tensor_at(pixel + ivec2(x, y) * 2) * w;
			weight += w;
		}
	}
	imageStore(tensor_image, pixel, vec4(sum / weight, 0.0));
}
