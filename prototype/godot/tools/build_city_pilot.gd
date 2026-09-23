extends SceneTree
## Builds a new disposable real-building world through WorldService commands.
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
	if not parsed is Dictionary or not parsed.get("buildings") is Array or parsed.buildings.is_empty() or parsed.buildings.size() > 16 or parsed.get("source_crs") != "EPSG:7415":
		_fail("Invalid bounded 3DBAG manifest.")
		return
	var service = Service.new(world_path)
	for item in service.model.snapshot().objects:
		var removed: Dictionary = service.request("DeleteObject", {"id": item.id})
		if not removed.ok:
			_fail("Cannot clear the starter object: " + JSON.stringify(removed.errors))
			return
	var ids: Array = []
	for building in parsed.buildings:
		if not building is Dictionary or not building.has_all(["id", "file", "position", "bounds", "sha256"]):
			_fail("Malformed building manifest entry.")
			return
		var path: String = manifest_path.get_base_dir().path_join(building.file)
		if path.get_base_dir() != manifest_path.get_base_dir() or FileAccess.get_sha256(path) != building.sha256:
			_fail("Building content checksum or path mismatch: " + str(building.id))
			return
		var imported: Dictionary = service.request("ImportGlb", {"path": path, "name": "Delft " + str(building.id).split(".")[-1], "license": parsed.license, "attribution": parsed.attribution + "; " + parsed.source_url})
		if not imported.ok:
			_fail("Cannot import building: " + str(building.id) + " " + JSON.stringify(imported.errors))
			return
		var asset_id: String = imported.payload.id
		var item: Dictionary = Schema.box("代尔夫特建筑 " + str(building.id).split(".")[-1], building.position, building.bounds, "#FFFFFF")
		item.asset_id = asset_id
		var placed: Dictionary = service.request("CreateObject", {"object": item})
		if not placed.ok:
			_fail("Cannot place building: " + str(building.id) + " " + JSON.stringify(placed.errors))
			return
		ids.append({"source_id": building.id, "object_id": item.id, "asset_id": asset_id})
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
