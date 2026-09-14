extends RefCounted
## One deterministic stamp; smooth reads the pre-edit field, never its own output.
const Schema = preload("res://domain/world_schema.gd")
const MAX_RAISE := 8.0

static func apply(terrain: Dictionary, payload: Dictionary) -> Dictionary:
	if not Schema.exact_keys(payload, ["mode", "center", "radius", "strength", "target_height"]):
		return {"error": "Invalid terrain brush fields."}
	if not payload.mode is String or payload.mode not in ["raise", "lower", "flatten", "smooth"]:
		return {"error": "Unknown terrain brush mode."}
	if not Schema.vector(payload.center, 2, 0, 256) or not Schema.number(payload.radius, 4, 32) or not Schema.number(payload.strength, 0.05, 1.0) or not Schema.number(payload.target_height, -40, 80):
		return {"error": "Invalid brush: center 0–256 m, radius 4–32 m, strength 0.05–1, target height -40–80 m."}
	var result: Dictionary = terrain.duplicate(true)
	var width := int(terrain.columns)
	var depth := int(terrain.rows)
	var source: Array = terrain.heights
	var changed := 0
	for y in range(depth):
		for x in range(width):
			var distance := Vector2(x * terrain.spacing, y * terrain.spacing).distance_to(Vector2(payload.center[0], payload.center[1]))
			if distance >= float(payload.radius):
				continue
			var t := 1.0 - distance / float(payload.radius)
			var weight := t * t * (3.0 - 2.0 * t) * float(payload.strength)
			var index := y * width + x
			var before := float(source[index])
			var after := before
			match payload.mode:
				"raise": after += MAX_RAISE * weight
				"lower": after -= MAX_RAISE * weight
				"flatten": after = lerpf(before, float(payload.target_height), weight)
				"smooth":
					var total := 0.0
					var samples := 0
					for ny in range(maxi(0, y - 1), mini(depth, y + 2)):
						for nx in range(maxi(0, x - 1), mini(width, x + 2)):
							total += float(source[ny * width + nx])
							samples += 1
					after = lerpf(before, total / samples, weight)
			after = snappedf(clampf(after, -40.0, 80.0), 0.001)
			# Preserve sub-millimetre V1 samples if rounding would produce no real edit.
			if abs(after - before) > 0.0005:
				result.heights[index] = after
				changed += 1
	return {"terrain": result, "changed_samples": changed}
