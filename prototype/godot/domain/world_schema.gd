extends RefCounted
## Portable world data. Coordinates: X east, Y north, Z up; distances in metres.

const VERSION := 3
const Previous = preload("res://domain/schema_v2.gd")
const T = preload("res://domain/world_transforms.gd")
const MeshAssets = preload("res://adapters/mesh_assets.gd")
const KINDS := ["box", "cylinder", "sphere", "door", "tree", "lamp"]
const MATERIALS := ["plain", "concrete", "brick", "wood", "metal"]
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
	if not world is Dictionary or not exact_keys(world, ["schema_version", "revision", "region", "terrain", "assets", "objects", "environment", "groups"]):
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
	var environment_error := validate_environment(world.environment)
	if not environment_error.is_empty():
		return environment_error
	if not world.assets is Array or world.assets.size() < KINDS.size() or world.assets.size() > KINDS.size() + 16 or world.assets.slice(0, KINDS.size()) != catalog():
		return "The asset catalog must begin with the six fixed built-ins and contain at most 16 imported assets."
	var mesh_ids: Array = []
	for asset in world.assets.slice(KINDS.size()):
		var loaded := MeshAssets.read(asset)
		if loaded.has("error"):
			return loaded.error
		if asset.id in mesh_ids or not kind(asset.id).is_empty():
			return "Duplicate asset identity."
		mesh_ids.append(asset.id)
	if not world.groups is Array or world.groups.size() > 128:
		return "Invalid group collection."
	var groups: Dictionary = {}
	for frame in world.groups:
		if not frame is Dictionary or not exact_keys(frame, ["id", "name", "root_id", "owner_id", "position", "rotation", "scale"]):
			return "Invalid group fields."
		if not is_uuid(frame.id) or not is_uuid(frame.root_id) or not is_uuid(frame.owner_id) or groups.has(frame.id) or not frame.name is String or frame.name.strip_edges().is_empty() or frame.name.length() > 80:
			return "Invalid group identity."
		if not vector(frame.position, 3, -100, 600) or not vector(frame.rotation, 4, -1, 1) or not number(frame.scale, 0.1, 10) or abs(T.quat(frame.rotation).length_squared() - 1) > 0.001:
			return "Invalid group transform."
		groups[frame.id] = frame
	if not world.objects is Array or world.objects.size() > MAX_OBJECTS:
		return "Invalid object collection or object limit exceeded."
	var seen: Dictionary = {}
	for item in world.objects:
		if not item is Dictionary or not item.get("group_id") is String or (not item.group_id.is_empty() and not groups.has(item.group_id)):
			return "Invalid or missing group reference."
		if not vector(item.get("position"), 3, -512, 600) or not vector(item.get("size"), 3, 0.02, 320) or not vector(item.get("rotation"), 4, -1, 1):
			return "Invalid local transform."
		if abs(T.quat(item.rotation).length_squared() - 1) > 0.001:
			return "Local rotation must be normalized."
		var error := validate_object(T.resolve(item, world.groups), region, mesh_ids)
		if not error.is_empty():
			return error
		if seen.has(item.id):
			return "Duplicate object ID."
		seen[item.id] = item
	for frame in world.groups:
		var count := 0
		for item in world.objects:
			if item.group_id == frame.id:
				count += 1
				if item.owner_id != frame.owner_id:
					return "Group members must share ownership."
		var root: Dictionary = seen.get(frame.root_id, {})
		if seen.has(frame.id) or count < 2 or count > 100 or root.is_empty() or root.group_id != frame.id:
			return "Group root or member count is invalid."
		if T.vec(root.position).length() > 0.00001 or abs(T.quat(root.rotation).dot(Quaternion.IDENTITY)) < 0.999999:
			return "Root transform belongs to the group; use UpdateGroup."
	if world.assets.size() > KINDS.size():
		var text := JSON.stringify(world, "\t", true, true)
		var envelope := {"format": "region-lab.snapshot", "version": 1, "sha256": "0".repeat(64), "world_json": text}
		if (JSON.stringify(envelope, "\t", true, true) + "\n").to_utf8_buffer().size() > MAX_FILE_BYTES:
			return "Embedded world exceeds the snapshot budget."
	return ""

static func validate_object(item: Variant, region: Dictionary, mesh_ids: Array = []) -> String:
	if not item is Dictionary or not exact_keys(item, ["id", "name", "asset_id", "owner_id", "position", "rotation", "size", "color", "material", "state", "group_id"]):
		return "Invalid object fields."
	if not is_uuid(item.id) or (kind(item.asset_id).is_empty() and item.asset_id not in mesh_ids) or not is_uuid(item.owner_id):
		return "Invalid object identity or asset reference."
	if not item.name is String or item.name.strip_edges().is_empty() or item.name.length() > 80:
		return "Object name must have 1–80 characters."
	if not vector(item.position, 3, -100, 600) or not vector(item.size, 3, 0.2, 32) or not vector(item.rotation, 4, -1, 1):
		return "Invalid transform; dimensions must be 0.2–32 m."
	if item.material not in MATERIALS or (item.asset_id in mesh_ids and item.material != "plain"):
		return "Unknown surface material."
	if not item.state is Dictionary:
		return "Object state must be a dictionary."
	if kind(item.asset_id) in ["door", "lamp"]:
		if not exact_keys(item.state, ["active"]) or not item.state.active is bool:
			return "Interactive objects require a boolean active state."
	elif not item.state.is_empty():
		return "This asset has no persistent behavior state."
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
	return {"id": uuid(), "name": name, "asset_id": BOX_ASSET, "owner_id": OWNER, "position": position, "rotation": [0.0, 0.0, 0.0, 1.0], "size": size, "color": color, "material": "plain", "state": {}, "group_id": ""}

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
		"assets": catalog(), "environment": default_environment(),
		"objects": [], "groups": []}
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


static func catalog() -> Array:
	var result: Array = []
	for i in range(KINDS.size()):
		result.append({"id": asset_id(KINDS[i]), "kind": KINDS[i], "uri": "builtin://unit-" + KINDS[i]})
	return result

static func asset_id(asset_kind: String) -> String:
	var index := KINDS.find(asset_kind)
	return BOX_ASSET if index == 0 else "22222222-2222-4222-8222-%012d" % (index + 1)

static func kind(id: Variant) -> String:
	for asset_kind in KINDS:
		if id == asset_id(asset_kind):
			return asset_kind
	return ""

static func primitive(asset_kind: String, name: String, position: Array, size: Array, color: String, material: String = "plain") -> Dictionary:
	var item := box(name, position, size, color)
	item.asset_id = asset_id(asset_kind)
	item.material = material
	if asset_kind in ["door", "lamp"]:
		item.state = {"active": asset_kind == "lamp"}
	return item

static func default_environment() -> Dictionary:
	return {"sun_hour": 15.5, "water_enabled": false, "water_height": -1.0, "fog_density": 0.0015, "terrain_grid": false}

static func validate_environment(value: Variant) -> String:
	if not value is Dictionary or not exact_keys(value, ["sun_hour", "water_enabled", "water_height", "fog_density", "terrain_grid"]):
		return "Invalid environment fields."
	if not number(value.sun_hour, 0, 24) or not number(value.water_height, -40, 80) or not number(value.fog_density, 0, 0.02):
		return "Environment value outside its supported range."
	if not value.water_enabled is bool or not value.terrain_grid is bool:
		return "Environment switches must be boolean."
	return ""

static func upgrade(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"error": "World must be a dictionary."}
	if value.get("schema_version") == 1 or value.get("schema_version") == 2:
		var previous := Previous.upgrade(value)
		if previous.has("error"):
			return previous
		var world: Dictionary = previous.world
		world.schema_version = VERSION
		world.groups = []
		for item in world.objects:
			item.group_id = ""
		return {"world": world, "migrated": true}
	var error := validate(value)
	return {"world": value.duplicate(true), "migrated": false} if error.is_empty() else {"error": error}

static func mesh_ids(world: Dictionary) -> Array:
	var result: Array = []
	for asset in world.assets:
		if asset.kind == "mesh":
			result.append(asset.id)
	return result
