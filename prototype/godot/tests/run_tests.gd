extends SceneTree
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const Repository = preload("res://adapters/snapshot_repository.gd")
const WorldView = preload("res://adapters/world_view.gd")
const Avatar = preload("res://client/avatar.gd")

var cases: Array[Dictionary] = []
var output_dir := ""

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, name: String) -> void:
	cases.append({"name": name, "ok": condition})
	print(("PASS " if condition else "FAIL ") + name)

func _run() -> void:
	output_dir = ProjectSettings.globalize_path("res://../test-results/" + Schema.uuid())
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output-dir="):
			output_dir = arg.trim_prefix("--output-dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	_test_schema()
	_test_region_extent()
	_test_commands()
	_test_persistence()
	await _test_physics()
	await preload("res://tests/test_terrain.gd").new().run(self)
	await preload("res://tests/test_v3.gd").new().run(self)
	await preload("res://tests/test_v31.gd").new().run(self)
	await preload("res://tests/test_cpu_colliders.gd").new().run(self)
	var passed := 0
	for item in cases:
		if item.ok:
			passed += 1
	var report := {"suite": "native-domain-persistence-physics", "engine": Engine.get_version_info().string, "physics": ProjectSettings.get_setting("physics/3d/physics_engine"), "passed": passed, "failed": cases.size() - passed, "cases": cases}
	var file := FileAccess.open(output_dir + "/report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("REPORT " + output_dir + "/report.json")
	print("RESULT %d/%d passed" % [passed, cases.size()])
	quit(0 if passed == cases.size() else 1)

func _test_region_extent() -> void:
	var service = Service.new(output_dir + "/wide-region.json")
	var original: Dictionary = service.model.snapshot()
	check(service.request("SetRegionSize", {"size": 512}).ok, "owner expands one region to 512 metres")
	var wide: Dictionary = service.model.snapshot()
	check(wide.region.size == [512.0, 512.0] and wide.terrain.columns == 129 and wide.terrain.heights[0] == original.terrain.heights[0] and Schema.validate(wide).is_empty(), "expanded terrain keeps existing samples and covers full 512 metres")
	var remote := Schema.box("Outer block", [400.0, 400.0, 2.0], [2.0, 2.0, 2.0], "#ffffff")
	check(service.request("CreateObject", {"object": remote}).ok and service.request("SetRegionSpawn", {"position": [400.0, 400.0, 3.0]}).ok, "objects and spawn can occupy the outer part of expanded region")
	check(not service.request("SetRegionSize", {"size": 256}).ok and service.model.snapshot().region.size == [512.0, 512.0], "shrinking rejects objects outside the smaller boundary atomically")
	check(service.request("SaveRegion").ok and service.request("LoadRegion").ok and service.model.snapshot().region.size == [512.0, 512.0], "expanded world persists and reloads")

func _test_schema() -> void:
	var world := Schema.seed()
	check(Schema.validate(world).is_empty(), "seed satisfies portable schema")
	var wrong := world.duplicate(true)
	wrong.schema_version = Schema.VERSION + 1
	check(not Schema.validate(wrong).is_empty(), "future schema rejected")
	wrong = world.duplicate(true)
	wrong.objects.append(wrong.objects[0].duplicate(true))
	check(not Schema.validate(wrong).is_empty(), "duplicate persistent ID rejected")
	wrong = world.duplicate(true)
	wrong.objects[0].size[0] = -1
	check(not Schema.validate(wrong).is_empty(), "negative dimensions rejected")
	wrong = world.duplicate(true)
	wrong.objects[0].position[0] = 0
	check(not Schema.validate(wrong).is_empty(), "full object footprint checked at region edge")
	wrong = world.duplicate(true)
	wrong.objects[0].rotation = [0, 0, 0, 2]
	check(not Schema.validate(wrong).is_empty(), "unnormalized quaternion rejected")
	wrong = world.duplicate(true)
	wrong.terrain.heights[0] = NAN
	check(not Schema.validate(wrong).is_empty(), "non-finite terrain rejected")
	wrong = world.duplicate(true)
	wrong.terrain.heights.pop_back()
	check(not Schema.validate(wrong).is_empty(), "terrain sample count checked")
	wrong = world.duplicate(true)
	wrong.objects[0].asset_id = Schema.uuid()
	check(not Schema.validate(wrong).is_empty(), "missing asset reference rejected")
	wrong = world.duplicate(true)
	wrong.assets[0].uri = "res://main.gd"
	check(not Schema.validate(wrong).is_empty(), "external executable asset paths rejected")
	wrong = world.duplicate(true)
	for index in range(Schema.MAX_IMPORTED_ASSETS + 1): wrong.assets.append({"id": str(index)})
	check(Schema.validate(wrong).contains("at most 64 imported assets"), "imported asset catalog stops at 64 entries")
	wrong = world.duplicate(true)
	wrong["unexpected"] = true
	check(not Schema.validate(wrong).is_empty(), "unknown world fields rejected")
	var point := [23.0, 91.0, 7.5]
	check(WorldView.to_world(WorldView.to_engine(point)) == point, "coordinate conversion round trip")
	var q := Quaternion(Vector3(0, 0, 1), PI / 2)
	var direction := WorldView.rotation_to_engine([q.x, q.y, q.z, q.w]) * Vector3.RIGHT
	check(direction.distance_to(Vector3(0, 0, -1)) < 0.0001, "east rotated toward north remains correct in engine")

func _test_commands() -> void:
	var service = Service.new(output_dir + "/commands.json")
	var count: int = service.model.snapshot().objects.size()
	var item := Schema.box("test", [50.0, 50.0, 1.0], [2.0, 2.0, 2.0], "#50A696")
	var command := {"api_version": 1, "request_id": Schema.uuid(), "operation": "CreateObject", "expected_revision": 0, "payload": {"object": item}}
	var created: Dictionary = service.dispatch(command)
	check(created.ok and service.model.snapshot().objects.size() == count + 1, "command creates an object with stable ID")
	var replay: Dictionary = service.dispatch(command)
	check(replay == created and service.model.snapshot().objects.size() == count + 1, "duplicate request does not create twice")
	command.payload.object.name = "changed after dispatch"
	check(service.model.object(item.id).name == "test", "input dictionary cannot mutate world after dispatch")
	check(not service.dispatch(command).ok, "reused request ID with altered payload rejected")
	command.request_id = Schema.uuid()
	check(service.dispatch(command).errors[0].code == "REVISION_CONFLICT", "stale revision rejected")
	var snapshot: Dictionary = service.model.snapshot()
	snapshot.objects.clear()
	check(service.model.snapshot().objects.size() == count + 1, "snapshot returns an isolated copy")
	check(service.request("UpdateObject", {"id": item.id, "patch": {"position": [51.25, 52.5, 3.0], "color": "#E9B45D"}}).ok, "transform and color update validated together")
	check(not service.request("UpdateObject", {"id": item.id, "patch": {"owner_id": Schema.uuid()}}).ok, "owner cannot be changed through a field patch")
	var before := Repository.canonical(service.model.snapshot())
	check(not service.request("UpdateObject", {"id": item.id, "patch": {"size": [0, 2, 2]}}).ok, "invalid edit rejected")
	check(Repository.canonical(service.model.snapshot()) == before, "rejected edit leaves revision and state unchanged")
	service.actor = Schema.uuid()
	check(not service.request("DeleteObject", {"id": item.id}).ok, "different local actor cannot delete owned object")
	service.actor = Schema.OWNER
	check(service.request("DeleteObject", {"id": item.id}).ok and service.model.object(item.id).is_empty(), "delete removes object")
	check(service.request("Undo").ok and not service.model.object(item.id).is_empty(), "undo restores same object identity")
	check(not service.dispatch({"operation": "CreateObject"}).ok, "malformed envelope rejected")
	check(not service.request("LaunchScript").ok, "unknown operation rejected")
	check(service.request("RenameRegion", {"name": "赫尔辛基实景街区"}).ok and service.model.snapshot().region.name == "赫尔辛基实景街区", "owner can name a seeded real-world region")
	check(service.request("SetRegionSpawn", {"position": [128.0, 107.0, 5.5]}).ok and service.model.snapshot().region.spawn == [128.0, 107.0, 5.5], "owner can place a safe scene spawn")
	var named: Dictionary = service.model.snapshot()
	check(not service.request("SetRegionSpawn", {"position": [300.0, 107.0, 5.5]}).ok and service.model.snapshot() == named, "out-of-region spawn is rejected atomically")
	service.actor = Schema.uuid()
	check(not service.request("RenameRegion", {"name": "unowned"}).ok and not service.request("SetRegionSpawn", {"position": [128.0, 107.0, 8.0]}).ok, "only the region owner can rename or move spawn")

func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(contents)
	file.close()

func _same_data(left: Variant, right: Variant) -> bool:
	if (left is float or left is int) and (right is float or right is int):
		return abs(float(left) - float(right)) <= 0.000001
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size() or not right.has_all(left.keys()):
			return false
		for key in left:
			if not _same_data(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not _same_data(left[index], right[index]):
				return false
		return true
	return typeof(left) == typeof(right) and left == right

func _test_persistence() -> void:
	var path := output_dir + "/world.json"
	var service = Service.new(path)
	var first: Dictionary = service.model.snapshot()
	var saved: Dictionary = service.request("SaveRegion")
	check(saved.ok and not service.dirty, "first save returns success after read-back verification")
	if not saved.ok:
		print(JSON.stringify(saved))
		print(JSON.stringify(service.repository._read(path + ".tmp")))
		return
	var id: String = service.model.snapshot().objects[0].id
	service.request("UpdateObject", {"id": id, "patch": {"name": "saved again", "position": [127.75, 130.25, 0.45]}})
	var second: Dictionary = service.model.snapshot()
	check(service.request("SaveRegion").ok, "second save replaces primary and keeps backup")
	var reader = Service.new(path)
	check(reader.request("LoadRegion").ok and _same_data(reader.model.snapshot(), second), "new service restores stable IDs and attributes within 1e-6")
	_write(path, "broken JSON")
	var recovered: Dictionary = reader.request("LoadRegion")
	check(recovered.ok and recovered.payload.recovered and _same_data(reader.model.snapshot(), first), "corrupt primary restores previous valid backup with warning")
	check(reader.request("SaveRegion").ok, "recovered backup can be saved without losing valid data")
	var envelope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	envelope.world_json = envelope.world_json.replace("中央展台", "tampered")
	_write(path, JSON.stringify(envelope))
	check(reader.request("LoadRegion").payload.recovered, "checksum detects valid JSON with altered content")
	_write(path + ".bak", "also broken")
	var before := Repository.canonical(reader.model.snapshot())
	check(not reader.request("LoadRegion").ok and Repository.canonical(reader.model.snapshot()) == before, "both invalid snapshots leave current world untouched")
	var blocked := output_dir + "/directory-not-file"
	DirAccess.make_dir_recursive_absolute(blocked)
	var bad_writer = Service.new(blocked)
	check(not bad_writer.request("SaveRegion").ok and bad_writer.dirty, "failed publish never marks world saved")
	var conflict_path := output_dir + "/conflict.json"
	var writer = Service.new(conflict_path)
	writer.request("SaveRegion")
	var competing = Service.new(conflict_path)
	competing.request("LoadRegion")
	writer.request("UpdateObject", {"id": writer.model.snapshot().objects[0].id, "patch": {"name": "other writer"}})
	writer.request("SaveRegion")
	check(not competing.request("SaveRegion").ok, "external file modification is detected before overwrite")

func _test_physics() -> void:
	check(ProjectSettings.get_setting("physics/3d/physics_engine") == "Jolt Physics", "project selects native Jolt physics")
	var world := Schema.seed()
	var view = WorldView.new()
	root.add_child(view)
	view.rebuild(world)
	for action in ["move_left", "move_right", "move_forward", "move_back", "sprint", "jump"]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
	var player = Avatar.new()
	root.add_child(player)
	player.reset_spawn(Vector3(90, 10, -100))
	for frame in range(150):
		await physics_frame
	check(player.is_on_floor(), "capsule lands on real terrain mesh collision")
	check(abs(player.position.y - view.ground_height(90, 100)) < 0.15, "rendered height samples align with collision height")
	var hit := view.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(55, 40, -195), Vector3(55, -20, -195), 1))
	check(not hit.is_empty() and abs(hit.position.y - view.ground_height(55, 195)) < 0.15, "hill collision agrees with north-up data mapping")
	player.active = true
	var floor_height: float = player.position.y
	Input.action_press("jump")
	for frame in range(15):
		await physics_frame
	Input.action_release("jump")
	check(player.position.y > floor_height + 0.5, "jump input lifts avatar through native physics")
	for frame in range(100):
		await physics_frame
	check(player.is_on_floor(), "avatar lands again after jumping")
	var start: Vector3 = player.position
	Input.action_press("move_forward")
	for frame in range(35):
		await physics_frame
	Input.action_release("move_forward")
	check(player.position.z < start.z - 2.0, "movement input advances avatar through physics")
	var blocker := Schema.box("physics obstacle", [90.0, 108.0, 1.2], [8.0, 2.0, 2.4], "#50A696")
	world.objects.append(blocker)
	view.sync_objects(world.objects)
	Input.action_press("move_forward")
	for frame in range(120):
		await physics_frame
	Input.action_release("move_forward")
	check(player.position.z > -107.1, "avatar cannot walk through editable box collider")
	var object_hit := view.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(90, 20, -108), Vector3(90, -10, -108), 2))
	check(not object_hit.is_empty() and object_hit.collider.get_meta("world_id") == blocker.id, "physics ray resolves persistent object identity")
	player.free()
	view.free()
	await process_frame
