extends RefCounted
## Bounded Wavefront OBJ + same-directory MTL/PNG/JPEG to portable GLB.
const Reader = preload("res://adapters/glb_reader.gd")
const MAX_SOURCE_BYTES := 4 * 1024 * 1024
const MAX_TRIANGLES := 20000

static func read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 1 or file.get_length() > MAX_SOURCE_BYTES:
		return {"error": "OBJ must be readable and at most 4 MiB."}
	var positions: Array[Vector3] = []
	var texcoords: Array[Vector2] = []
	var surfaces: Dictionary = {}
	var active := "default"
	var materials: Dictionary = {}
	var triangles := 0
	for line in file.get_as_text().split("\n"):
		var parts := line.strip_edges().replace("\t", " ").split(" ", false)
		if parts.is_empty(): continue
		match parts[0]:
			"mtllib":
				if parts.size() != 2 or not _safe_name(parts[1]): return {"error": "MTL must be a file beside the OBJ."}
				var loaded := _materials(path, parts[1])
				if loaded.has("error"): return loaded
				materials.merge(loaded, true)
			"usemtl":
				if parts.size() != 2: return {"error": "Invalid OBJ material name."}
				active = parts[1]
			"v":
				if parts.size() < 4 or not _float(parts[1]) or not _float(parts[2]) or not _float(parts[3]): return {"error": "Invalid OBJ vertex."}
				positions.append(Vector3(float(parts[1]), float(parts[2]), float(parts[3])))
				if positions.size() > 60000: return {"error": "OBJ has too many vertices."}
			"vt":
				if parts.size() < 3 or not _float(parts[1]) or not _float(parts[2]): return {"error": "Invalid OBJ UV."}
				texcoords.append(Vector2(float(parts[1]), 1.0 - float(parts[2])))
			"f":
				if parts.size() < 4 or parts.size() > 9: return {"error": "OBJ faces must have 3–8 vertices."}
				var polygon: Array = []
				for token in parts.slice(1):
					var components := str(token).split("/", true)
					var vertex := _index(components[0], positions.size())
					var uv := _index(components[1], texcoords.size()) if components.size() > 1 and not components[1].is_empty() else -1
					if vertex < 0 or (components.size() > 1 and not components[1].is_empty() and uv < 0): return {"error": "OBJ face references a missing vertex or UV."}
					polygon.append([positions[vertex], texcoords[uv] if uv >= 0 else Vector2.ZERO])
				if not surfaces.has(active): surfaces[active] = {"vertices": PackedVector3Array(), "uv": PackedVector2Array()}
				for corner in range(1, polygon.size() - 1):
					for member in [polygon[0], polygon[corner], polygon[corner + 1]]:
						surfaces[active].vertices.append(member[0])
						surfaces[active].uv.append(member[1])
					triangles += 1
					if triangles > MAX_TRIANGLES: return {"error": "OBJ exceeds 20,000 triangles; split the scene into tiles."}
	if triangles == 0 or surfaces.size() > 32: return {"error": "OBJ requires 1–32 nonempty material groups."}
	var mesh := ArrayMesh.new()
	for name in surfaces:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surfaces[name].vertices
		arrays[Mesh.ARRAY_TEX_UV] = surfaces[name].uv
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var description: Dictionary = materials.get(name, {})
		var surface_material := StandardMaterial3D.new()
		surface_material.albedo_color = description.get("color", Color.WHITE)
		if description.has("texture"):
			var texture_path: String = path.get_base_dir().path_join(description.texture)
			var image := Image.new()
			if image.load(texture_path) != OK or image.get_width() > 1024 or image.get_height() > 1024:
				return {"error": "OBJ texture must be a readable PNG or JPEG within 1024 pixels per side."}
			surface_material.albedo_texture = ImageTexture.create_from_image(image)
		mesh.surface_set_material(mesh.get_surface_count() - 1, surface_material)
	var instance := MeshInstance3D.new()
	instance.name = "ImportedOBJ"
	instance.mesh = mesh
	var document := GLTFDocument.new()
	document.image_format = "JPEG"
	var state := GLTFState.new()
	if document.append_from_scene(instance, state) != OK:
		instance.free()
		return {"error": "Could not convert OBJ to glTF."}
	var bytes := _remove_godot_marker(document.generate_buffer(state))
	instance.free()
	if bytes.is_empty() or bytes.size() > Reader.MAX_BYTES: return {"error": "Converted OBJ exceeds the 2 MiB GLB limit; split or simplify it."}
	return {"bytes": bytes}

static func _remove_godot_marker(source: PackedByteArray) -> PackedByteArray:
	if source.size() < 28: return PackedByteArray()
	var json_size := int(source.decode_u32(12))
	if json_size < 2 or 28 + json_size > source.size(): return PackedByteArray()
	var document: Variant = JSON.parse_string(source.slice(20, 20 + json_size).get_string_from_utf8())
	if not document is Dictionary: return PackedByteArray()
	if document.get("extensionsUsed", []) == ["GODOT_single_root"]: document.erase("extensionsUsed")
	var json := JSON.stringify(document).to_utf8_buffer()
	while json.size() % 4 != 0: json.append(32)
	var binary := source.slice(28 + json_size)
	var result := PackedByteArray()
	result.resize(20)
	result.encode_u32(0, 0x46546c67); result.encode_u32(4, 2)
	result.encode_u32(8, 28 + json.size() + binary.size())
	result.encode_u32(12, json.size()); result.encode_u32(16, 0x4e4f534a)
	result.append_array(json)
	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, binary.size()); header.encode_u32(4, 0x004e4942)
	result.append_array(header); result.append_array(binary)
	return result

static func _materials(obj_path: String, name: String) -> Dictionary:
	var path := obj_path.get_base_dir().path_join(name)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 262144: return {"error": "MTL is missing or exceeds 256 KiB."}
	var result: Dictionary = {}
	var active := ""
	for line in file.get_as_text().split("\n"):
		var parts := line.strip_edges().replace("\t", " ").split(" ", false)
		if parts.is_empty(): continue
		match parts[0]:
			"newmtl":
				if parts.size() != 2: return {"error": "Invalid MTL material name."}
				active = parts[1]
				result[active] = {"color": Color.WHITE}
			"Kd":
				if active.is_empty() or parts.size() != 4 or not _float(parts[1]) or not _float(parts[2]) or not _float(parts[3]): return {"error": "Invalid MTL diffuse color."}
				result[active].color = Color(clampf(float(parts[1]), 0, 1), clampf(float(parts[2]), 0, 1), clampf(float(parts[3]), 0, 1))
			"map_Kd":
				if active.is_empty() or parts.size() != 2 or not _safe_name(parts[1]) or parts[1].get_extension().to_lower() not in ["png", "jpg", "jpeg"]: return {"error": "MTL texture must be a same-directory PNG or JPEG."}
				var texture := FileAccess.open(obj_path.get_base_dir().path_join(parts[1]), FileAccess.READ)
				if texture == null or texture.get_length() > 1024 * 1024: return {"error": "OBJ texture is missing or exceeds 1 MiB."}
				result[active].texture = parts[1]
	return result

static func _safe_name(name: String) -> bool:
	return not name.is_empty() and name not in [".", ".."] and not name.contains("/") and not name.contains("\\") and not name.contains(":") and not name.contains("%")

static func _float(value: String) -> bool:
	return value.is_valid_float() and is_finite(float(value)) and absf(float(value)) < 10000000

static func _index(value: String, length: int) -> int:
	if not value.is_valid_int(): return -1
	var number := int(value)
	var result := number - 1 if number > 0 else length + number
	return result if number != 0 and result >= 0 and result < length else -1
