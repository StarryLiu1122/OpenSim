shader_type spatial;
uniform vec4 tint : source_color = vec4(1.0);
uniform int surface_kind = 0;
varying vec3 world_position;
varying vec3 world_normal;
float grain(vec3 p) { return fract(sin(dot(floor(p), vec3(12.9898, 78.233, 39.425))) * 43758.5453); }
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
	vec3 p = world_position;
	float noise = grain(p * 12.0);
	vec3 color = tint.rgb;
	ROUGHNESS = 0.8;
	if (surface_kind == 1) { color *= 0.86 + noise * 0.20; }
	if (surface_kind == 2) {
		vec2 uv = abs(world_normal.z) > abs(world_normal.x) ? p.xy : p.zy;
		if (abs(world_normal.y) > 0.7) { uv = p.xz; }
		float row = floor(uv.y / 0.22);
		vec2 brick = fract(vec2(uv.x / 0.48 + mod(row, 2.0) * 0.5, uv.y / 0.22));
		vec2 edge = min(brick, 1.0 - brick);
		float mortar = 1.0 - smoothstep(0.025, 0.05, min(edge.x, edge.y));
		color = mix(color * (0.85 + 0.22 * noise), vec3(0.48, 0.46, 0.41), mortar);
	}
	if (surface_kind == 3) {
		float wood = sin(p.x * 28.0 + sin(p.z * 2.5) * 2.0 + sin(p.y * 3.0));
		color *= 0.82 + 0.12 * wood + noise * 0.1;
	}
	if (surface_kind == 5) { color *= 0.72 + noise * 0.35; }
	if (surface_kind == 4) { METALLIC = 0.65; ROUGHNESS = 0.32; }
	ALBEDO = color;
}
