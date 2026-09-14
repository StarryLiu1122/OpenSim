extends RefCounted
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const View = preload("res://adapters/world_view.gd")
const Avatar = preload("res://client/avatar.gd")

func stamp(mode: String = "raise", center: Array = [80.0, 80.0], strength: float = 0.5) -> Dictionary:
	return {"mode": mode, "center": center, "radius": 12.0, "strength": strength, "target_height": 8.0}

func run(suite: SceneTree) -> void:
	var service = Service.new(suite.output_dir + "/terrain.json")
	var flat: Dictionary = Schema.seed()
	flat.terrain.heights.fill(0.0)
	service.model.replace(flat)
	var index := 20 * 65 + 20
	var payload := stamp()
	var command := {"api_version": 1, "request_id": Schema.uuid(), "operation": "SculptTerrain", "expected_revision": 0, "payload": payload}
	var raised: Dictionary = service.dispatch(command)
	var world: Dictionary = service.model.snapshot()
	suite.check(raised.ok and world.terrain.heights[index] == 4.0, "terrain raise uses bounded metric displacement")
	suite.check(world.terrain.heights[index + 1] > 0 and world.terrain.heights[index + 1] < 4, "terrain brush has a radial falloff")
	suite.check(world.terrain.heights[index + 3] == 0 and world.terrain.heights[0] == 0, "samples outside brush radius remain unchanged")
	suite.check(world.objects == flat.objects and world.region == flat.region, "terrain edits preserve object transforms and region identity")
	suite.check(service.dispatch(command) == raised and service.model.revision() == 1, "terrain request replay does not stamp twice")
	var before: Dictionary = world.duplicate(true)
	for key in ["mode", "radius", "strength", "center", "target_height", "extra"]:
		var invalid := stamp()
		match key:
			"mode": invalid.mode = "execute"
			"radius": invalid.radius = 0
			"strength": invalid.strength = NAN
			"center": invalid.center = [-1, 80]
			"target_height": invalid.target_height = 100
			"extra": invalid.extra = true
		suite.check(not service.request("SculptTerrain", invalid).ok, "terrain rejects invalid " + key)
	suite.check(service.model.snapshot() == before and service.history_state().undo == 1, "rejected terrain edits preserve state and history")
	service.actor = Schema.uuid()
	suite.check(not service.request("SculptTerrain", stamp()).ok, "terrain editing requires region ownership")
	service.actor = Schema.OWNER
	suite.check(service.request("Undo").ok and service.model.snapshot().terrain == flat.terrain, "undo restores entire terrain stamp")
	suite.check(service.request("Redo").ok and service.model.snapshot().terrain == before.terrain and service.model.revision() == 3, "redo restores terrain with a new revision")
	service.request("Undo")
	service.request("SculptTerrain", stamp("lower"))
	suite.check(service.model.snapshot().terrain.heights[index] == -4 and not service.request("Redo").ok, "new terrain edit invalidates redo history")
	service.request("SculptTerrain", stamp("flatten", [80.0, 80.0], 1.0))
	suite.check(service.model.snapshot().terrain.heights[index] == 8, "flatten reaches target elevation at full-strength center")
	var spiked: Dictionary = flat.duplicate(true)
	spiked.terrain.heights[index] = 9.0
	service = Service.new(suite.output_dir + "/smooth.json")
	service.model.replace(spiked)
	service.request("SculptTerrain", stamp("smooth", [80.0, 80.0], 1.0))
	var smoothed: Dictionary = service.model.snapshot()
	suite.check(smoothed.terrain.heights[index] == 1, "smooth reads the pre-stamp 3 by 3 neighborhood")
	suite.check(smoothed.terrain.heights[index - 1] == smoothed.terrain.heights[index + 1], "smoothing is independent of iteration direction")
	var edge := stamp("raise", [256.0, 256.0])
	suite.check(service.request("SculptTerrain", edge).ok and service.model.snapshot().terrain.heights[-1] == 4, "brush safely clips at northeast region boundary")
	var ceiling: Dictionary = flat.duplicate(true)
	ceiling.terrain.heights.fill(80.0)
	service = Service.new(suite.output_dir + "/limit.json")
	service.model.replace(ceiling)
	service.request("SaveRegion")
	var unchanged: Dictionary = service.request("SculptTerrain", stamp())
	suite.check(unchanged.ok and not unchanged.payload.changed and not service.dirty and service.model.revision() == 0 and service.history_state().undo == 0, "clamped no-op preserves saved state and revision")
	service.request("SculptTerrain", stamp("lower"))
	service.request("Undo")
	service.request("SculptTerrain", stamp())
	suite.check(service.history_state().redo == 1, "no-op terrain edit retains redo history")
	service.request("Redo")
	suite.check(service.request("SaveRegion").ok, "edited terrain snapshot saves successfully")
	var reader = Service.new(suite.output_dir + "/limit.json")
	suite.check(reader.request("LoadRegion").ok and suite._same_data(reader.model.snapshot().terrain, service.model.snapshot().terrain), "terrain samples round trip through snapshot within 1e-6")
	suite.check(reader.history_state() == {"undo": 0, "redo": 0}, "loading a snapshot clears both history stacks")
	for i in range(35):
		reader.request("SculptTerrain", stamp("lower"))
	suite.check(reader.history_state().undo == 30, "terrain and object history remains bounded")
	var limit: Dictionary = reader.model.snapshot()
	limit.revision = 1000000000
	reader.model.replace(limit)
	suite.check(not reader.request("SculptTerrain", stamp()).ok and reader.model.snapshot() == limit, "revision limit rejects terrain edit atomically")
	var history_before: Dictionary = reader.history_state()
	suite.check(not reader.request("Undo").ok and reader.history_state() == history_before, "revision limit preserves history after rejected undo")
	var legacy_path: String = suite.output_dir + "/v1-compatibility.json"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://../fixtures/v1-region.snapshot.json"), legacy_path)
	var legacy = Service.new(legacy_path)
	var restored: Dictionary = legacy.request("LoadRegion")
	suite.check(restored.ok and legacy.model.object("44444444-4444-4444-8444-444444444444").get("position") == [45.25, 72.5, 3.75], "V1 snapshot fixture preserves stable object identity and attributes")
	suite.check(legacy.request("SculptTerrain", stamp()).ok and legacy.request("SaveRegion").ok and legacy.request("LoadRegion").ok, "V1 snapshot supports V2 terrain edit and resave without migration")
	await _physics(suite, flat)

func _physics(suite: SceneTree, world: Dictionary) -> void:
	var service = Service.new(suite.output_dir + "/terrain-physics.json")
	service.model.replace(world)
	var view = View.new()
	suite.root.add_child(view)
	view.rebuild(world)
	var object_body: Node = view.bodies[world.objects[0].id]
	service.request("SculptTerrain", stamp("flatten", [80.0, 80.0], 1.0))
	view.sync_terrain(service.model.snapshot().terrain, world.region.size)
	for frame in range(4):
		await suite.physics_frame
	suite.check(view.bodies[world.objects[0].id] == object_body, "terrain synchronization preserves existing object bodies")
	var ray := PhysicsRayQueryParameters3D.create(Vector3(80, 90, -80), Vector3(80, -50, -80), 1)
	var hit := view.get_world_3d().direct_space_state.intersect_ray(ray)
	suite.check(not hit.is_empty() and abs(hit.position.y - 8.0) < 0.002, "terrain edit updates native Jolt collision elevation")
	var arrays: Array = view.get_node("TerrainVisual").mesh.surface_get_arrays(0)
	suite.check(abs(arrays[Mesh.ARRAY_VERTEX][20 * 65 + 20].y - 8.0) < 0.002, "terrain edit updates rendered mesh elevation")
	service.request("Undo")
	view.sync_terrain(service.model.snapshot().terrain, world.region.size)
	for frame in range(4):
		await suite.physics_frame
	hit = view.get_world_3d().direct_space_state.intersect_ray(ray)
	suite.check(not hit.is_empty() and abs(hit.position.y) < 0.002, "undo updates Jolt terrain collision")
	# A nonplanar cell distinguishes triangle interpolation from bilinear sampling.
	var saddle: Dictionary = world.terrain.duplicate(true)
	saddle.heights[20 * 65 + 21] = 10.0
	view.sync_terrain(saddle, world.region.size)
	for frame in range(4):
		await suite.physics_frame
	for point in [Vector2(81, 81), Vector2(83, 83), Vector2(81, 83), Vector2(83, 81)]:
		ray = PhysicsRayQueryParameters3D.create(Vector3(point.x, 90, -point.y), Vector3(point.x, -50, -point.y), 1)
		hit = view.get_world_3d().direct_space_state.intersect_ray(ray)
		suite.check(not hit.is_empty() and abs(hit.position.y - view.ground_height(point.x, point.y)) < 0.002, "mesh triangle and Jolt agree within nonplanar cell " + str(point))
	saddle.heights[-1] = 7.0
	view.sync_terrain(saddle, world.region.size)
	suite.check(view.ground_height(256, 256) == 7, "height query includes exact northeast boundary sample")
	service.request("Redo")
	view.sync_terrain(service.model.snapshot().terrain, world.region.size)
	var avatar = Avatar.new()
	suite.root.add_child(avatar)
	avatar.reset_spawn(Vector3(80, 16, -80))
	for frame in range(150):
		await suite.physics_frame
	suite.check(avatar.is_on_floor() and abs(avatar.position.y - 8.0) < 0.2, "avatar lands on edited terrain through native physics")
	avatar.free()
	view.free()
	await suite.process_frame
