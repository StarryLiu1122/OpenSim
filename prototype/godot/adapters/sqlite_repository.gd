extends "res://adapters/repository_contract.gd"
const Schema = preload("res://domain/world_schema.gd")
const Content = preload("res://adapters/content_asset_store.gd")
var directory: String
var region_id: String
var executable: String
var commit_revision := -1
var _pending: Dictionary = {}

func _init(storage_directory: String, store_executable: String, id: String = Schema.REGION_ID) -> void:
	directory = ProjectSettings.globalize_path(storage_directory)
	executable = ProjectSettings.globalize_path(store_executable)
	region_id = id
	path = directory.path_join("worlds.sqlite3")

func exists() -> bool:
	# Existing but unreadable stores must reach LoadRegion and report a real error.
	# They must never silently become a fresh JSON world.
	if not FileAccess.file_exists(path): return false
	var status := _invoke({"operation": "status"})
	if status.has("error"): return true
	for region in status.regions:
		if region[0] == region_id: return true
	return false

func _invoke(request: Dictionary) -> Dictionary:
	if not FileAccess.file_exists(executable): return {"error": "RegionStore executable is missing; build/install V4 storage first."}
	request.root = directory
	request.region_id = region_id
	request.godot = OS.get_executable_path()
	request.project = ProjectSettings.globalize_path("res://")
	var scratch := directory.path_join("requests").path_join(Schema.uuid())
	if DirAccess.make_dir_recursive_absolute(scratch) != OK: return {"error": "Cannot create isolated storage request directory."}
	var input := scratch.path_join("request.json")
	var output := scratch.path_join("response.json")
	var file := FileAccess.open(input, FileAccess.WRITE)
	if file == null: return {"error": "Cannot write storage request."}
	file.store_string(JSON.stringify(request, "", true, true)); file.close()
	var log: Array = []
	var exit_code := OS.execute(executable, [input, output], log, true, false)
	var result: Variant = null
	var response := FileAccess.open(output, FileAccess.READ)
	if response != null and response.get_length() <= 12 * 1024 * 1024: result = JSON.parse_string(response.get_as_text())
	response = null
	for temporary in [input, output]:
		if FileAccess.file_exists(temporary): DirAccess.remove_absolute(temporary)
	DirAccess.remove_absolute(scratch)
	if not result is Dictionary: return {"error": "Storage process returned no valid response; outcome unknown. Reload before changing the candidate."}
	if exit_code != 0 or not result.get("ok", false): return {"error": result.get("error", "STORAGE_FAILED")}
	return result

func load_world() -> Dictionary:
	var result := _invoke({"operation": "load"})
	if result.has("error"): return result
	var hydrated := Content.hydrate(result.world, directory.path_join("objects"))
	if hydrated.has("error"): return hydrated
	result.world = hydrated.world
	var validation := Schema.validate(result.world)
	if not validation.is_empty(): return {"error": validation}
	commit_revision = int(result.commit_revision)
	_pending.clear()
	return result

func save_world(world: Dictionary) -> Dictionary:
	var validation := Schema.validate(world)
	if not validation.is_empty(): return {"error": validation}
	var serialized := JSON.stringify(world, "", true, true)
	var fingerprint := serialized.sha256_text()
	if not _pending.is_empty() and _pending.fingerprint != fingerprint:
		return {"error": "Previous save outcome is unresolved. Retry the unchanged world or reload before saving a different candidate."}
	if _pending.is_empty(): _pending = {"fingerprint": fingerprint, "request_id": Schema.uuid()}
	var staged := Content.stage(world, directory.path_join("objects"))
	if staged.has("error"): return staged
	if DirAccess.make_dir_recursive_absolute(directory) != OK: return {"error": "Cannot create database directory."}
	var input := directory.path_join("candidate-" + _pending.request_id + ".json")
	var file := FileAccess.open(input, FileAccess.WRITE)
	if file == null: return {"error": "Cannot write candidate world."}
	file.store_string(JSON.stringify(staged.world, "", true, true)); file.flush(); file.close()
	var result := _invoke({"operation": "save", "input": input, "expected_commit": commit_revision, "request_id": _pending.request_id})
	DirAccess.remove_absolute(input)
	if result.has("error"): return result
	commit_revision = int(result.commit_revision)
	_pending.clear()
	result.revision = world.revision
	return result
