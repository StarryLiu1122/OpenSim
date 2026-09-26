extends RefCounted
## The on-disk world contains mesh metadata; immutable GLB bytes live by SHA-256.
const Assets = preload("res://adapters/mesh_assets.gd")
const Reader = preload("res://adapters/glb_reader.gd")

static func stage(world: Dictionary, directory: String) -> Dictionary:
	var compact := world.duplicate(true)
	for asset in compact.assets:
		if asset.kind != "mesh": continue
		# Callers validate the full world before staging; publication independently
		# checks the byte length and SHA so an on-disk object cannot be substituted.
		var bytes := Marshalls.base64_to_raw(asset.glb)
		var published := _publish(directory, asset.sha256, bytes)
		if published.has("error"): return published
		asset.erase("glb")
	return {"world": compact}

static func hydrate(world: Dictionary, directory: String) -> Dictionary:
	if not world.get("assets") is Array: return {"error": "Invalid asset catalog."}
	var expanded := world.duplicate(true)
	for asset in expanded.assets:
		if not asset is Dictionary or asset.get("kind", "") != "mesh": continue
		if asset.has("glb"): continue # Version 1 snapshots embed their content.
		var digest: Variant = asset.get("sha256")
		if not _digest(digest): return {"error": "Invalid mesh content reference."}
		var path := directory.path_join(digest + ".glb")
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null: return {"error": "Mesh content is missing: " + digest}
		if file.get_length() < 1 or file.get_length() > Reader.MAX_BYTES:
			return {"error": "Mesh content exceeds its file limit: " + digest}
		var bytes := file.get_buffer(file.get_length())
		if Assets.sha256(bytes) != digest: return {"error": "Mesh content checksum mismatch: " + digest}
		asset.glb = Marshalls.raw_to_base64(bytes)
		var checked := Assets.read(asset)
		if checked.has("error"): return checked
	return {"world": expanded}

static func _publish(directory: String, digest: String, bytes: PackedByteArray) -> Dictionary:
	if not _digest(digest) or bytes.size() < 1 or bytes.size() > Reader.MAX_BYTES or Assets.sha256(bytes) != digest:
		return {"error": "Invalid mesh content checksum or size."}
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {"error": "Cannot create mesh content directory."}
	var target := directory.path_join(digest + ".glb")
	if FileAccess.file_exists(target):
		return {} if FileAccess.get_sha256(target) == digest else {"error": "Existing mesh content is corrupt: " + digest}
	var temporary := directory.path_join(digest + "." + str(Time.get_ticks_usec()) + ".tmp")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return {"error": "Cannot write mesh content."}
	file.store_buffer(bytes); file.flush()
	var write_error := file.get_error(); file.close()
	if write_error != OK or FileAccess.get_sha256(temporary) != digest:
		DirAccess.remove_absolute(temporary)
		return {"error": "Mesh content verification failed."}
	if DirAccess.rename_absolute(temporary, target) != OK:
		DirAccess.remove_absolute(temporary)
		# Another writer may have published the same immutable object meanwhile.
		return {} if FileAccess.file_exists(target) and FileAccess.get_sha256(target) == digest else {"error": "Cannot publish mesh content."}
	return {}

static func _digest(value: Variant) -> bool:
	return value is String and value.length() == 64 and value.is_valid_hex_number() and value == value.to_lower()
