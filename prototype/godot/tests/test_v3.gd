extends RefCounted
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const Demo = preload("res://domain/demo_region.gd")
const View = preload("res://adapters/world_view.gd")
const EnvironmentView = preload("res://adapters/environment_view.gd")
const Avatar = preload("res://client/avatar.gd")

func run(suite: SceneTree) -> void:
	var demo := Demo.create()
	suite.check(Schema.validate(demo).is_empty() and demo.objects.size() > 30, "V3 demonstration satisfies the complete portable schema")
	var service = Service.new(suite.output_dir + "/v3-state.json")
	var original: Dictionary = service.model.snapshot()
	var result: Dictionary = service.request("UpdateEnvironment", {"patch": {"sun_hour": 20.0, "water_enabled": true, "water_height": -2.0}})
	suite.check(result.ok and service.model.snapshot().environment.sun_hour == 20, "environment command changes validated persistent settings")
	suite.check(service.model.snapshot().objects == original.objects and service.model.snapshot().terrain == original.terrain, "environment changes preserve terrain and objects")
	var history: Dictionary = service.history_state()
	suite.check(service.request("UpdateEnvironment", {"patch": {"sun_hour": 20.0}}).ok and service.history_state() == history, "identical environment state creates no history entry")
	for patch in [{"sun_hour": 25}, {"sun_hour": NAN}, {"water_height": -41}, {"water_enabled": 1}, {"terrain_grid": 0}, {"fog_density": -1}, {"terrain_grid": "yes"}, {"script": "anything"}]:
		var before: Dictionary = service.model.snapshot()
		suite.check(not service.request("UpdateEnvironment", {"patch": patch}).ok and service.model.snapshot() == before, "invalid environment patch rejected atomically: " + str(patch.keys()[0]) + ":" + str(patch.values()[0]))
	service.actor = Schema.uuid()
	suite.check(not service.request("UpdateEnvironment", {"patch": {"sun_hour": 12}}).ok, "environment command requires region ownership")
	service.actor = Schema.OWNER
	suite.check(service.request("Undo").ok and service.model.snapshot().environment == original.environment, "environment undo restores all settings")
	suite.check(service.request("Redo").ok and service.model.snapshot().environment.sun_hour == 20, "environment redo restores all settings")
	for kind in Schema.KINDS:
		var item := Schema.primitive(kind, "catalog " + kind, [60, 60, 3], [3, 2, 4], "#AABBAA", "metal")
		suite.check(service.request("CreateObject", {"object": item}).ok, "built-in asset accepts valid geometry: " + kind)
	var door := Schema.primitive("door", "physics door", [90, 108, 1.6], [3, 0.3, 3.2], "#779999", "metal")
	service.request("CreateObject", {"object": door})
	var command := {"api_version": 1, "request_id": Schema.uuid(), "operation": "SetObjectState", "expected_revision": service.model.revision(), "payload": {"id": door.id, "active": true}}
	result = service.dispatch(command)
	suite.check(result.ok and service.model.object(door.id).state.active and service.dispatch(command) == result, "door state and request replay are deterministic")
	history = service.history_state()
	suite.check(service.request("SetObjectState", {"id": door.id, "active": true}).ok and service.history_state() == history, "repeated target door state is a no-op")
	for payload in [{"id": door.id, "active": 1}, {"id": door.id, "active": true, "script": "x"}, {"id": original.objects[0].id, "active": true}]:
		var before: Dictionary = service.model.snapshot()
		suite.check(not service.request("SetObjectState", payload).ok and service.model.snapshot() == before, "invalid object behavior request preserves state: " + str(payload))
	service.actor = Schema.uuid()
	suite.check(not service.request("SetObjectState", {"id": door.id, "active": false}).ok, "object behavior requires local ownership")
	service.actor = Schema.OWNER
	suite.check(not service.request("UpdateObject", {"id": door.id, "patch": {"state": {"active": false}}}).ok, "ordinary attribute patches cannot bypass the behavior command")
	suite.check(not service.request("UpdateObject", {"id": door.id, "patch": {"material": "external://x"}}).ok, "material registry rejects external resources")
	suite.check(service.request("SaveRegion").ok, "V3 environment and behavior state save successfully")
	var reader = Service.new(service.repository.path)
	suite.check(reader.request("LoadRegion").ok and suite._same_data(service.model.snapshot(), reader.model.snapshot()), "V3 state restores with stable IDs and numeric precision")
	await _physics(suite, door)
	_migration(suite)

func _migration(suite: SceneTree) -> void:
	var source := ProjectSettings.globalize_path("res://../fixtures/v1-region.snapshot.json")
	var path: String = suite.output_dir + "/v3-migration.json"
	DirAccess.copy_absolute(source, path)
	var original_hash := FileAccess.get_sha256(path)
	var service = Service.new(path)
	var result: Dictionary = service.request("LoadRegion")
	suite.check(result.ok and result.payload.migrated and service.dirty and service.model.snapshot().schema_version == Schema.VERSION, "legacy snapshot upgrade is explicit and requires a save")
	suite.check(FileAccess.get_sha256(path) == original_hash, "loading an older snapshot never rewrites its original bytes")
	var legacy: Dictionary = JSON.parse_string(JSON.parse_string(FileAccess.get_file_as_string(source)).world_json)
	var upgraded: Dictionary = service.model.snapshot()
	suite.check(suite._same_data(legacy.terrain, upgraded.terrain) and legacy.revision == upgraded.revision and legacy.objects[0].id == upgraded.objects[0].id, "migration preserves terrain, revision and object identity")
	suite.check(service.request("SaveRegion").ok and FileAccess.get_sha256(path + ".bak") == original_hash, "saving upgraded data retains the original version as backup")
	var v2: String = suite.output_dir + "/v2-migration.json"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://../fixtures/v2-region.snapshot.json"), v2)
	var v2_reader = Service.new(v2)
	var v2_result: Dictionary = v2_reader.request("LoadRegion")
	suite.check(v2_result.ok and v2_result.payload.migrated and v2_reader.model.snapshot().terrain.heights[1320] == 8, "actual V2 snapshot preserves sculpted elevation during upgrade")
	suite.check(v2_reader.request("SaveRegion").ok and v2_reader.request("LoadRegion").ok and v2_reader.model.snapshot().terrain.heights[1320] == 8, "upgraded V2 terrain survives resave and reload")
	legacy.objects[0].script = "invalid legacy field"
	suite.check(Schema.upgrade(legacy).has("error"), "legacy migration validates old records before adding defaults")
	legacy.erase("objects")
	suite.check(Schema.upgrade(legacy).has("error"), "malformed legacy snapshots cannot be migrated")
	upgraded.schema_version = Schema.VERSION + 1
	suite.check(Schema.upgrade(upgraded).has("error"), "future snapshot versions cannot be coerced to V3")

func _physics(suite: SceneTree, door: Dictionary) -> void:
	var world := Schema.seed()
	world.terrain.heights.fill(0.0)
	world.objects = [door]
	var view = View.new()
	suite.root.add_child(view)
	view.rebuild(world)
	var environment = EnvironmentView.new()
	suite.root.add_child(environment)
	var env := Schema.default_environment()
	env.water_enabled = true
	env.water_height = 2.5
	environment.sync(env)
	view.sync_environment(env)
	suite.check(environment.water.visible and environment.water.position.y == 2.5, "persistent water height reaches rendered surface")
	var day: float = environment.sun.light_energy
	env.sun_hour = 0
	environment.sync(env)
	suite.check(day > 0 and environment.sun.light_energy == 0, "night setting removes direct sunlight")
	for i in range(4):
		await suite.physics_frame
	var ray := PhysicsRayQueryParameters3D.create(Vector3(90, 1.5, -104), Vector3(90, 1.5, -112), 2)
	suite.check(not view.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(), "closed door blocks a native physics ray")
	var player = Avatar.new()
	suite.root.add_child(player)
	player.reset_spawn(Vector3(90, 0.1, -104))
	player.active = true
	Input.action_press("move_forward")
	for i in range(60):
		await suite.physics_frame
	Input.action_release("move_forward")
	suite.check(player.position.z > -107.7, "closed door blocks the actual avatar capsule")
	door.state.active = true
	view.sync_objects([door])
	for i in range(4):
		await suite.physics_frame
	suite.check(view.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(), "opened door removes collision from its central passage")
	Input.action_press("move_forward")
	for i in range(60):
		await suite.physics_frame
	Input.action_release("move_forward")
	suite.check(player.position.z < -111, "avatar can pass through the opened door")
	var lamp := Schema.primitive("lamp", "light", [95, 108, 2], [1, 1, 4], "#666666")
	view.sync_objects([door, lamp])
	suite.check(view.bodies[lamp.id].get_node("LampLight").light_energy > 0, "active lamp creates a native local light")
	lamp.state.active = false
	view.sync_objects([door, lamp])
	suite.check(view.bodies[lamp.id].get_node("LampLight").light_energy == 0, "inactive lamp removes local illumination")
	var ball := Schema.primitive("sphere", "ellipsoid", [100, 108, 2], [4, 2, 4], "#CCCCCC")
	view.sync_objects([ball])
	for i in range(4):
		await suite.physics_frame
	ray = PhysicsRayQueryParameters3D.create(Vector3(100, 8, -108), Vector3(100, -1, -108), 2)
	var hit: Dictionary = view.get_world_3d().direct_space_state.intersect_ray(ray)
	suite.check(not hit.is_empty() and abs(hit.position.y - 4.0) < 0.03, "ellipsoid collider bakes nonuniform metric dimensions")
	ray = PhysicsRayQueryParameters3D.create(Vector3(101.8, 8, -108.8), Vector3(101.8, -1, -108.8), 2)
	suite.check(view.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(), "ellipsoid collider does not behave like its bounding box")
	player.free()
	environment.free()
	view.free()
	await suite.process_frame
