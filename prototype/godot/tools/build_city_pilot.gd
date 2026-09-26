extends SceneTree
## Builds a new disposable city world through WorldService commands.
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var options := {}
	for arg in OS.get_cmdline_user_args():
		var pair: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2: options[pair[0]] = pair[1]
	if not options.has_all(["manifest", "world-file", "report"]):
		_fail("Required: --manifest=... --world-file=... --report=...")
		return
	var manifest_path: String = ProjectSettings.globalize_path(options.manifest).simplify_path()
	var world_path: String = ProjectSettings.globalize_path(options["world-file"]).simplify_path()
	var report_path: String = ProjectSettings.globalize_path(options.report).simplify_path()
	if FileAccess.file_exists(world_path) or FileAccess.file_exists(world_path + ".bak") or world_path == manifest_path or report_path == world_path:
		_fail("Use a fresh world path; source and report paths must be separate.")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	var entries: Variant = parsed.get("tiles", parsed.get("buildings", [])) if parsed is Dictionary else []
	var primitives: Variant = parsed.get("primitives", []) if parsed is Dictionary else []
	var terrain_flatten: Variant = parsed.get("terrain_flatten", null) if parsed is Dictionary else null
	var crs := str(parsed.get("source_crs", "")) if parsed is Dictionary else ""
	var crs_pattern := RegEx.new()
	crs_pattern.compile("^(EPSG:[0-9]{4,6}(\\+[0-9]{4,6})?|LOCAL_METRES)$")
	if not parsed is Dictionary or not entries is Array or not primitives is Array or entries.size() + primitives.size() < 1 or entries.size() + primitives.size() > Schema.MAX_OBJECTS or crs_pattern.search(crs) == null or not Schema.number(parsed.get("region_size", 256), 256, 512) or float(parsed.get("region_size", 256)) not in [256.0, 512.0]:
		_fail("Invalid bounded city manifest.")
		return
	if terrain_flatten != null and not _valid_terrain_flatten(terrain_flatten, float(parsed.get("region_size", 256))):
		_fail("Invalid terrain_flatten; use centers, radius, passes, and target_height.")
		return
	for building in entries:
		if not building is Dictionary or not building.has_all(["file", "position", "bounds", "sha256"]) or not building.has("id") and not building.has("name") or not building.file is String or not building.sha256 is String or not Schema.vector(building.position, 3, -100, 600) or not Schema.vector(building.bounds, 3, 0.2, 32) or building.has("rotation") and not _valid_rotation(building.rotation):
			_fail("Malformed city manifest entry.")
			return
	for primitive in primitives:
		if not primitive is Dictionary or not primitive.has_all(["name", "position", "bounds", "color"]) or not primitive.name is String or not primitive.color is String or not Schema.vector(primitive.position, 3, -100, 600) or not Schema.vector(primitive.bounds, 3, 0.2, 32) or primitive.get("kind", "box") not in Schema.KINDS or primitive.get("material", "plain") not in Schema.MATERIALS or primitive.has("rotation") and not _valid_rotation(primitive.rotation):
			_fail("Malformed city primitive entry.")
			return
	var service = Service.new(world_path)
	if float(parsed.get("region_size", 256)) == 512.0:
		var enlarged: Dictionary = service.request("SetRegionSize", {"size": 512})
		if not enlarged.ok:
			_fail("Cannot expand city region: " + JSON.stringify(enlarged.errors))
			return
	if parsed.has("region_name"):
		var renamed: Dictionary = service.request("RenameRegion", {"name": parsed.region_name})
		if not renamed.ok:
			_fail("Cannot name city region: " + JSON.stringify(renamed.errors))
			return
	if parsed.has("spawn"):
		var spawn_result: Dictionary = service.request("SetRegionSpawn", {"position": parsed.spawn})
		if not spawn_result.ok:
			_fail("Cannot set city spawn: " + JSON.stringify(spawn_result.errors))
			return
	for item in service.model.snapshot().objects:
		var removed: Dictionary = service.request("DeleteObject", {"id": item.id})
		if not removed.ok:
			_fail("Cannot clear the starter object: " + JSON.stringify(removed.errors))
			return
	var flattened_stamps := 0
	if terrain_flatten != null:
		for pass_index in range(int(terrain_flatten.passes)):
			for center in terrain_flatten.centers:
				var flattened: Dictionary = service.request("SculptTerrain", {"mode": "flatten", "center": center, "radius": terrain_flatten.radius, "strength": 1.0, "target_height": terrain_flatten.target_height})
				if not flattened.ok:
					_fail("Cannot flatten city terrain: " + JSON.stringify(flattened.errors))
					return
				flattened_stamps += 1
	# Place lightweight builtin street pieces before embedding large GLBs.
	# WorldService validates every edit, so this keeps first-run construction fast.
	var primitive_ids: Array = []
	for primitive in primitives:
		var item: Dictionary = Schema.primitive(str(primitive.get("kind", "box")), primitive.name, primitive.position, primitive.bounds, primitive.color, str(primitive.get("material", "plain")))
		if primitive.has("rotation"):
			item.rotation = primitive.rotation
		var placed: Dictionary = service.request("CreateObject", {"object": item})
		if not placed.ok:
			_fail("Cannot place city primitive: " + str(primitive.name) + " " + JSON.stringify(placed.errors))
			return
		primitive_ids.append(item.id)
	var ids: Array = []
	var imported_ids := {}
	for building in entries:
		var name: String = str(building.get("name", "代尔夫特建筑 " + str(building.get("id", "")).split(".")[-1]))
		var path: String = manifest_path.get_base_dir().path_join(building.file).simplify_path()
		if path.get_base_dir() != manifest_path.get_base_dir() or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != building.sha256:
			_fail("City asset content checksum or path mismatch: " + name)
			return
		var asset_id: String = str(imported_ids.get(building.sha256, ""))
		if asset_id.is_empty():
			var imported: Dictionary = service.request("ImportGlb", {"path": path, "name": name, "license": parsed.license, "attribution": parsed.attribution})
			if not imported.ok:
				_fail("Cannot import city asset: " + name + " " + JSON.stringify(imported.errors))
				return
			asset_id = imported.payload.id
			imported_ids[building.sha256] = asset_id
		var item: Dictionary = Schema.box(name, building.position, building.bounds, "#FFFFFF")
		item.asset_id = asset_id
		if building.has("rotation"):
			item.rotation = building.rotation
		var placed: Dictionary = service.request("CreateObject", {"object": item})
		if not placed.ok:
			_fail("Cannot place city asset: " + name + " " + JSON.stringify(placed.errors))
			return
		ids.append({"source_id": building.get("id", building.get("source_obj", "")), "object_id": item.id, "asset_id": asset_id})
	var saved: Dictionary = service.request("SaveRegion")
	if not saved.ok:
		_fail("Cannot save city world: " + JSON.stringify(saved.errors))
		return
	var report := {"ok": true, "world_file": world_path, "buildings": ids, "revision": service.model.revision(), "source_url": parsed.get("source_url", "")}
	if not primitive_ids.is_empty(): report.primitives = primitive_ids
	if terrain_flatten != null: report.terrain_stamps = flattened_stamps
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("CITY_PILOT " + JSON.stringify(report))
	quit(0)

func _valid_rotation(value: Variant) -> bool:
	if not Schema.vector(value, 4, -1, 1):
		return false
	var rotation := Quaternion(value[0], value[1], value[2], value[3])
	return absf(rotation.length_squared() - 1.0) <= 0.001

func _valid_terrain_flatten(value: Variant, region_size: float) -> bool:
	if not value is Dictionary or not Schema.exact_keys(value, ["centers", "radius", "passes", "target_height"]) or not value.centers is Array or value.centers.is_empty() or value.centers.size() > 32:
		return false
	if not Schema.number(value.radius, 4, 32) or not Schema.number(value.passes, 1, 4) or float(value.passes) != floorf(float(value.passes)) or not Schema.number(value.target_height, -40, 80):
		return false
	for center in value.centers:
		if not Schema.vector(center, 2, 0, region_size):
			return false
	return true

func _fail(message: String) -> void:
	push_error(message)
	print("CITY_PILOT " + JSON.stringify({"ok": false, "error": message}))
	quit(1)
