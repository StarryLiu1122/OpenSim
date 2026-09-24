extends RefCounted
const Reader = preload("res://adapters/glb_reader.gd")
const Packer = preload("res://adapters/gltf_packer.gd")
const ObjPacker = preload("res://adapters/obj_packer.gd")
const C = preload("res://domain/schema_v2.gd")
static var _cache: Dictionary = {}

static func import_file(payload: Dictionary) -> Dictionary:
	if not C.exact_keys(payload, ["path", "name", "license", "attribution"]) or not payload.path is String or payload.path.get_extension().to_lower() not in ["glb", "gltf", "obj"]:
		return {"error": "ImportGlb requires path, name, license and attribution; choose a .glb, .gltf or .obj file."}
	for key in ["name", "license", "attribution"]:
		if not _text(payload[key], 160):
			return {"error": "Provide a nonempty name, license identifier and attribution (1–160 characters)."}
	var source := read_source(payload.path)
	if source.has("error"): return source
	var bytes: PackedByteArray = source.bytes
	var digest := sha256(bytes)
	var geometry := Reader.new().parse(bytes)
	if geometry.has("error"):
		return geometry
	var record := {"id": content_id(digest), "kind": "mesh", "uri": "embedded://sha256/" + digest, "sha256": digest, "name": payload.name, "license": payload.license, "attribution": payload.attribution, "bounds": geometry.bounds, "glb": Marshalls.raw_to_base64(bytes)}
	_remember(digest, geometry)
	return {"asset": record, "triangles": geometry.triangles, "collision_mode": geometry.collision_mode}

static func read_source(path: String) -> Dictionary:
	if path.get_extension().to_lower() == "gltf": return Packer.read(path)
	if path.get_extension().to_lower() == "obj": return ObjPacker.read(path)
	if path.get_extension().to_lower() != "glb": return {"error": "Choose a .glb, .gltf or .obj file."}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"error": "Cannot open GLB: " + error_string(FileAccess.get_open_error())}
	if file.get_length() > Reader.MAX_BYTES: return {"error": "GLB exceeds the 2 MiB import limit."}
	return {"bytes": file.get_buffer(file.get_length())}

static func read(record: Variant) -> Dictionary:
	if not record is Dictionary or not C.exact_keys(record, ["id", "kind", "uri", "sha256", "name", "license", "attribution", "bounds", "glb"]):
		return {"error": "Invalid embedded mesh asset fields."}
	if not record.sha256 is String or record.sha256.length() != 64 or not record.sha256.is_valid_hex_number() or record.sha256 != record.sha256.to_lower() or record.id != content_id(record.sha256) or record.kind != "mesh" or record.uri != "embedded://sha256/" + record.sha256:
		return {"error": "Invalid content-addressed asset identity."}
	for key in ["name", "license", "attribution"]:
		if not _text(record[key], 160):
			return {"error": "Mesh asset provenance must be recorded."}
	if not C.vector(record.bounds, 3, 0.2, 32) or not record.glb is String or record.glb.length() > 2796204:
		return {"error": "Invalid mesh bounds or embedded file size."}
	var regex := RegEx.new()
	regex.compile("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
	if record.glb.is_empty() or regex.search(record.glb) == null:
		return {"error": "Invalid embedded base64."}
	var bytes := Marshalls.base64_to_raw(record.glb)
	if bytes.size() > Reader.MAX_BYTES or sha256(bytes) != record.sha256:
		return {"error": "Embedded mesh content checksum mismatch."}
	var geometry: Dictionary = _cache.get(record.sha256, {})
	if geometry.is_empty():
		geometry = Reader.new().parse(bytes)
		if geometry.has("error"):
			return geometry
		_remember(record.sha256, geometry)
	for axis in range(3):
		if absf(float(record.bounds[axis]) - float(geometry.bounds[axis])) > 0.000001:
			return {"error": "Stored mesh bounds disagree with its content."}
	return geometry.duplicate(true)

static func sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

static func content_id(digest: String) -> String:
	return "%s-%s-%s-%s-%s" % [digest.substr(0, 8), digest.substr(8, 4), digest.substr(12, 4), digest.substr(16, 4), digest.substr(20, 12)]

static func _text(value: Variant, limit: int) -> bool:
	return value is String and not value.strip_edges().is_empty() and value.length() <= limit

static func _remember(digest: String, geometry: Dictionary) -> void:
	_cache[digest] = geometry.duplicate(true)
	if _cache.size() > 16:
		_cache.erase(_cache.keys()[0])
