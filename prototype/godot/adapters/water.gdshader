shader_type spatial;
varying vec3 p;
void vertex() { p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float phase = p.x * 0.87 + p.z * 0.23 + sin(p.z * 0.11) + TIME * 0.8;
	float cross_wave = p.x * 0.31 - p.z * 1.43 + sin(p.x * 0.07) - TIME * 0.6;
	float ripple = sin(phase) * 0.65 + sin(cross_wave) * 0.35;
	ALBEDO = vec3(0.045, 0.18, 0.21) * (1.0 + ripple * 0.07);
	NORMAL_MAP = normalize(vec3(cos(phase) * 0.025, cos(cross_wave) * 0.018, 1.0)) * 0.5 + 0.5;
	ROUGHNESS = 0.38;
	METALLIC = 0.08;
}
