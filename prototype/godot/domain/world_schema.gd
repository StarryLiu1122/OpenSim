extends RefCounted
## Portable world data. Coordinates: X east, Y north, Z up; distances in metres.

const VERSION := 1
const OWNER := "11111111-1111-4111-8111-111111111111"
const BOX_ASSET := "22222222-2222-4222-8222-222222222222"
const REGION_ID := "33333333-3333-4333-8333-333333333333"
const MAX_OBJECTS := 500
const MAX_FILE_BYTES := 8 * 1024 * 1024

static func uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	var value := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [value.substr(0, 8), value.substr(8, 4), value.substr(12, 4), value.substr(16, 4), value.substr(20, 12)]

static func is_uuid(value: Variant) -> bool:
	if not value is String:
		return false
	var regex := RegEx.new()
	regex.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
	return regex.search(value) != null

static func number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= minimum and float(value) <= maximum

static func vector(value: Variant, count: int, minimum: float, maximum: float) -> bool:
	if not value is Array or value.size() != count:
		return false
	for component in value:
		if not number(component, minimum, maximum):
			return false
	return true

static func exact_keys(value: Dictionary, required: Array) -> bool:
	return value.size() == required.size() and value.has_all(required)

static func validate(world: Variant) -> String:
	if not world is Dictionary or not exact_keys(world, ["schema_version", "revision", "region", "terrain", "assets", "objects"]):
		return "World fields are missing or unknown."
	if world.schema_version != VERSION:
		return "Unsupported world schema version."
	if not number(world.revision, 0, 1000000000) or float(world.revision) != floor(float(world.revision)):
		return "Invalid world revision."
	var region: Variant = world.region
	if not region is Dictionary or not exact_keys(region, ["id", "name", "size", "spawn", "owner_id"]):
		return "Invalid region fields."
	if not is_uuid(region.id) or not is_uuid(region.owner_id) or not region.name is String or region.name.length() < 1 or region.name.length() > 80:
		return "Invalid region identity."
	if not vector(region.size, 2, 16, 512) or not vector(region.spawn, 3, -100, 600):
		return "Invalid region dimensions or spawn."
	if region.size[0] != 256 or region.size[1] != 256:
		return "This prototype validates only a 256 x 256 metre region."
	if region.spawn[0] < 1 or region.spawn[0] > region.size[0] - 1 or region.spawn[1] < 1 or region.spawn[1] > region.size[1] - 1:
		return "Spawn is outside the region."
	var terrain: Variant = world.terrain
	if not terrain is Dictionary or not exact_keys(terrain, ["columns", "rows", "spacing", "heights"]):
		return "Invalid terrain fields."
	if not number(terrain.columns, 2, 129) or not number(terrain.rows, 2, 129) or not number(terrain.spacing, 0.25, 16):
		return "Invalid terrain sampling."
	if terrain.columns != floor(float(terrain.columns)) or terrain.rows != floor(float(terrain.rows)):
		return "Terrain dimensions must be integers."
	if abs((terrain.columns - 1) * terrain.spacing - region.size[0]) > 0.0001 or abs((terrain.rows - 1) * terrain.spacing - region.size[1]) > 0.0001:
		return "Terrain coverage differs from region dimensions."
	if not vector(terrain.heights, int(terrain.columns * terrain.rows), -40, 80):
		return "Invalid terrain heights."
	if not world.assets is Array or world.assets.size() != 1:
		return "This prototype requires exactly one built-in box asset."
	var asset: Variant = world.assets[0]
	if not asset is Dictionary or not exact_keys(asset, ["id", "kind", "uri"]) or asset.id != BOX_ASSET or asset.kind != "box" or asset.uri != "builtin://unit-box":
		return "Unknown asset; external resource loading is not supported."
	if not world.objects is Array or world.objects.size() > MAX_OBJECTS:
		return "Invalid object collection or object limit exceeded."
	var seen: Dictionary = {}
	for item in world.objects:
		var error := validate_object(item, region)
		if not error.is_empty():
			return error
		if seen.has(item.id):
			return "Duplicate object ID."
		seen[item.id] = true
	return ""

static func validate_object(item: Variant, region: Dictionary) -> String:
	if not item is Dictionary or not exact_keys(item, ["id", "name", "asset_id", "owner_id", "position", "rotation", "size", "color"]):
		return "Invalid object fields."
	if not is_uuid(item.id) or item.asset_id != BOX_ASSET or not is_uuid(item.owner_id):
		return "Invalid object identity or asset reference."
	if not item.name is String or item.name.strip_edges().is_empty() or item.name.length() > 80:
		return "Object name must have 1–80 characters."
	if not vector(item.position, 3, -100, 600) or not vector(item.size, 3, 0.2, 32) or not vector(item.rotation, 4, -1, 1):
		return "Invalid transform; dimensions must be 0.2–32 m."
	var q := Quaternion(item.rotation[0], item.rotation[1], item.rotation[2], item.rotation[3])
	if abs(q.length_squared() - 1.0) > 0.001:
		return "Rotation quaternion must be normalized."
	if item.position[2] < -40 or item.position[2] > 120:
		return "Object height must be between -40 and 120 m."
	var rotation_basis := Basis(q)
	var half := Vector3(item.size[0], item.size[1], item.size[2]) * 0.5
	var extent := rotation_basis.x.abs() * half.x + rotation_basis.y.abs() * half.y + rotation_basis.z.abs() * half.z
	if item.position[0] - extent.x < 0 or item.position[0] + extent.x > region.size[0] or item.position[1] - extent.y < 0 or item.position[1] + extent.y > region.size[1]:
		return "Object footprint crosses the region boundary."
	if not item.color is String or item.color.length() != 7 or not item.color.begins_with("#") or not Color.html_is_valid(item.color):
		return "Color must be #RRGGBB."
	return ""

static func box(name: String, position: Array, size: Array, color: String) -> Dictionary:
	return {"id": uuid(), "name": name, "asset_id": BOX_ASSET, "owner_id": OWNER, "position": position, "rotation": [0.0, 0.0, 0.0, 1.0], "size": size, "color": color}

static func seed() -> Dictionary:
	var heights: Array = []
	for y in range(65):
		for x in range(65):
			var east := x * 4.0
			var north := y * 4.0
			var hill := 12.0 * exp(-((east - 55.0) * (east - 55.0) + (north - 195.0) * (north - 195.0)) / 2000.0)
			hill += 8.0 * exp(-((east - 215.0) * (east - 215.0) + (north - 205.0) * (north - 205.0)) / 1600.0)
			heights.append(snappedf(hill, 0.001))
	var world := {
		"schema_version": VERSION, "revision": 0,
		"region": {"id": REGION_ID, "name": "青屿实验区", "size": [256.0, 256.0], "spawn": [128.0, 107.0, 2.5], "owner_id": OWNER},
		"terrain": {"columns": 65, "rows": 65, "spacing": 4.0, "heights": heights},
		"assets": [{"id": BOX_ASSET, "kind": "box", "uri": "builtin://unit-box"}],
		"objects": []}
	world.objects = [
		box("中央展台", [128.0, 131.0, 0.35], [14.0, 14.0, 0.7], "#D9DED4"),
		box("青绿立方", [124.0, 129.0, 2.25], [3.0, 3.0, 3.0], "#50A696"),
		box("日光立方", [130.0, 133.0, 1.75], [2.0, 2.0, 2.0], "#E9B45D"),
		box("远山立方", [132.0, 128.0, 3.25], [2.5, 2.5, 5.0], "#758FAD"),
		box("长凳", [119.0, 119.0, 0.65], [5.0, 1.5, 1.3], "#C7AD85"),
		box("北侧门柱 A", [119.0, 147.0, 3.0], [1.2, 1.2, 6.0], "#F0EADC"),
		box("北侧门柱 B", [131.0, 147.0, 3.0], [1.2, 1.2, 6.0], "#F0EADC"),
		box("北侧横梁", [125.0, 147.0, 6.1], [13.2, 1.2, 1.0], "#F0EADC")]
	return world
