extends RefCounted
const Assets = preload("res://adapters/mesh_assets.gd")
var cache: Dictionary = {}
var _asset_hashes: Dictionary = {}
var _asset_images: Dictionary = {}
var _geometry: Dictionary = {}
var _textures: Dictionary = {}

func prepare(assets: Array) -> void:
	var present: Dictionary = {}
	for asset in assets:
		if asset.kind == "mesh":
			present[asset.id] = true
			if not cache.has(asset.id) or _asset_hashes.get(asset.id, "") != asset.sha256:
				cache.erase(asset.id)
				_asset_hashes.erase(asset.id)
				_asset_images.erase(asset.id)
				_geometry.erase(asset.id)
				var data := Assets.read(asset)
				if data.has("error"):
					push_error(data.error)
					continue
				cache[asset.id] = data
				_asset_hashes[asset.id] = asset.sha256
				_asset_images[asset.id] = _image_keys(data)
	for id in cache.keys():
		if not present.has(id):
			cache.erase(id)
	for id in _asset_hashes.keys():
		if not cache.has(id): _asset_hashes.erase(id)
	for id in _asset_images.keys():
		if not cache.has(id): _asset_images.erase(id)
	for id in _geometry.keys():
		if not cache.has(id): _geometry.erase(id)
	var active_images: Dictionary = {}
	for keys in _asset_images.values():
		for key in keys:
			active_images[key] = true
	for key in _textures.keys():
		if not active_images.has(key):
			_textures.erase(key)

func build(body: StaticBody3D, item: Dictionary) -> void:
	var data: Dictionary = cache[item.asset_id]
	var size := Vector3(item.size[0], item.size[2], item.size[1])
	var sizes: Dictionary = _geometry.get(item.asset_id, {})
	if not sizes.has(size):
		sizes[size] = _build_geometry(data, size)
		_geometry[item.asset_id] = sizes
	var geometry: Dictionary = sizes[size]
	for index in range(data.surfaces.size()):
		var surface: Dictionary = data.surfaces[index]
		var visual := MeshInstance3D.new()
		var source: Dictionary = surface.material
		visual.mesh = geometry.meshes[index]
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(source.color[0], source.color[1], source.color[2], 1) * Color(item.color)
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		material.metallic = source.metallic
		material.roughness = source.roughness
		material.cull_mode = BaseMaterial3D.CULL_DISABLED if source.double_sided else BaseMaterial3D.CULL_BACK
		if not source.albedo.is_empty(): material.albedo_texture = _image_texture(source.albedo)
		if not source.normal.is_empty():
			material.normal_enabled = true
			material.normal_texture = _image_texture(source.normal)
		if not source.metallic_roughness.is_empty():
			var packed_texture := _image_texture(source.metallic_roughness)
			material.metallic_texture = packed_texture
			material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
			material.roughness_texture = packed_texture
			material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		if not source.occlusion.is_empty():
			material.ao_enabled = true
			material.ao_texture = _image_texture(source.occlusion)
			material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		visual.material_override = material
		body.add_child(visual)
	for shape in geometry.shapes:
		var collider := CollisionShape3D.new()
		collider.shape = shape
		body.add_child(collider)

func _build_geometry(data: Dictionary, size: Vector3) -> Dictionary:
	var source_size := Vector3(data.bounds[0], data.bounds[2], data.bounds[1])
	var meshes: Array[ArrayMesh] = []
	for surface in data.surfaces:
		meshes.append(_mesh(surface, size, source_size, not surface.material.normal.is_empty()))
	var shapes: Array[ConcavePolygonShape3D] = []
	for surface in data.collision:
		var faces := PackedVector3Array()
		faces.resize(surface.indices.size())
		for index in range(surface.indices.size()): faces[index] = surface.vertices[surface.indices[index]] * size
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		shapes.append(shape)
	return {"meshes": meshes, "shapes": shapes}

func _image_keys(data: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for surface in data.surfaces:
		var material: Dictionary = surface.material
		for channel in ["albedo", "normal", "metallic_roughness", "occlusion"]:
			var source: Dictionary = material[channel]
			if not source.is_empty():
				var key := _image_key(source)
				if key not in keys: keys.append(key)
	return keys

func _image_key(source: Dictionary) -> String:
	if not source.has("_cache_key"):
		source["_cache_key"] = source.mime + ":" + Assets.sha256(source.bytes)
	return source._cache_key

func _mesh(surface: Dictionary, size: Vector3, source_size: Vector3, tangent_space: bool) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for i in range(surface.vertices.size()):
		vertices.append(surface.vertices[i] * size)
		normals.append((surface.normals[i] * source_size / size).normalized())
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
	arrays[Mesh.ARRAY_INDEX] = surface.indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if tangent_space:
		var tool := SurfaceTool.new()
		tool.create_from(mesh, 0)
		tool.generate_tangents()
		return tool.commit()
	return mesh

func _image_texture(source: Dictionary) -> ImageTexture:
	var key := _image_key(source)
	if _textures.has(key): return _textures[key]
	var picture := Image.new()
	if source.mime == "image/png": picture.load_png_from_buffer(source.bytes)
	else: picture.load_jpg_from_buffer(source.bytes)
	picture.generate_mipmaps()
	var texture := ImageTexture.create_from_image(picture)
	_textures[key] = texture
	return texture
