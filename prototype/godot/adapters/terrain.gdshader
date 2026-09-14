shader_type spatial;
render_mode cull_disabled;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 low = vec3(0.30, 0.44, 0.38);
	vec3 high = vec3(0.56, 0.65, 0.48);
	vec3 ground = mix(low, high, smoothstep(0.0, 12.0, world_position.y));
	vec2 cell = world_position.xz / 4.0;
	vec2 grid = abs(fract(cell - 0.5) - 0.5) / max(fwidth(cell), vec2(0.0001));
	float line = 1.0 - min(min(grid.x, grid.y), 1.0);
	float distance_fade = 1.0 - smoothstep(65.0, 150.0, length(VERTEX));
	ALBEDO = mix(ground, ground + vec3(0.10), line * 0.26 * distance_fade);
	ROUGHNESS = 0.95;
}
