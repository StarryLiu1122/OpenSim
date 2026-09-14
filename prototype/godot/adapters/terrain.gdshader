shader_type spatial;
render_mode cull_disabled;
uniform float water_height = -100.0;
uniform bool show_grid = false;
varying vec3 world_position;
varying vec3 world_normal;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 cell = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(cell), hash(cell + vec2(1,0)), f.x), mix(hash(cell + vec2(0,1)), hash(cell + vec2(1,1)), f.x), f.y);
}
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
	vec3 p = world_position;
	float patches = noise(p.xz * 0.17) * 0.6 + noise(p.xz * 1.3) * 0.4;
	float grain = noise(p.xz * 5.0);
	vec3 grass = mix(vec3(0.17,0.24,0.09), vec3(0.37,0.41,0.19), patches) * (0.94 + grain * 0.12);
	vec3 sand = mix(vec3(0.48,0.42,0.28), vec3(0.68,0.60,0.43), grain);
	vec3 ground = mix(sand, grass, smoothstep(water_height + 0.15, water_height + 0.9, p.y));
	float slope = 1.0 - abs(world_normal.y);
	ground = mix(ground, vec3(0.39,0.39,0.34) * (0.8 + grain * 0.3), smoothstep(0.1, 0.4, slope));
	if (show_grid) {
		vec2 uv = p.xz / 4.0;
		vec2 grid = abs(fract(uv - 0.5) - 0.5) / max(fwidth(uv), vec2(0.0001));
		float line = (1.0 - min(min(grid.x, grid.y), 1.0)) * (1.0 - smoothstep(65.0,150.0,length(VERTEX)));
		ground += vec3(line * 0.22);
	}
	ALBEDO = ground;
	ROUGHNESS = 0.94;
}
