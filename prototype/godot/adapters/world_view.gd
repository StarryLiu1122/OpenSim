extends Node3D
## The only place that translates portable world records into Godot nodes/physics.
const COORDINATES := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
const Builtins = preload("res://adapters/builtin_objects.gd")
const T = preload("res://domain/world_transforms.gd")
var mesh_view = preload("res://adapters/mesh_view.gd").new()
var bodies: Dictionary = {}
var _records: Dictionary = {}
var selected := ""
var _terrain: Dictionary
var _region_size := Vector2(256, 256)
var _brush: MeshInstance3D
var _brush_key := ""

static func to_engine(value: Array) -> Vector3:
	return Vector3(value[0], value[2], -value[1])

static func to_world(value: Vector3) -> Array:
	return [value.x, -value.z, value.y]

static func rotation_to_engine(value: Array) -> Basis:
	return COORDINATES * Basis(Quaternion(value[0], value[1], value[2], value[3])) * COORDINATES.inverse()

func rebuild(world: Dictionary) -> void:
	for child in get_children():
		child.free()
	bodies.clear()
	_records.clear()
	_brush = null
	_brush_key = ""
	_terrain = {}
	_region_size = Vector2(world.region.size[0], world.region.size[1])
	sync_terrain(world.terrain, world.region.size)
	_build_boundary(world.region.size)
	sync_objects(world.objects, world.groups, world.assets)

func sync_terrain(terrain: Dictionary, region_size: Array) -> bool:
	_region_size = Vector2(region_size[0], region_size[1])
	if _terrain == terrain:
		return false
	for node_name in ["TerrainVisual", "TerrainPhysics"]:
		var node := get_node_or_null(NodePath(node_name))
		if node != null:
			node.free()
	_terrain = terrain.duplicate(true)
	_build_terrain({"region": {"size": region_size}})
	_brush_key = ""
	return true

func sync_objects(objects: Array, groups: Array = [], assets: Array = []) -> void:
	if not assets.is_empty():
		mesh_view.prepare(assets)
	var current: Dictionary = {}
	for record in objects:
		var item := T.resolve(record, groups)
		current[item.id] = true
		if not bodies.has(item.id):
			var body := StaticBody3D.new()
			body.set_meta("world_id", item.id)
			body.collision_layer = 2
			body.collision_mask = 4
			_build_object(body, item)
			var outline := MeshInstance3D.new()
			outline.name = "Outline"
			var lines := ImmediateMesh.new()
			var ink := StandardMaterial3D.new()
			ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			ink.albedo_color = Color("efb85b")
			outline.material_override = ink
			lines.surface_begin(Mesh.PRIMITIVE_LINES)
			for axis in range(3):
				for a in [-0.5, 0.5]:
					for b in [-0.5, 0.5]:
						var start := Vector3.ZERO
						start[axis] = -0.5
						start[(axis + 1) % 3] = a
						start[(axis + 2) % 3] = b
						var end := start
						end[axis] = 0.5
						lines.surface_add_vertex(start)
						lines.surface_add_vertex(end)
			lines.surface_end()
			outline.mesh = lines
			body.add_child(outline)
			add_child(body)
			bodies[item.id] = body
			_records[item.id] = item.duplicate(true)
		var body: StaticBody3D = bodies[item.id]
		body.position = to_engine(item.position)
		body.basis = rotation_to_engine(item.rotation)
		var dimensions := Vector3(item.size[0], item.size[2], item.size[1])
		if _records.get(item.id) != item:
			for child in body.get_children():
				if child.name != "Outline":
					child.free()
			_build_object(body, item)
			_records[item.id] = item.duplicate(true)
		body.get_node("Outline").scale = dimensions + Vector3.ONE * 0.06
	for id in bodies.keys():
		if not current.has(id):
			bodies[id].free()
			bodies.erase(id)
			_records.erase(id)
	select(selected)

func select(id: String) -> void:
	selected = id
	for key in bodies:
		bodies[key].get_node("Outline").visible = key == id

func pick(camera: Camera3D, point: Vector2) -> String:
	var origin := camera.project_ray_origin(point)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(point) * 1000.0, 2)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return str(hit.collider.get_meta("world_id", "")) if not hit.is_empty() else ""

func ground_height(east: float, north: float) -> float:
	var fx := clampf(east / float(_terrain.spacing), 0, float(_terrain.columns) - 1)
	var fy := clampf(north / float(_terrain.spacing), 0, float(_terrain.rows) - 1)
	var x := mini(int(fx), int(_terrain.columns) - 2)
	var y := mini(int(fy), int(_terrain.rows) - 2)
	var width := int(_terrain.columns)
	var h: Array = _terrain.heights
	var u := fx - x
	var v := fy - y
	var a := float(h[y * width + x])
	var b := float(h[y * width + x + 1])
	var c := float(h[(y + 1) * width + x])
	var d := float(h[(y + 1) * width + x + 1])
	# Match the mesh triangle diagonal instead of bilinear interpolation.
	return a + (b - a) * u + (c - a) * v if u + v <= 1.0 else d + (c - d) * (1.0 - u) + (b - d) * (1.0 - v)

func pick_terrain(camera: Camera3D, point: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(point)
	return get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(point) * 1000.0, 1))

func show_brush(center: Vector2, radius: float, enabled: bool = true) -> void:
	if not enabled:
		if is_instance_valid(_brush):
			_brush.visible = false
		return
	if not is_instance_valid(_brush):
		_brush = MeshInstance3D.new()
		_brush.name = "BrushPreview"
		var ink := StandardMaterial3D.new()
		ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ink.albedo_color = Color("ffcd68")
		_brush.material_override = ink
		add_child(_brush)
	_brush.visible = true
	var key := str(center) + ":" + str(radius)
	if key == _brush_key:
		return
	_brush_key = key
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(65):
		var angle := TAU * i / 64.0
		var point := center + Vector2(cos(angle), sin(angle)) * radius
		point = point.clamp(Vector2.ZERO, _region_size)
		lines.surface_add_vertex(Vector3(point.x, ground_height(point.x, point.y) + 0.12, -point.y))
	lines.surface_end()
	_brush.mesh = lines

func _build_terrain(world: Dictionary) -> void:
	var width := int(_terrain.columns)
	var depth := int(_terrain.rows)
	var spacing := float(_terrain.spacing)
	var heights: Array = _terrain.heights
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for y in range(depth):
		for x in range(width):
			vertices.append(Vector3(x * spacing, heights[y * width + x], -y * spacing))
			var dx := (float(heights[y * width + mini(x + 1, width - 1)]) - float(heights[y * width + maxi(x - 1, 0)])) / (2.0 * spacing)
			var dy := (float(heights[mini(y + 1, depth - 1) * width + x]) - float(heights[maxi(y - 1, 0) * width + x])) / (2.0 * spacing)
			normals.append(Vector3(-dx, 1, dy).normalized())
			if x < width - 1 and y < depth - 1:
				var i := y * width + x
				indices.append_array(PackedInt32Array([i, i + width, i + 1, i + 1, i + width, i + width + 1]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var terrain_mesh := ArrayMesh.new()
	terrain_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var visual := MeshInstance3D.new()
	visual.name = "TerrainVisual"
	visual.mesh = terrain_mesh
	var material := ShaderMaterial.new()
	material.shader = load("res://adapters/terrain.gdshader")
	visual.material_override = material
	add_child(visual)
	var body := StaticBody3D.new()
	body.name = "TerrainPhysics"
	body.collision_layer = 1
	body.collision_mask = 4
	var collider := CollisionShape3D.new()
	# Reuse the exact CPU triangles. Reading them back from the uploaded mesh
	# stalls WebGL (especially Firefox) and adds no information to the collider.
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for index in range(indices.size()): faces[index] = vertices[indices[index]]
	var collision := ConcavePolygonShape3D.new()
	collision.set_faces(faces)
	collider.shape = collision
	body.add_child(collider)
	add_child(body)

func _build_boundary(size: Array) -> void:
	for i in range(4):
		var body := StaticBody3D.new()
		body.collision_layer = 8
		body.collision_mask = 4
		var collider := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		if i < 2:
			shape.size = Vector3(2, 300, size[1] + 4)
			body.position = Vector3(-1 if i == 0 else size[0] + 1, 70, -size[1] * 0.5)
		else:
			shape.size = Vector3(size[0] + 4, 300, 2)
			body.position = Vector3(size[0] * 0.5, 70, 1 if i == 2 else -size[1] - 1)
		collider.shape = shape
		body.add_child(collider)
		add_child(body)

func sync_environment(data: Dictionary) -> void:
	var material: ShaderMaterial = get_node("TerrainVisual").material_override
	material.set_shader_parameter("water_height", data.water_height if data.water_enabled else -100.0)
	material.set_shader_parameter("show_grid", data.terrain_grid)

func interaction_target(camera: Camera3D, distance: float = 4.0) -> String:
	var origin := camera.global_position
	var ray := PhysicsRayQueryParameters3D.create(origin, origin - camera.global_basis.z * distance, 3)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():
		return ""
	var id: String = hit.collider.get_meta("world_id", "")
	var record: Dictionary = _records.get(id, {})
	return id if record.get("state", {}).has("active") else ""


func _build_object(body: StaticBody3D, item: Dictionary) -> void:
	if mesh_view.cache.has(item.asset_id):
		mesh_view.build(body, item)
	else:
		Builtins.build(body, item)
