extends SceneTree
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const Assets = preload("res://adapters/mesh_assets.gd")
const View = preload("res://adapters/world_view.gd")
const Avatar = preload("res://client/avatar.gd")
const ID := "bb4cb272-8b7b-4c41-954a-acb3e5261b65"
var checks: Array = []
var output := ""
var mode := ""

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, label: String) -> void:
	checks.append({"name": label, "passed": value})
	print("BUILDING ", value, " ", label)

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output-dir="): output = arg.trim_prefix("--output-dir=")
		if arg.begins_with("--mode="): mode = arg.trim_prefix("--mode=")
	if output.is_empty() or not mode in ["write", "read"]: quit(2); return
	var world_path := output + "/cabin.snapshot.json"
	var service = Service.new(world_path)
	if mode == "write":
		var world := Schema.seed(); world.objects = []; world.terrain.heights.fill(0.0)
		service.model.replace(world)
		var source := output + "/temporary-source.glb"
		DirAccess.copy_absolute(ProjectSettings.globalize_path("res://../fixtures/buildings/pioneer-log-cabin/pioneer-log-cabin.glb"), source)
		var imported: Dictionary = service.request("ImportGlb", {"path": source, "name": "Pioneer Log Cabin / HABS WIS-18", "license": "CC0-1.0", "attribution": "LOC HABS WIS-18, Herbert W. Bradley; measured-drawing derivative by Region Lab"})
		check(imported.ok, "documented GLB accepted by production importer")
		check(DirAccess.remove_absolute(source) == OK, "original import source removed")
		if imported.ok:
			var asset: Dictionary = service.model.snapshot().assets[-1]
			var item := Schema.box("Pioneer Log Cabin", [100, 99.3096, 2.1209], asset.bounds, "#FFFFFF")
			item.id = ID; item.asset_id = asset.id
			check(service.request("CreateObject", {"object": item}).ok, "building object created with measured dimensions")
			check(service.request("SaveRegion").ok, "self-contained snapshot saved")
	else:
		check(service.request("LoadRegion").ok, "relocated snapshot loaded in a new engine process")
		check(not FileAccess.file_exists(output + "/temporary-source.glb"), "source GLB absent in destination")
	var snapshot: Dictionary = service.model.snapshot()
	var geometry := Assets.read(snapshot.assets[-1])
	check(not geometry.has("error") and geometry.get("collision_mode") == "proxy", "independent COL_ proxy parsed")
	check(service.model.object(ID).get("id") == ID, "building identity preserved")
	var view = View.new(); root.add_child(view); view.rebuild(snapshot)
	for i in range(5): await physics_frame
	var space: PhysicsDirectSpaceState3D = view.get_world_3d().direct_space_state
	check(space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(100, 1.1, -95), Vector3(100, 1.1, -100), 2)).is_empty(), "entrance center clear")
	check(not space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(101, 1.1, -95), Vector3(101, 1.1, -100), 2)).is_empty(), "front wall blocks ray")
	check(not space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(100, 2.10, -95), Vector3(100, 2.10, -100), 2)).is_empty(), "lintel blocks over-height path")
	for action in ["move_left", "move_right", "move_forward", "move_back", "jump", "sprint"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	var avatar = Avatar.new(); root.add_child(avatar); avatar.reset_spawn(Vector3(100, .2, -95.7)); avatar.active = true
	Input.action_press("move_forward")
	for i in range(43): await physics_frame
	Input.action_release("move_forward"); avatar.active = false
	for i in range(12): await physics_frame
	check(avatar.position.z < -99 and avatar.position.z > -102, "1.8m avatar passes 0.84m by 1.90m doorway")
	check(avatar.is_on_floor() and absf(avatar.position.y - .12) < .035, "avatar stands on imported floor")
	avatar.reset_spawn(Vector3(101, .2, -96)); avatar.active = true; Input.action_press("move_forward")
	for i in range(40): await physics_frame
	Input.action_release("move_forward"); avatar.active = false
	check(avatar.position.z > -97.3, "actual capsule cannot walk through front wall")
	if not OS.has_feature("headless") and DisplayServer.get_name() != "headless":
		var camera := Camera3D.new(); root.add_child(camera); camera.position = Vector3(108, 6, -90); camera.look_at(Vector3(100, 1.5, -99)); camera.current = true
		var light := DirectionalLight3D.new(); root.add_child(light); light.rotation_degrees = Vector3(-50, -20, 0)
		for i in range(5): await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(output + "/cabin-" + mode + ".png") == OK, "rendered building screenshot saved")
	var passed := checks.all(func(c: Dictionary) -> bool: return c.passed)
	var file := FileAccess.open(output + "/building-" + mode + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"test": "documented-building", "mode": mode, "passed": passed, "checks": checks, "engine": Engine.get_version_info().string}, "  ") + "\n"); file.close()
	view.free(); avatar.free(); quit(0 if passed else 1)
