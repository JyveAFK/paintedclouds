#[compute]
#version 450

// The paint filters, on the cloud layer only (rgb = premultiplied colour, a = coverage), then the
// composite over the scene. In order, each mixed in by its strength (0 = off):
//   Kuwahara (classic, or anisotropic: strokes that follow the clouds' shapes), hue-shifted
//   shadows and lights, watercolour edge darkening, soft ink outlines, rim bloom, canvas grain.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D cloud_texture;
// (E, F, G) structure tensor, for the anisotropic Kuwahara.
layout(set = 0, binding = 2) uniform sampler2D tensor_texture;

layout(set = 0, binding = 3, std140) uniform Params {
	ivec4 size; // 0, xy = pixels, z = Kuwahara mode (0 off, 1 classic, 2 anisotropic)
	vec4 kuwahara; // 16, x = radius (px), y = strength, z = sharpness, w = anisotropy
	vec4 watercolor; // 32, x = strength, y = width (px)
	vec4 grain; // 48, x = strength, y = scale (px)
	vec4 ink; // 64, x = strength, y = width (px), z = interior lines strength
	vec4 ink_color; // 80, rgb linear
	vec4 hue; // 96, x = strength
	vec4 shadow_tint; // 112, rgb
	vec4 light_tint; // 128, rgb
	vec4 bloom; // 144, x = strength, y = threshold (brightness), z = radius (px)
} params;

vec4 cloud_at(vec2 p) {
	return textureLod(cloud_texture, (p + 0.5) / vec2(params.size.xy), 0.0);
}

float luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Classic Kuwahara: of the four square quadrants round p, the mean of the one that varies least.
vec4 kuwahara_classic(vec2 p, int r) {
	vec4 best = vec4(0.0);
	float best_variance = 1e30;
	for (int q = 0; q < 4; q++) {
		ivec2 dir = ivec2((q & 1) == 0 ? -1 : 1, (q & 2) == 0 ? -1 : 1);
		vec4 sum = vec4(0.0);
		vec3 sum_sq = vec3(0.0);
		float n = 0.0;
		for (int y = 0; y <= r; y++) {
			for (int x = 0; x <= r; x++) {
				vec4 c = cloud_at(p + vec2(x * dir.x, y * dir.y));
				sum += c;
				sum_sq += c.rgb * c.rgb;
				n += 1.0;
			}
		}
		vec4 mean = sum / n;
		vec3 variance = abs(sum_sq / n - mean.rgb * mean.rgb);
		float v = variance.r + variance.g + variance.b;
		if (v < best_variance) {
			best_variance = v;
			best = mean;
		}
	}
	return best;
}

// Anisotropic Kuwahara (Kyprianidis et al., with polynomial sector weights): an ellipse stretched
// along the local structure, split into 8 sectors, each sector's mean weighted by how little it
// varies.
vec4 kuwahara_anisotropic(vec2 p, float radius) {
	vec3 t = vec3(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			t += textureLod(tensor_texture, (p + vec2(x, y) + 0.5) / vec2(params.size.xy), 0.0).xyz;
		}
	}
	t /= 9.0;
	float root = sqrt((t.x - t.z) * (t.x - t.z) + 4.0 * t.y * t.y);
	float l1 = 0.5 * (t.x + t.z + root);
	float l2 = 0.5 * (t.x + t.z - root);
	vec2 v = vec2(l1 - t.x, -t.y);
	vec2 dir = length(v) > 1e-6 ? normalize(v) : vec2(0.0, 1.0);
	float phi = -atan(dir.y, dir.x);
	float anisotropy = (l1 + l2 > 1e-6) ? (l1 - l2) / (l1 + l2) : 0.0;
	float alpha = max(params.kuwahara.w, 0.01);
	float a = radius * clamp((alpha + anisotropy) / alpha, 0.1, 2.0);
	float b = radius * clamp(alpha / (alpha + anisotropy), 0.1, 2.0);
	float cos_phi = cos(phi);
	float sin_phi = sin(phi);
	mat2 R = mat2(cos_phi, -sin_phi, sin_phi, cos_phi);
	mat2 S = mat2(0.5 / a, 0.0, 0.0, 0.5 / b);
	mat2 SR = S * R;
	int max_x = min(int(sqrt(a * a * cos_phi * cos_phi + b * b * sin_phi * sin_phi)), 12);
	int max_y = min(int(sqrt(a * a * sin_phi * sin_phi + b * b * cos_phi * cos_phi)), 12);

	float zeta = 2.0 / max(radius, 1.0);
	float zero_crossing = 0.58;
	float sin_zero = sin(zero_crossing);
	float eta = (zeta + cos(zero_crossing)) / (sin_zero * sin_zero);
	vec4 m[8];
	vec3 s[8];
	float ws[8];
	for (int k = 0; k < 8; k++) {
		m[k] = vec4(0.0);
		s[k] = vec3(0.0);
		ws[k] = 0.0;
	}
	for (int y = -max_y; y <= max_y; y++) {
		for (int x = -max_x; x <= max_x; x++) {
			vec2 o = SR * vec2(x, y);
			if (dot(o, o) > 0.25) {
				continue;
			}
			vec4 c = cloud_at(p + vec2(x, y));
			float w[8];
			float sum = 0.0;
			float vxx = zeta - eta * o.x * o.x;
			float vyy = zeta - eta * o.y * o.y;
			float z = max(0.0, o.y + vxx); w[0] = z * z; sum += w[0];
			z = max(0.0, -o.x + vyy); w[2] = z * z; sum += w[2];
			z = max(0.0, -o.y + vxx); w[4] = z * z; sum += w[4];
			z = max(0.0, o.x + vyy); w[6] = z * z; sum += w[6];
			vec2 d = 0.70710678 * vec2(o.x - o.y, o.x + o.y);
			vxx = zeta - eta * d.x * d.x;
			vyy = zeta - eta * d.y * d.y;
			z = max(0.0, d.y + vxx); w[1] = z * z; sum += w[1];
			z = max(0.0, -d.x + vyy); w[3] = z * z; sum += w[3];
			z = max(0.0, -d.y + vxx); w[5] = z * z; sum += w[5];
			z = max(0.0, d.x + vyy); w[7] = z * z; sum += w[7];
			float g = exp(-3.125 * dot(o, o)) / max(sum, 1e-6);
			for (int k = 0; k < 8; k++) {
				float wk = w[k] * g;
				m[k] += c * wk;
				s[k] += c.rgb * c.rgb * wk;
				ws[k] += wk;
			}
		}
	}
	vec4 result = vec4(0.0);
	float total = 0.0;
	float q = params.kuwahara.z;
	for (int k = 0; k < 8; k++) {
		if (ws[k] <= 1e-6) {
			continue;
		}
		vec4 mean = m[k] / ws[k];
		vec3 variance = abs(s[k] / ws[k] - mean.rgb * mean.rgb);
		float sigma2 = variance.r + variance.g + variance.b;
		float w = 1.0 / (1.0 + pow(abs(1000.0 * sigma2), 0.5 * q));
		result += mean * w;
		total += w;
	}
	return total > 0.0 ? result / total : cloud_at(p);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.size.xy))) {
		return;
	}
	vec2 p = vec2(pixel);
	vec4 cloud = cloud_at(p);
	float scale = float(params.size.y) / 1080.0;

	// Anything near enough to matter? (Filters can spread the clouds a few pixels.)
	float reach = max(max(params.kuwahara.x, params.bloom.z), max(params.ink.y, params.watercolor.y)) * scale + 2.0;
	float near = cloud.a;
	near = max(near, cloud_at(p + vec2(reach, 0.0)).a);
	near = max(near, cloud_at(p - vec2(reach, 0.0)).a);
	near = max(near, cloud_at(p + vec2(0.0, reach)).a);
	near = max(near, cloud_at(p - vec2(0.0, reach)).a);
	if (near <= 0.0) {
		return; // No cloud here: the scene stays as it is.
	}

	// Kuwahara.
	int mode = params.size.z;
	if (mode != 0 && params.kuwahara.y > 0.0) {
		float radius = max(params.kuwahara.x * scale, 1.0);
		vec4 filtered = mode == 1 ? kuwahara_classic(p, int(radius + 0.5)) : kuwahara_anisotropic(p, radius);
		cloud = mix(cloud, filtered, params.kuwahara.y);
	}

	// Hue-shifted shadows and lights: shadows towards one tint, lights towards another, keeping
	// the brightness.
	if (params.hue.x > 0.0 && cloud.a > 0.001) {
		vec3 c = cloud.rgb / cloud.a;
		float l = luminance(c);
		vec3 tint = mix(params.shadow_tint.rgb, params.light_tint.rgb, smoothstep(0.15, 0.85, l / max(l + 0.5, 1e-3) * 1.5));
		vec3 shifted = c * tint;
		shifted *= l / max(luminance(shifted), 1e-4);
		cloud.rgb = mix(c, shifted, params.hue.x) * cloud.a;
	}

	// Edges of the cloud layer: how fast coverage changes across width pixels.
	vec2 edge_gradient = vec2(0.0);
	if (params.watercolor.x > 0.0 || params.ink.x > 0.0) {
		float w = max(max(params.watercolor.y, params.ink.y) * scale, 1.0);
		edge_gradient = vec2(cloud_at(p + vec2(w, 0.0)).a - cloud_at(p - vec2(w, 0.0)).a,
				cloud_at(p + vec2(0.0, w)).a - cloud_at(p - vec2(0.0, w)).a);
	}
	float edge = length(edge_gradient);

	// Watercolour edge darkening: pigment pools just inside the edges, a little deeper and richer.
	if (params.watercolor.x > 0.0 && cloud.a > 0.001) {
		float pool = smoothstep(0.05, 0.6, edge) * cloud.a;
		vec3 c = cloud.rgb / cloud.a;
		vec3 pooled = c * mix(vec3(1.0), c / max(luminance(c), 1e-3) * 0.75, 0.5) * 0.8;
		cloud.rgb = mix(c, pooled, pool * params.watercolor.x) * cloud.a;
	}

	// Soft ink outlines: on the silhouette, plus fainter lines where the shading changes sharply.
	if (params.ink.x > 0.0) {
		float line = smoothstep(0.15, 0.7, edge);
		if (params.ink.z > 0.0) {
			float w = max(params.ink.y * scale, 1.0);
			float lx = luminance(cloud_at(p + vec2(w, 0.0)).rgb) - luminance(cloud_at(p - vec2(w, 0.0)).rgb);
			float ly = luminance(cloud_at(p + vec2(0.0, w)).rgb) - luminance(cloud_at(p - vec2(0.0, w)).rgb);
			line = max(line, smoothstep(0.08, 0.3, length(vec2(lx, ly))) * params.ink.z * cloud.a);
		}
		float ink_alpha = clamp(line * params.ink.x, 0.0, 1.0);
		cloud = cloud * (1.0 - ink_alpha) + vec4(params.ink_color.rgb, 1.0) * ink_alpha;
	}

	// Rim bloom: the brightest parts (silver linings) glow a little past themselves.
	if (params.bloom.x > 0.0) {
		float r = max(params.bloom.z * scale, 1.0);
		vec3 glow = vec3(0.0);
		const int TAPS = 16;
		for (int i = 0; i < TAPS; i++) {
			// A spiral (golden angle) of taps over the disc.
			float f = (float(i) + 0.5) / float(TAPS);
			float angle = float(i) * 2.39996323;
			vec4 c = cloud_at(p + vec2(cos(angle), sin(angle)) * sqrt(f) * r);
			glow += max(c.rgb - params.bloom.y * c.a, vec3(0.0)) * (1.0 - f);
		}
		cloud.rgb += glow / float(TAPS) * 2.0 * params.bloom.x;
	}

	// Canvas grain: a fixed paper texture (fine noise plus a woven weave) over the clouds.
	if (params.grain.x > 0.0 && cloud.a > 0.0) {
		vec2 g = p / max(params.grain.y * scale, 0.25);
		float n = fract(sin(dot(floor(g), vec2(12.9898, 78.233))) * 43758.5453);
		float weave = sin(g.x * 1.7) * sin(g.y * 1.7) * 0.5;
		cloud.rgb *= 1.0 + (n - 0.5 + weave * 0.6) * 0.25 * params.grain.x;
	}

	vec4 scene = imageLoad(color_image, pixel);
	imageStore(color_image, pixel, vec4(scene.rgb * (1.0 - clamp(cloud.a, 0.0, 1.0)) + max(cloud.rgb, vec3(0.0)), scene.a));
}
