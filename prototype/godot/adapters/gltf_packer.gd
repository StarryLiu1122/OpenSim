extends RefCounted
## Packs a bounded .gltf and same-directory dependencies into the existing GLB asset format.
const Reader = preload("res://adapters/glb_reader.gd")
const MAX_SOURCE_BYTES := 4 * 1024 * 1024

static func read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_SOURCE_BYTES:
		return {"error": "Cannot read glTF JSON or source exceeds 4 MiB."}
	var document: Variant = JSON.parse_string(file.get_as_text())
	if not document is Dictionary or not document.get("buffers") is Array or document.buffers.size() != 1 or not document.buffers[0] is Dictionary:
		return {"error": "glTF requires exactly one buffer."}
	var buffer: Dictionary = document.buffers[0]
	if not buffer.get("uri") is String or not buffer.get("byteLength") is float and not buffer.get("byteLength") is int:
		return {"error": "glTF buffer URI and length are required."}
	var loaded := _dependency(path, buffer.uri, "buffer")
	if loaded.has("error"): return loaded
	var binary: PackedByteArray = loaded.bytes
	if float(buffer.byteLength) != floor(float(buffer.byteLength)) or int(buffer.byteLength) < 1 or int(buffer.byteLength) > binary.size() or binary.size() - int(buffer.byteLength) > 3:
		return {"error": "glTF buffer length does not match its data."}
	binary.resize(int(buffer.byteLength))
	buffer.erase("uri")
	if not document.get("images", []) is Array or not document.get("bufferViews", []) is Array:
		return {"error": "Invalid glTF images or buffer views."}
	if not document.has("bufferViews"): document.bufferViews = []
	if document.get("images", []).size() > 64 or document.get("bufferViews", []).size() > 1024:
		return {"error": "Too many glTF images or buffer views."}
	for image in document.get("images", []):
		if not image is Dictionary: return {"error": "Invalid glTF image."}
		if not image.has("uri"): continue
		if not image.uri is String or image.has("bufferView"):
			return {"error": "Image cannot use both URI and bufferView."}
		var source := _dependency(path, image.uri, "image")
		if source.has("error"): return source
		while binary.size() % 4 != 0: binary.append(0)
		document.bufferViews.append({"buffer": 0, "byteOffset": binary.size(), "byteLength": source.bytes.size()})
		image.bufferView = document.bufferViews.size() - 1
		image.mimeType = source.mime
		image.erase("uri")
		binary.append_array(source.bytes)
		if binary.size() > Reader.MAX_BYTES:
			return {"error": "Packed glTF exceeds the 2 MiB GLB limit."}
	buffer.byteLength = binary.size()
	var json := JSON.stringify(document).to_utf8_buffer()
	while json.size() % 4 != 0: json.append(32)
	while binary.size() % 4 != 0: binary.append(0)
	if json.size() > 262144 or 28 + json.size() + binary.size() > Reader.MAX_BYTES:
		return {"error": "Packed glTF exceeds the GLB JSON or 2 MiB file limit."}
	var result := PackedByteArray()
	result.resize(20)
	result.encode_u32(0, 0x46546c67)
	result.encode_u32(4, 2)
	result.encode_u32(8, 28 + json.size() + binary.size())
	result.encode_u32(12, json.size())
	result.encode_u32(16, 0x4e4f534a)
	result.append_array(json)
	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, binary.size())
	header.encode_u32(4, 0x004e4942)
	result.append_array(header)
	result.append_array(binary)
	return {"bytes": result}

static func _dependency(source_path: String, uri: String, kind: String) -> Dictionary:
	var mime := ""
	var bytes := PackedByteArray()
	if uri.begins_with("data:"):
		var comma := uri.find(",")
		if comma < 0 or not uri.substr(0, comma).ends_with(";base64"):
			return {"error": "Only base64 data URIs are supported."}
		mime = uri.substr(5, comma - 12)
		var encoded := uri.substr(comma + 1)
		if encoded.length() > MAX_SOURCE_BYTES:
			return {"error": "Embedded glTF dependency is oversized."}
		var pattern := RegEx.new()
		pattern.compile("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
		if pattern.search(encoded) == null:
			return {"error": "Invalid base64 data URI."}
		bytes = Marshalls.base64_to_raw(encoded)
	else:
		if uri.is_empty() or uri in [".", ".."] or uri.contains("/") or uri.contains("\\") or uri.contains(":") or uri.contains("%"):
			return {"error": "Dependencies must be files beside the glTF, without paths or URLs."}
		var file := FileAccess.open(source_path.get_base_dir().path_join(uri), FileAccess.READ)
		if file == null or file.get_length() > Reader.MAX_BYTES:
			return {"error": "Missing or oversized glTF dependency: " + uri}
		bytes = file.get_buffer(file.get_length())
		mime = "image/png" if uri.get_extension().to_lower() == "png" else ("image/jpeg" if uri.get_extension().to_lower() in ["jpg", "jpeg"] else "")
	if bytes.is_empty() or bytes.size() > Reader.MAX_BYTES:
		return {"error": "Empty or oversized glTF dependency."}
	if kind == "image" and mime not in ["image/png", "image/jpeg"]:
		return {"error": "Only PNG and JPEG glTF images are supported."}
	return {"bytes": bytes, "mime": mime}
