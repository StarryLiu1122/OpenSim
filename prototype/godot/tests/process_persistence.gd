extends SceneTree
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const TEST_ID := "44444444-4444-4444-8444-444444444444"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--world-file="):
			path = arg.trim_prefix("--world-file=")
	if path.is_empty():
		push_error("An isolated --world-file is required.")
		quit(1)
		return
	var service = Service.new(path)
	var ok := false
	var mode := "read"
	if OS.get_cmdline_user_args().has("--write"):
		mode = "write"
		var item := Schema.box("process restart fixture", [45.25, 72.5, 3.75], [2.5, 3.5, 4.5], "#E9B45D")
		item.id = TEST_ID
		item.asset_id = Schema.asset_id("door")
		item.material = "metal"
		item.state = {"active": true}
		service.request("UpdateEnvironment", {"patch": {"sun_hour": 19.5, "water_enabled": true, "water_height": -2.5}})
		var sculpted: Dictionary = service.request("SculptTerrain", {"mode": "flatten", "center": [80.0, 80.0], "radius": 12.0, "strength": 1.0, "target_height": 8.0})
		ok = sculpted.ok and service.request("CreateObject", {"object": item}).ok and service.request("SaveRegion").ok
	else:
		var result: Dictionary = service.request("LoadRegion")
		var item: Dictionary = service.model.object(TEST_ID)
		ok = result.ok and not item.is_empty() and item.position == [45.25, 72.5, 3.75] and item.size == [2.5, 3.5, 4.5] and item.color == "#E9B45D" and item.name == "process restart fixture"
		ok = ok and item.state.active and item.material == "metal" and Schema.kind(item.asset_id) == "door" and service.model.snapshot().environment.sun_hour == 19.5 and service.model.snapshot().environment.water_height == -2.5
		ok = ok and service.model.snapshot().terrain.heights[20 * 65 + 20] == 8.0
	print(JSON.stringify({"test": "separate-process-persistence", "mode": mode, "ok": ok, "id": TEST_ID}))
	quit(0 if ok else 1)
