extends Node3D
## Bounded Web export probe. Uses the production domain and physics adapters.
const Service = preload("res://domain/world_service.gd")
const Schema = preload("res://domain/world_schema.gd")
const View = preload("res://adapters/world_view.gd")
const Avatar = preload("res://client/avatar.gd")
var checks: Array = []
var service: RefCounted
var view: Node3D
var picker_finished := false
var report: Dictionary = {}
var label: Label

func check(condition: bool, message: String) -> void:
	checks.append({"name": message, "passed": condition})
	print("WEB_PROBE ", condition, " ", message)

func _ready() -> void:
	for action in ["move_left", "move_right", "move_forward", "move_back", "jump", "sprint"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	service = Service.new("user://web-probe.snapshot.json")
	var previous: Dictionary = service.request("LoadRegion")
	var previous_revision: int = service.model.revision() if previous.ok else -1
	var world := Schema.seed()
	world.terrain.heights.fill(0.0)
	world.objects = []
	service.model.replace(world)
	var file := FileAccess.open("user://pavilion.glb", FileAccess.WRITE)
	file.store_buffer(FileAccess.get_file_as_bytes("res://probe-fixtures/pavilion.bytes")); file.close()
	var imported: Dictionary = service.request("ImportGlb", {"path": "user://pavilion.glb", "name": "Web probe pavilion", "license": "CC0-1.0", "attribution": "Region Lab contributors"})
	check(imported.ok, "production GLB importer")
	if not imported.ok: _publish(); return
	var asset: Dictionary = service.model.snapshot().assets[-1]
	var item := Schema.box("Web GLB", [80, 80, 1.9], asset.bounds, "#FFFFFF")
	item.asset_id = asset.id
	check(service.request("CreateObject", {"object": item}).ok, "mesh instance command")
	var door := Schema.primitive("door", "Web door", [88, 80, 1.8], [2.6, 0.3, 3.2], "#668888")
	check(service.request("CreateObject", {"object": door}).ok, "door command")
	view = View.new(); add_child(view); view.rebuild(service.model.snapshot())
	var light := DirectionalLight3D.new(); light.rotation_degrees = Vector3(-50, -30, 0); add_child(light)
	var camera := Camera3D.new(); add_child(camera)
	camera.position = Vector3(95, 12, -63); camera.look_at(Vector3(81, 1, -80)); camera.current = true
	var ui := CanvasLayer.new(); add_child(ui)
	label = Label.new(); ui.add_child(label); label.position = Vector2(20, 20)
	label.add_theme_color_override("font_color", Color(0.05, 0.08, 0.12))
	label.text = "Region Lab V4 | WebGL2 probe\nTerrain / avatar / door / static GLB"
	for i in range(10): await get_tree().physics_frame
	var space: PhysicsDirectSpaceState3D = view.get_world_3d().direct_space_state
	check(not space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(70, 5, -70), Vector3(70, -2, -70), 1)).is_empty(), "terrain collision")
	check(space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(80, 1.5, -74), Vector3(80, 1.5, -81), 2)).is_empty(), "GLB doorway ray")
	check(not space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(77, 1.5, -74), Vector3(77, 1.5, -81), 2)).is_empty(), "GLB wall collision")
	var ray := PhysicsRayQueryParameters3D.create(Vector3(88, 1.5, -77), Vector3(88, 1.5, -83), 2)
	check(not space.intersect_ray(ray).is_empty(), "closed door collision")
	check(service.request("SetObjectState", {"id": door.id, "active": true}).ok, "door interaction command")
	world = service.model.snapshot(); view.sync_objects(world.objects, world.groups, world.assets)
	for i in range(4): await get_tree().physics_frame
	check(space.intersect_ray(ray).is_empty(), "open door passage")
	var avatar = Avatar.new(); add_child(avatar); avatar.reset_spawn(Vector3(80, 0.3, -77)); avatar.active = true
	Input.action_press("move_forward")
	for i in range(55): await get_tree().physics_frame
	Input.action_release("move_forward"); avatar.active = false
	check(avatar.position.z < -80 and avatar.position.y >= 0.15, "avatar enters GLB and stands on floor")
	check(service.request("SaveRegion").ok, "user filesystem snapshot save")
	report = {"engine": Engine.get_version_info().string, "physics": ProjectSettings.get_setting("physics/3d/physics_engine"), "previous_snapshot_loaded": previous.ok, "previous_revision": previous_revision, "avatar_position": [avatar.position.x, avatar.position.y, avatar.position.z], "renderer": RenderingServer.get_current_rendering_method()}
	_publish()

func _publish() -> void:
	report.checks = checks
	report.passed = checks.all(func(item: Dictionary) -> bool: return item.passed)
	if label != null: label.text += "\n" + ("PASS" if report.passed else "FAIL") + " | " + str(checks.size()) + " checks"
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.regionLabProbe = " + JSON.stringify(report) + ";", true)

func _process(_delta: float) -> void:
	if picker_finished or not OS.has_feature("web") or checks.is_empty(): return
	var selected: Variant = JavaScriptBridge.eval("window.regionLabSelected || ''", true)
	if selected is String and not selected.is_empty():
		picker_finished = true
		var file := FileAccess.open("user://selected.glb", FileAccess.WRITE)
		file.store_buffer(Marshalls.base64_to_raw(selected)); file.close()
		var result: Dictionary = service.request("ImportGlb", {"path": "user://selected.glb", "name": "Picked GLB", "license": "CC0-1.0", "attribution": "Region Lab test fixture"})
		JavaScriptBridge.eval("window.regionLabPicker = " + JSON.stringify({"passed": result.ok, "errors": result.errors}) + ";", true)
