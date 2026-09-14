extends RefCounted
## Validated, checksummed snapshots. Single writer; bounded reads; previous valid backup.
const Schema = preload("res://domain/world_schema.gd")

var path: String
var _fingerprint := ""

func _init(file_path: String) -> void:
	path = ProjectSettings.globalize_path(file_path)

func exists() -> bool:
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")

static func canonical(world: Dictionary) -> String:
	# Stable semantic comparison for diagnostics. Integrity hashes the exact stored payload.
	return JSON.stringify(world, "", true)

func _read(file_path: String) -> Dictionary:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return {"error": "Cannot open snapshot: " + error_string(FileAccess.get_open_error())}
	if file.get_length() > Schema.MAX_FILE_BYTES:
		return {"error": "Snapshot exceeds the 8 MiB limit."}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return {"error": "Snapshot JSON is invalid."}
	var envelope: Variant = parser.data
	if not envelope is Dictionary or not Schema.exact_keys(envelope, ["format", "version", "sha256", "world_json"]):
		return {"error": "Invalid snapshot envelope."}
	if envelope.format != "region-lab.snapshot" or envelope.version != 1:
		return {"error": "Unsupported snapshot version."}
	if not envelope.world_json is String or not envelope.sha256 is String or envelope.world_json.sha256_text() != envelope.sha256:
		return {"error": "Snapshot checksum mismatch."}
	var payload := JSON.new()
	if payload.parse(envelope.world_json) != OK:
		return {"error": "World payload JSON is invalid."}
	var upgraded := Schema.upgrade(payload.data)
	if upgraded.has("error"):
		return upgraded
	upgraded.sha256 = envelope.sha256
	return upgraded

func load_world() -> Dictionary:
	var primary := _read(path)
	_fingerprint = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
	if not primary.has("error"):
		primary["recovered"] = false
		return primary
	var backup := _read(path + ".bak")
	if not backup.has("error"):
		backup["recovered"] = true
		backup["warning"] = "Primary snapshot unavailable; loaded the last valid backup. " + primary.error
		return backup
	return {"error": primary.error + " Backup: " + backup.error}

func save_world(world: Dictionary) -> Dictionary:
	var error := Schema.validate(world)
	if not error.is_empty():
		return {"error": error}
	var disk_hash := FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
	if disk_hash != _fingerprint:
		return {"error": "Snapshot changed on disk. Reload before saving; use a separate file for another instance."}
	var directory_error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if directory_error != OK:
		return {"error": "Cannot create save directory: " + error_string(directory_error)}
	# Hash the stored UTF-8 text, not re-serialized floats (which can round differently).
	var world_json := JSON.stringify(world, "\t", true, true)
	var digest := world_json.sha256_text()
	var envelope := {"format": "region-lab.snapshot", "version": 1, "sha256": digest, "world_json": world_json}
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return {"error": "Cannot write snapshot: " + error_string(FileAccess.get_open_error())}
	file.store_string(JSON.stringify(envelope, "\t", true, true) + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK or _read(temp_path).has("error"):
		return {"error": "Snapshot verification failed; existing save was preserved."}
	# Never rotate a corrupt primary over a valid backup.
	if FileAccess.file_exists(path) and not _read(path).has("error"):
		var backup_temp := path + ".bak.tmp"
		var copy_error := DirAccess.copy_absolute(path, backup_temp)
		if copy_error != OK or _read(backup_temp).has("error"):
			return {"error": "Backup verification failed; existing save was preserved."}
		if DirAccess.rename_absolute(backup_temp, path + ".bak") != OK:
			return {"error": "Cannot publish backup; existing save was preserved."}
	var rename_error := DirAccess.rename_absolute(temp_path, path)
	if rename_error != OK:
		return {"error": "Cannot publish snapshot: " + error_string(rename_error)}
	_fingerprint = FileAccess.get_sha256(path)
	return {"path": path, "sha256": digest, "revision": world.revision}
