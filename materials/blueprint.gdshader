shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_prepass_alpha;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 line_color : source_color = vec4(0.55, 0.92, 1.0, 1.0);
uniform vec4 fill_color : source_color = vec4(0.05, 0.3, 0.7, 1.0);
uniform vec4 scan_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float bounds_min_y = 0.0;
uniform float bounds_size_y = 1.0;
uniform float grid_scale = 3.0;
uniform float grid_thickness = 0.04;
uniform float scan_band = 0.08;
uniform float base_alpha = 0.75;
uniform float emission_strength = 2.5;
uniform float pulse_phase = 0.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float h = (v_world.y - bounds_min_y) / max(bounds_size_y, 0.0001);
	if (h > progress) {
		discard;
	}

	// 3D world-space grid
	vec3 p = v_world * grid_scale;
	vec3 g = abs(fract(p + 0.5) - 0.5);
	float line = 1.0 - step(grid_thickness, min(min(g.x, g.y), g.z));

	// Bright scan band at the reveal front
	float scan = smoothstep(progress - scan_band, progress, h);

	vec3 col = mix(fill_color.rgb, line_color.rgb, line);
	col = mix(col, scan_color.rgb, scan * 0.9);

	// Subtle end-of-animation pulse
	float pulse = sin(pulse_phase * 6.2831) * 0.5 + 0.5;
	col += line_color.rgb * pulse * 0.25;

	ALBEDO = col;
	EMISSION = col * (emission_strength + scan * 5.0);
	ALPHA = clamp(base_alpha + scan * 0.25 + line * 0.15, 0.0, 1.0);
}
