extends RefCounted
## Bounded GLB 2.0 static subset. Produces arrays; never instantiates imported nodes.
const C = preload("res://domain/schema_v2.gd")
const MAX_BYTES := 2 * 1024 * 1024
const MAX_VERTICES := 60000
var document: Dictionary
var binary: PackedByteArray
var error := ""
var surfaces: Array = []
var proxies: Array = []
var visited: Dictionary = {}
var vertex_count := 0
var index_count := 0

func parse(bytes: PackedByteArray) -> Dictionary:
	document = {}
	binary = PackedByteArray()
	error = ""
	surfaces = []
	proxies = []
	visited = {}
	vertex_count = 0
	index_count = 0
	if bytes.size() < 28 or bytes.size() > MAX_BYTES or bytes.decode_u32(0) != 0x46546c67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != bytes.size():
		return {"error": "Expected a GLB 2.0 file of at most 2 MiB."}
	var json_size := int(bytes.decode_u32(12))
	if json_size < 2 or json_size > 262144 or json_size % 4 != 0 or 28 + json_size > bytes.size() or bytes.decode_u32(16) != 0x4e4f534a:
		return {"error": "Invalid or oversized GLB JSON chunk."}
	var bin_header := 20 + json_size
	if bytes.decode_u32(bin_header + 4) != 0x004e4942 or bytes.decode_u32(bin_header) % 4 != 0 or bin_header + 8 + bytes.decode_u32(bin_header) != bytes.size():
		return {"error": "GLB requires exactly one JSON and one embedded BIN chunk."}
	var json := JSON.new()
	if json.parse(bytes.slice(20, bin_header).get_string_from_utf8()) != OK or not json.data is Dictionary:
		return {"error": "Invalid GLB JSON."}
	document = json.data
	binary = bytes.slice(bin_header + 8)
	if not document.get("asset") is Dictionary or document.asset.get("version") != "2.0" or document.asset.get("minVersion", "2.0") != "2.0":
		return {"error": "Unsupported glTF asset version."}
	for key in ["animations", "skins", "cameras", "extensionsUsed", "extensionsRequired"]:
		if document.has(key) and (not document[key] is Array or not document[key].is_empty()):
			return {"error": "Static GLB subset does not support " + key + "."}
	if _has_extensions(document):
		return {"error": "glTF extensions are outside the supported subset."}
	for key in ["buffers", "bufferViews", "accessors", "nodes", "meshes", "scenes", "materials", "images", "textures", "samplers"]:
		if not document.get(key, []) is Array or document.get(key, []).size() > 1024:
			return {"error": "Invalid GLB collection: " + key}
		for entry in document.get(key, []):
			if not entry is Dictionary:
				return {"error": "GLB collection entries must be objects."}
	if document.get("buffers", []).size() != 1 or document.buffers[0].has("uri") or not _integer(document.buffers[0].get("byteLength"), 1, binary.size()) or binary.size() - int(document.buffers[0].byteLength) > 3:
		return {"error": "Only one embedded GLB buffer is supported."}
	binary = binary.slice(0, int(document.buffers[0].byteLength))
	if document.get("nodes", []).size() > 256 or document.get("scenes", []).size() != 1 or document.get("scene", 0) != 0 or not document.scenes[0].get("nodes") is Array:
		return {"error": "Import one static scene with at most 256 nodes."}
	for root in document.scenes[0].nodes:
		_visit(root, Transform3D.IDENTITY, 0, false)
		if not error.is_empty():
			return {"error": error}
	if surfaces.is_empty():
		return {"error": "The GLB has no visible triangle geometry."}
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for surface in surfaces:
		for point in surface.vertices:
			minimum = minimum.min(point)
			maximum = maximum.max(point)
	var bounds := maximum - minimum
	if bounds.x < 0.2 or bounds.y < 0.2 or bounds.z < 0.2 or bounds.x > 32 or bounds.y > 32 or bounds.z > 32:
		return {"error": "Imported bounds must be 0.2–32 metres on each axis; export in metres."}
	var center := (minimum + maximum) * 0.5
	for surface in surfaces + proxies:
		for i in range(surface.vertices.size()):
			var point: Vector3 = surface.vertices[i]
			if point.x < minimum.x - 0.001 or point.y < minimum.y - 0.001 or point.z < minimum.z - 0.001 or point.x > maximum.x + 0.001 or point.y > maximum.y + 0.001 or point.z > maximum.z + 0.001:
				return {"error": "Collision proxies must fit inside the visible bounds."}
			surface.vertices[i] = (point - center) / bounds
	# Godot axes match glTF; portable dimensions use east, north, up.
	return {"surfaces": surfaces, "collision": proxies if not proxies.is_empty() else surfaces, "bounds": [bounds.x, bounds.z, bounds.y], "triangles": index_count / 3, "vertices": vertex_count, "collision_mode": "proxy" if not proxies.is_empty() else "visual"}

func _visit(index: Variant, parent: Transform3D, depth: int, proxy: bool) -> void:
	if not _integer(index, 0, document.get("nodes", []).size() - 1) or visited.has(index) or depth > 32:
		error = "Invalid node graph: cycle, shared child, index or depth."
		return
	visited[index] = true
	var node: Dictionary = document.nodes[int(index)]
	if node.has("skin") or node.has("camera") or node.has("weights") or not node.get("children", []) is Array or not node.get("name", "") is String:
		error = "Unsupported node or invalid children."
		return
	var local := Transform3D.IDENTITY
	if node.has("matrix"):
		if node.has("translation") or node.has("rotation") or node.has("scale") or not C.vector(node.matrix, 16, -100000, 100000) or node.matrix[3] != 0 or node.matrix[7] != 0 or node.matrix[11] != 0 or node.matrix[15] != 1:
			error = "Node matrix must be affine and cannot coexist with TRS."
			return
		local = Transform3D(Basis(Vector3(node.matrix[0], node.matrix[1], node.matrix[2]), Vector3(node.matrix[4], node.matrix[5], node.matrix[6]), Vector3(node.matrix[8], node.matrix[9], node.matrix[10])), Vector3(node.matrix[12], node.matrix[13], node.matrix[14]))
	else:
		var t: Variant = node.get("translation", [0, 0, 0])
		var r: Variant = node.get("rotation", [0, 0, 0, 1])
		var s: Variant = node.get("scale", [1, 1, 1])
		if not C.vector(t, 3, -100000, 100000) or not C.vector(r, 4, -1, 1) or not C.vector(s, 3, 0.001, 1000):
			error = "Invalid finite node transform."
			return
		var q := Quaternion(r[0], r[1], r[2], r[3])
		if abs(q.length_squared() - 1.0) > 0.001:
			error = "Node rotation must be normalized."
			return
		local = Transform3D(Basis(q).scaled_local(Vector3(s[0], s[1], s[2])), Vector3(t[0], t[1], t[2]))
	var transform := parent * local
	if not transform.is_finite() or transform.basis.determinant() <= 0.00000001:
		error = "Singular or mirrored node transforms are unsupported."
		return
	proxy = proxy or node.get("name", "").begins_with("COL_")
	if node.has("mesh"):
		if not _integer(node.mesh, 0, document.get("meshes", []).size() - 1):
			error = "Invalid mesh reference."
			return
		var mesh: Dictionary = document.meshes[int(node.mesh)]
		if mesh.has("weights") or not mesh.get("primitives") is Array or mesh.primitives.size() > 32:
			error = "Mesh must have at most 32 static primitives."
			return
		for primitive in mesh.primitives:
			_surface(primitive, transform, proxy)
			if not error.is_empty():
				return
	for child in node.get("children", []):
		_visit(child, transform, depth + 1, proxy)
		if not error.is_empty():
			return

func _surface(primitive: Variant, transform: Transform3D, proxy: bool) -> void:
	if not primitive is Dictionary or primitive.get("mode", 4) != 4 or primitive.has("targets") or not primitive.get("attributes") is Dictionary or not primitive.attributes.has("POSITION"):
		error = "Only static TRIANGLES primitives with POSITION are supported."
		return
	for key in primitive.attributes:
		if key not in ["POSITION", "NORMAL", "TEXCOORD_0"]:
			error = "Unsupported vertex attribute: " + str(key)
			return
	var positions := _accessor(primitive.attributes.POSITION, "VEC3", [5126])
	var normals := _accessor(primitive.attributes.NORMAL, "VEC3", [5126]) if primitive.attributes.has("NORMAL") else []
	var uv := _accessor(primitive.attributes.TEXCOORD_0, "VEC2", [5126]) if primitive.attributes.has("TEXCOORD_0") else []
	var indices := _accessor(primitive.indices, "SCALAR", [5121, 5123, 5125]) if primitive.has("indices") else range(positions.size())
	if not error.is_empty():
		return
	if (not normals.is_empty() and normals.size() != positions.size()) or (not uv.is_empty() and uv.size() != positions.size()) or indices.is_empty() or indices.size() % 3 != 0:
		error = "Mismatched attribute counts or triangle indices."
		return
	vertex_count += positions.size()
	if vertex_count > MAX_VERTICES or index_count + indices.size() > 60000 or surfaces.size() + proxies.size() >= 64:
		error = "Asset exceeds 60,000 vertices, 20,000 triangles or 64 surfaces including proxies."
		return
	var points := PackedVector3Array()
	var directions := PackedVector3Array()
	var uvs := PackedVector2Array()
	for i in range(positions.size()):
		points.append(transform * Vector3(positions[i][0], positions[i][1], positions[i][2]))
		if not points[-1].is_finite() or points[-1].length() > 100000:
			error = "Mesh contains invalid transformed coordinates."
			return
		if not normals.is_empty():
			var normal := transform.basis.inverse().transposed() * Vector3(normals[i][0], normals[i][1], normals[i][2])
			if normal.length_squared() < 0.000001:
				error = "Mesh contains a zero normal."
				return
			directions.append(normal.normalized())
		else:
			directions.append(Vector3.ZERO)
		uvs.append(Vector2(uv[i][0], uv[i][1]) if not uv.is_empty() else Vector2.ZERO)
	var faces := PackedInt32Array()
	for i in range(0, indices.size(), 3):
		for offset in range(3):
			if not _integer(indices[i + offset], 0, points.size() - 1):
				error = "Triangle index exceeds vertex count."
				return
		var a := int(indices[i]); var b := int(indices[i + 1]); var c := int(indices[i + 2])
		var n := (points[b] - points[a]).cross(points[c] - points[a])
		if n.length_squared() < 0.000000000001:
			continue
		if normals.is_empty():
			for vertex in [a, b, c]:
				directions[vertex] += n.normalized()
		# glTF front faces are CCW; Godot mesh front faces are clockwise.
		faces.append_array(PackedInt32Array([a, c, b]))
	if faces.is_empty():
		error = "Mesh contains no non-degenerate triangles."
		return
	index_count += faces.size()
	for i in range(directions.size()):
		directions[i] = directions[i].normalized()
	var material := _material(primitive.get("material", -1), not uv.is_empty())
	if not error.is_empty():
		return
	var surface := {"vertices": points, "normals": directions, "uvs": uvs, "indices": faces, "material": material}
	if proxy:
		proxies.append(surface)
	else:
		surfaces.append(surface)

func _accessor(index: Variant, type: String, components: Array) -> Array:
	if not _integer(index, 0, document.get("accessors", []).size() - 1):
		error = "Invalid accessor reference."
		return []
	var accessor: Dictionary = document.accessors[int(index)]
	var component: Variant = accessor.get("componentType")
	if accessor.get("type") != type or (not _integer(component, 0, 65535) or int(component) not in components) or accessor.has("sparse") or accessor.get("normalized", false) != false or not _integer(accessor.get("count"), 1, MAX_VERTICES):
		error = "Unsupported accessor type, count, normalization or sparse data."
		return []
	var view := _buffer_view(accessor.get("bufferView"))
	if not error.is_empty():
		return []
	var width := 4 if (component == 5126 or component == 5125) else (2 if component == 5123 else 1)
	var size := 3 if type == "VEC3" else (2 if type == "VEC2" else 1)
	var step: Variant = view.get("byteStride", size * width)
	var offset: Variant = accessor.get("byteOffset", 0)
	if not _integer(step, size * width, 252) or not _integer(offset, 0, view.byteLength) or int(step) % width != 0 or int(offset) % width != 0 or int(view.get("byteOffset", 0)) % width != 0 or int(offset) + (int(accessor.count) - 1) * int(step) + size * width > int(view.byteLength):
		error = "Accessor stride, alignment or byte range is invalid."
		return []
	var result: Array = []
	for i in range(int(accessor.count)):
		var row: Array = []
		for j in range(size):
			var address := int(view.get("byteOffset", 0)) + int(offset) + i * int(step) + j * width
			var value: Variant = binary.decode_float(address) if component == 5126 else (binary.decode_u32(address) if component == 5125 else (binary.decode_u16(address) if component == 5123 else binary[address]))
			if not C.number(value, -100000, 100000) and component == 5126:
				error = "Accessor contains non-finite or excessive values."
				return []
			row.append(value)
		result.append(row[0] if size == 1 else row)
	return result

func _buffer_view(index: Variant) -> Dictionary:
	if not _integer(index, 0, document.get("bufferViews", []).size() - 1):
		error = "Invalid bufferView reference."
		return {}
	var view: Dictionary = document.bufferViews[int(index)]
	if view.get("buffer") != 0 or not _integer(view.get("byteLength"), 1, binary.size()) or not _integer(view.get("byteOffset", 0), 0, binary.size()) or int(view.get("byteOffset", 0)) + int(view.byteLength) > binary.size():
		error = "bufferView is outside the embedded buffer."
		return {}
	return view

func _material(index: Variant, has_uv: bool) -> Dictionary:
	var material: Dictionary = {}
	if index != -1:
		if not _integer(index, 0, document.get("materials", []).size() - 1):
			error = "Invalid material reference."
			return {}
		material = document.materials[int(index)]
	var pbr: Variant = material.get("pbrMetallicRoughness", {})
	if not pbr is Dictionary or material.get("alphaMode", "OPAQUE") != "OPAQUE" or not material.get("doubleSided", false) is bool:
		error = "Only opaque metallic-roughness materials are supported."
		return {}
	if material.has("emissiveTexture") or material.get("emissiveFactor", [0, 0, 0]) != [0, 0, 0]:
		error = "Emissive materials are not yet supported."
		return {}
	var color: Variant = pbr.get("baseColorFactor", [1, 1, 1, 1])
	if not C.vector(color, 4, 0, 1) or color[3] != 1 or not C.number(pbr.get("metallicFactor", 1), 0, 1) or not C.number(pbr.get("roughnessFactor", 1), 0, 1):
		error = "Invalid material factors."
		return {}
	var albedo := _texture(pbr.get("baseColorTexture"), has_uv) if pbr.has("baseColorTexture") else {}
	var normal := _texture(material.get("normalTexture"), has_uv) if material.has("normalTexture") else {}
	var roughness := _texture(pbr.get("metallicRoughnessTexture"), has_uv) if pbr.has("metallicRoughnessTexture") else {}
	var occlusion := _texture(material.get("occlusionTexture"), has_uv) if material.has("occlusionTexture") else {}
	if not error.is_empty():
		return {}
	if material.has("normalTexture") and material.normalTexture.get("scale", 1) != 1:
		error = "Non-default normal scale is unsupported."
		return {}
	if material.has("occlusionTexture") and material.occlusionTexture.get("strength", 1) != 1:
		error = "Non-default occlusion strength is unsupported."
		return {}
	return {"color": color, "metallic": pbr.get("metallicFactor", 1), "roughness": pbr.get("roughnessFactor", 1), "double_sided": material.get("doubleSided", false), "albedo": albedo, "normal": normal, "metallic_roughness": roughness, "occlusion": occlusion}

func _texture(texture: Variant, has_uv: bool) -> Dictionary:
	if not texture is Dictionary or not has_uv or texture.get("texCoord", 0) != 0 or not _integer(texture.get("index"), 0, document.get("textures", []).size() - 1):
		error = "Texture requires TEXCOORD_0 and a valid reference."
		return {}
	var reference: Dictionary = document.textures[int(texture.index)]
	if not _integer(reference.get("source"), 0, document.get("images", []).size() - 1):
		error = "Invalid image reference."
		return {}
	if reference.has("sampler"):
		if not _integer(reference.sampler, 0, document.get("samplers", []).size() - 1):
			error = "Invalid sampler reference."
			return {}
		var sampler: Dictionary = document.samplers[int(reference.sampler)]
		if sampler.get("wrapS", 10497) != 10497 or sampler.get("wrapT", 10497) != 10497 or sampler.get("magFilter", 9729) != 9729 or sampler.get("minFilter", 9987) != 9987:
			error = "Only repeat wrapping and linear mipmap filtering are supported."
			return {}
	var source: Dictionary = document.images[int(reference.source)]
	var mime: Variant = source.get("mimeType", "")
	if not mime is String or mime not in ["image/png", "image/jpeg"] or source.has("uri"):
		error = "Only embedded PNG or JPEG textures are supported."
		return {}
	var view := _buffer_view(source.get("bufferView"))
	if not error.is_empty():
		return {}
	var bytes := binary.slice(int(view.get("byteOffset", 0)), int(view.get("byteOffset", 0)) + int(view.byteLength))
	if bytes.size() < 4 or bytes.size() > 1024 * 1024:
		error = "Invalid or oversized texture."
		return {}
	var image := Image.new()
	var decoded := image.load_png_from_buffer(bytes) if mime == "image/png" else image.load_jpg_from_buffer(bytes)
	if decoded != OK or image.get_width() < 1 or image.get_height() < 1 or image.get_width() > 1024 or image.get_height() > 1024:
		error = "Texture must decode within 1024 by 1024 pixels."
		return {}
	return {"bytes": bytes, "mime": mime}

static func _integer(value: Variant, low: int, high: int) -> bool:
	return C.number(value, low, high) and float(value) == floor(float(value))

static func _has_extensions(value: Variant) -> bool:
	if value is Dictionary:
		for key in value:
			if key == "extensions" and value[key] != {}:
				return true
			if _has_extensions(value[key]):
				return true
	elif value is Array:
		for entry in value:
			if _has_extensions(entry):
				return true
	return false
