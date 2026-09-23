extends RefCounted
const Assets = preload("res://adapters/mesh_assets.gd")
var cache: Dictionary = {}

func prepare(assets: Array) -> void:
	var present: Dictionary = {}
	for asset in assets:
		if asset.kind == "mesh":
			present[asset.id] = true
			if not cache.has(asset.id):
				var data := Assets.read(asset)
				if data.has("error"):
					push_error(data.error)
					continue
				cache[asset.id] = data
	for id in cache.keys():
		if not present.has(id):
			cache.erase(id)

func build(body: StaticBody3D, item: Dictionary) -> void:
	var data: Dictionary = cache[item.asset_id]
	var size := Vector3(item.size[0], item.size[2], item.size[1])
	var source_size := Vector3(data.bounds[0], data.bounds[2], data.bounds[1])
	for surface in data.surfaces:
		var visual := MeshInstance3D.new()
		var source: Dictionary = surface.material
		visual.mesh = _mesh(surface, size, source_size, not source.normal.is_empty())
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
	for surface in data.collision:
		var collider := CollisionShape3D.new()
		var faces := PackedVector3Array()
		faces.resize(surface.indices.size())
		for index in range(surface.indices.size()): faces[index] = surface.vertices[surface.indices[index]] * size
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		collider.shape = shape
		body.add_child(collider)

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
	var picture := Image.new()
	if source.mime == "image/png": picture.load_png_from_buffer(source.bytes)
	else: picture.load_jpg_from_buffer(source.bytes)
	picture.generate_mipmaps()
	return ImageTexture.create_from_image(picture)
