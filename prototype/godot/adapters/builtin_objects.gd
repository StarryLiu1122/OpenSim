extends RefCounted
## Closed asset registry: geometry and colliders are created together in metres.
const Schema = preload("res://domain/world_schema.gd")
const SURFACE = preload("res://adapters/surface.gdshader")

static func build(body: StaticBody3D, item: Dictionary) -> void:
	var d := Vector3(item.size[0], item.size[2], item.size[1])
	var material := ShaderMaterial.new()
	material.shader = SURFACE
	material.set_shader_parameter("tint", Color(item.color))
	material.set_shader_parameter("surface_kind", Schema.MATERIALS.find(item.material))
	match Schema.kind(item.asset_id):
		"box":
			_box(body, d, Vector3.ZERO, material)
		"sphere", "cylinder":
			_round(body, d, Vector3.ZERO, material, Schema.kind(item.asset_id) == "sphere", true)
		"tree":
			var bark := _color(Color("66503a"))
			_round(body, Vector3(d.x * 0.12, d.y * 0.6, d.z * 0.12), Vector3(0, -d.y * 0.2, 0), bark, false, true)
			material.set_shader_parameter("surface_kind", 5)
			_round(body, Vector3(d.x * 0.72, d.y * 0.55, d.z * 0.74), Vector3(0, d.y * 0.225, 0), material, true, false)
			for index in range(5):
				var angle := float(index) * TAU / 5.0
				var offset := Vector3(cos(angle) * d.x * 0.18, d.y * (0.05 + float(index % 3) * 0.05), sin(angle) * d.z * 0.18)
				_round(body, Vector3(d.x * 0.6, d.y * 0.40, d.z * 0.6), offset, material, true, false)
		"door":
			var frame := _color(Color("36454a"))
			for side in [-1, 1]:
				_box(body, Vector3(d.x * 0.06, d.y, d.z), Vector3(side * d.x * 0.47, 0, 0), frame)
				# Two telescopic leaves park inside the jamb envelope when opened.
				var width := d.x * (0.04 if item.state.active else 0.44)
				var offset := d.x * (0.42 if item.state.active else 0.22)
				_box(body, Vector3(width, d.y * 0.94, d.z * 0.55), Vector3(side * offset, -d.y * 0.03, 0), material)
			_box(body, Vector3(d.x, d.y * 0.06, d.z), Vector3(0, d.y * 0.47, 0), frame)
		"lamp":
			var pole := _round(body, Vector3(d.x * 0.22, d.y * 0.85, d.z * 0.22), Vector3(0, -d.y * 0.075, 0), material, false, true)
			# A point emitter inside the fixture must not project its own pole as a dark disk.
			pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var glow := _color(Color("fff0c0") if item.state.active else Color("9faaa8"))
			glow.emission_enabled = item.state.active
			glow.emission = Color("ffd692")
			glow.emission_energy_multiplier = 1.5
			var bulb := _round(body, Vector3(d.x, d.y * 0.15, d.z), Vector3(0, d.y * 0.425, 0), glow, true, false)
			bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var light := OmniLight3D.new()
			light.name = "LampLight"
			light.position.y = d.y * 0.38
			light.shadow_enabled = true
			light.light_color = Color("ffdc9e")
			light.light_energy = 0.85 if item.state.active else 0.0
			light.omni_range = clampf(d.y * 3.0, 3.0, 18.0)
			body.add_child(light)

static func _color(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.65
	return material

static func _box(body: StaticBody3D, size: Vector3, position: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.position = position
	visual.material_override = material
	body.add_child(visual)
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	collider.position = position
	body.add_child(collider)

static func _round(body: StaticBody3D, size: Vector3, position: Vector3, material: Material, sphere: bool, solid: bool) -> MeshInstance3D:
	var mesh: PrimitiveMesh
	if sphere:
		var ball := SphereMesh.new()
		ball.radius = 0.5
		ball.height = 1.0
		ball.radial_segments = 20
		ball.rings = 12
		mesh = ball
	else:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.5
		cylinder.bottom_radius = 0.5
		cylinder.height = 1.0
		cylinder.radial_segments = 20
		mesh = cylinder
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.position = position
	visual.scale = size
	visual.material_override = material
	body.add_child(visual)
	if solid:
		# Bake nonuniform scale into the convex shape, rather than scaling physics bodies.
		var points := PackedVector3Array()
		for point in mesh.get_faces():
			points.append(point * size)
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		var collider := CollisionShape3D.new()
		collider.shape = shape
		collider.position = position
		body.add_child(collider)
	return visual
