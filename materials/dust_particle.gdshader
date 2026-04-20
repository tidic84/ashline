shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.96, 0.86, 1.0);
uniform float softness : hint_range(0.05, 4.0) = 1.6;
uniform float emission_strength : hint_range(0.0, 8.0) = 0.6;

void vertex() {
	// Face the camera (billboard in view space).
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0)
	);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = dot(p, p);
	float alpha = pow(clamp(1.0 - d, 0.0, 1.0), softness);
	ALBEDO = color.rgb;
	EMISSION = color.rgb * emission_strength * alpha;
	ALPHA = alpha * COLOR.a * color.a;
}
