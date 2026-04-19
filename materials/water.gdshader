shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.35, 0.68, 0.72, 1.0);
uniform vec4 deep_color : source_color = vec4(0.02, 0.12, 0.22, 1.0);
uniform vec4 foam_color : source_color = vec4(0.92, 0.97, 1.0, 1.0);
uniform float depth_distance : hint_range(0.1, 20.0) = 3.2;
uniform float shore_fade : hint_range(0.05, 6.0) = 1.0;
uniform float foam_edge : hint_range(0.01, 4.0) = 0.7;
uniform float foam_intensity : hint_range(0.0, 3.0) = 1.1;
uniform float metallic_amount : hint_range(0.0, 1.0) = 0.1;
uniform float roughness_amount : hint_range(0.0, 1.0) = 0.08;
uniform float wave_amplitude : hint_range(0.0, 0.5) = 0.035;
uniform float wave_speed : hint_range(0.0, 3.0) = 0.35;
uniform vec2 flow_direction_a = vec2(0.08, 0.05);
uniform vec2 flow_direction_b = vec2(-0.05, 0.09);
uniform float normal_scale_a : hint_range(0.1, 12.0) = 2.2;
uniform float normal_scale_b : hint_range(0.1, 12.0) = 4.5;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.75;
uniform float fresnel_power : hint_range(0.1, 8.0) = 3.5;
uniform float alpha_min : hint_range(0.0, 1.0) = 0.72;
uniform float alpha_max : hint_range(0.0, 1.0) = 0.95;

const vec3 NORMAL_DEFAULT = vec3(0.5, 0.5, 1.0);

// Cheap value noise for procedural ripples (no texture needed).
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

vec3 sample_ripple_normal(vec2 uv, float t) {
	vec2 p = uv;
	float e = 0.05;
	float n1 = value_noise(p + flow_direction_a * t);
	float n2 = value_noise(p + vec2(e, 0.0) + flow_direction_a * t);
	float n3 = value_noise(p + vec2(0.0, e) + flow_direction_a * t);
	vec3 n = normalize(vec3(n1 - n2, n1 - n3, e));
	return n;
}

void vertex() {
	float t = TIME * wave_speed;
	vec2 wuv = VERTEX.xz * 0.25;
	float h = value_noise(wuv + flow_direction_a * t)
		+ value_noise(wuv * 2.3 + flow_direction_b * t * 1.3) * 0.5;
	VERTEX.y += (h - 0.75) * wave_amplitude;
}

void fragment() {
	float t = TIME * wave_speed;
	vec2 uv_a = UV * normal_scale_a + flow_direction_a * t;
	vec2 uv_b = UV * normal_scale_b + flow_direction_b * t;
	vec3 n_a = sample_ripple_normal(uv_a, t);
	vec3 n_b = sample_ripple_normal(uv_b, t * 1.4);
	vec3 ripple_n = normalize(mix(NORMAL_DEFAULT, n_a * 0.5 + n_b * 0.5 + 0.5, normal_strength));
	NORMAL_MAP = ripple_n;

	float scene_depth = textureLod(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	view.xyz /= view.w;
	float surface_depth = -view.z + VERTEX.z;
	float depth_blend = clamp(surface_depth / depth_distance, 0.0, 1.0);
	float shore_mask = 1.0 - clamp(surface_depth / shore_fade, 0.0, 1.0);

	vec3 albedo = mix(shallow_color.rgb, deep_color.rgb, depth_blend);

	// Procedural foam: bright at shore and on wave crests.
	float crest = smoothstep(0.55, 0.9, value_noise(UV * 6.0 + flow_direction_a * t * 2.0));
	float foam = clamp(shore_mask * foam_intensity + crest * shore_mask * 0.8, 0.0, 1.0);
	foam *= smoothstep(foam_edge + 0.25, foam_edge - 0.05, surface_depth);
	albedo = mix(albedo, foam_color.rgb, foam);

	// Fresnel edge shine.
	vec3 view_dir = normalize(VIEW);
	float fres = pow(1.0 - clamp(dot(view_dir, NORMAL), 0.0, 1.0), fresnel_power);

	ALBEDO = albedo;
	METALLIC = metallic_amount;
	ROUGHNESS = max(roughness_amount, 1.0 - fres);
	SPECULAR = 0.6;
	EMISSION = foam_color.rgb * foam * 0.15;
	ALPHA = mix(alpha_min, alpha_max, max(depth_blend, foam));
}
