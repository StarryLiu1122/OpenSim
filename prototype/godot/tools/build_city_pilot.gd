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
	if not parsed is Dictionary or not entries is Array or entries.is_empty() or entries.size() > 16 or parsed.get("source_crs") not in ["EPSG:7415", "EPSG:3879+5773"]:
		_fail("Invalid bounded city manifest.")
		return
	var service = Service.new(world_path)
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
	var ids: Array = []
	for building in entries:
		if not building is Dictionary or not building.has_all(["file", "position", "bounds", "sha256"]) or not building.has("id") and not building.has("name"):
			_fail("Malformed city manifest entry.")
			return
		var name: String = str(building.get("name", "代尔夫特建筑 " + str(building.get("id", "")).split(".")[-1]))
		var path: String = manifest_path.get_base_dir().path_join(building.file)
		if path.get_base_dir() != manifest_path.get_base_dir() or FileAccess.get_sha256(path) != building.sha256:
			_fail("City asset content checksum or path mismatch: " + name)
			return
		var imported: Dictionary = service.request("ImportGlb", {"path": path, "name": name, "license": parsed.license, "attribution": parsed.attribution})
		if not imported.ok:
			_fail("Cannot import city asset: " + name + " " + JSON.stringify(imported.errors))
			return
		var asset_id: String = imported.payload.id
		var item: Dictionary = Schema.box(name, building.position, building.bounds, "#FFFFFF")
		item.asset_id = asset_id
		var placed: Dictionary = service.request("CreateObject", {"object": item})
		if not placed.ok:
			_fail("Cannot place city asset: " + name + " " + JSON.stringify(placed.errors))
			return
		ids.append({"source_id": building.get("id", building.get("source_obj", "")), "object_id": item.id, "asset_id": asset_id})
	var saved: Dictionary = service.request("SaveRegion")
	if not saved.ok:
		_fail("Cannot save city world: " + JSON.stringify(saved.errors))
		return
	var report := {"ok": true, "world_file": world_path, "buildings": ids, "revision": service.model.revision(), "source_url": parsed.source_url}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("CITY_PILOT " + JSON.stringify(report))
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	print("CITY_PILOT " + JSON.stringify({"ok": false, "error": message}))
	quit(1)
