extends Node3D
## Local-only placement outline. It never contributes collision or world state.
const View = preload("res://adapters/world_view.gd")

var volume := MeshInstance3D.new()
var outline := MeshInstance3D.new()
var ink := StandardMaterial3D.new()
var line_ink := StandardMaterial3D.new()

func _ready() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	volume.mesh = box
	ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ink.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ink.albedo_color = Color(0.27, 0.88, 0.67, 0.24)
	ink.cull_mode = BaseMaterial3D.CULL_DISABLED
	volume.material_override = ink
	add_child(volume)
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for axis in range(3):
		for first in [-0.5, 0.5]:
			for second in [-0.5, 0.5]:
				var start := Vector3.ZERO
				start[axis] = -0.5
				start[(axis + 1) % 3] = first
				start[(axis + 2) % 3] = second
				var end := start
				end[axis] = 0.5
				lines.surface_add_vertex(start)
				lines.surface_add_vertex(end)
	lines.surface_end()
	outline.mesh = lines
	line_ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_ink.albedo_color = Color("78e6bc")
	outline.material_override = line_ink
	add_child(outline)
	visible = false

func show_pose(world_position: Array, world_size: Array, world_rotation: Array, valid: bool) -> void:
	position = View.to_engine(world_position)
	basis = View.rotation_to_engine(world_rotation)
	var dimensions := Vector3(world_size[0], world_size[2], world_size[1])
	volume.scale = dimensions
	outline.scale = dimensions + Vector3.ONE * 0.02
	ink.albedo_color = Color(0.27, 0.88, 0.67, 0.24) if valid else Color(1.0, 0.29, 0.28, 0.28)
	line_ink.albedo_color = Color("78e6bc") if valid else Color("ff7773")
	visible = true

func hide_pose() -> void:
	visible = false
