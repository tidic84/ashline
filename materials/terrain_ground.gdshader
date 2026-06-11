shader_type spatial;

// Sol de terrain en UV monde avec anti-répétition :
// - la même texture est échantillonnée à deux échelles et mélangée par un
//   bruit basse fréquence, ce qui casse le motif visible au loin ;
// - une variation de teinte grande échelle évite l'aplat de couleur uniforme.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 albedo_tint : source_color = vec4(0.45, 0.47, 0.36, 1.0);
uniform float detail_scale = 0.45; // tuiles fines (~2,2 m)
uniform float macro_scale = 0.04; // tuiles larges pour le lointain (~25 m)
uniform float macro_blend : hint_range(0.0, 1.0) = 0.5;
uniform float normal_strength : hint_range(0.0, 4.0) = 1.6;
uniform float roughness_mult : hint_range(0.0, 2.0) = 1.0;
uniform vec4 color_variation : source_color = vec4(0.78, 0.84, 0.66, 1.0);
uniform float variation_scale = 0.012;

varying vec3 world_pos;

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash2(i), hash2(i + vec2(1.0, 0.0)), u.x),
		mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Projection planaire XZ : tangente monde +X, indépendante des UV du mesh.
	TANGENT = normalize(vec3(1.0, 0.0, 0.0) - NORMAL * NORMAL.x);
	BINORMAL = cross(NORMAL, TANGENT);
}

void fragment() {
	vec2 uv_detail = world_pos.xz * detail_scale;
	vec2 uv_macro = world_pos.xz * macro_scale + vec2(0.37, 0.71);
	float blend_noise = vnoise(world_pos.xz * 0.05);
	float blend = clamp(macro_blend * blend_noise + 0.12, 0.0, 0.85);

	vec3 albedo_detail = texture(albedo_tex, uv_detail).rgb;
	vec3 albedo_macro = texture(albedo_tex, uv_macro).rgb;
	vec3 albedo = mix(albedo_detail, albedo_macro, blend);

	float variation = vnoise(world_pos.xz * variation_scale);
	albedo *= mix(vec3(1.0), color_variation.rgb, variation * 0.7);
	ALBEDO = albedo * albedo_tint.rgb;

	vec3 normal_detail = texture(normal_tex, uv_detail).rgb;
	vec3 normal_macro = texture(normal_tex, uv_macro).rgb;
	NORMAL_MAP = mix(normal_detail, normal_macro, blend);
	NORMAL_MAP_DEPTH = normal_strength;

	AO = texture(ao_tex, uv_detail).r;
	AO_LIGHT_AFFECT = 0.0;
	ROUGHNESS = clamp(texture(rough_tex, uv_detail).r * roughness_mult, 0.0, 1.0);
	SPECULAR = 0.3;
}
