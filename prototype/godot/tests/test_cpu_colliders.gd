extends RefCounted
const Builtins = preload("res://adapters/builtin_objects.gd")
const Schema = preload("res://domain/world_schema.gd")
const View = preload("res://adapters/world_view.gd")

func run(suite: SceneTree) -> void:
	for kind in ["sphere", "cylinder"]:
		var body := StaticBody3D.new(); suite.root.add_child(body)
		Builtins.build(body, Schema.primitive(kind, "CPU hull", [128, 128, 2], [3, 2, 4], "#ffffff"))
		var visual: MeshInstance3D = body.get_child(0)
		var shape: ConvexPolygonShape3D = body.get_child(1).shape
		var reference: PackedVector3Array = visual.mesh.get_faces()
		var maximum := 0.0
		for point in shape.points:
			var closest := INF
			for expected in reference: closest = minf(closest, point.distance_to(expected * visual.scale))
			maximum = maxf(maximum, closest)
		print("CPU HULL ", kind, " ", maximum, " points ", shape.points.size(), " / ", reference.size())
		suite.check(maximum < 0.0005, kind + " CPU hull matches decoded render vertices within 0.5 millimetres")
		body.free()
	var view = View.new(); suite.root.add_child(view); view.rebuild(Schema.seed())
	var expected: PackedVector3Array = view.get_node("TerrainVisual").mesh.get_faces()
	var actual: PackedVector3Array = view.get_node("TerrainPhysics").get_child(0).shape.get_faces()
	var terrain_error := 0.0
	for index in range(mini(expected.size(), actual.size())): terrain_error = maxf(terrain_error, expected[index].distance_to(actual[index]))
	print("CPU TERRAIN ", expected.size(), " / ", actual.size(), " error ", terrain_error, " first ", expected.slice(0, 6), " / ", actual.slice(0, 6))
	suite.check(expected.size() == actual.size() and terrain_error < 0.00001, "CPU terrain preserves rendered triangle order within 10 micrometres")
	view.free()
	await suite.process_frame
