extends SceneTree
## Injects events into real Godot Controls, then checks world/physics/save state.
var app
var cases: Array[Dictionary] = []
var output_dir := ""

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, name: String) -> void:
	cases.append({"ok": ok, "name": name})
	print(("PASS " if ok else "FAIL ") + name)

func _click(control: Control) -> void:
	# Containers may queue layout after state changes; target the drawn control.
	await process_frame
	await RenderingServer.frame_post_draw
	var center := control.get_global_rect().get_center()
	var target := control.get_window()
	if target != root:
		center += Vector2(target.position)
	await _click_point(center)

func _click_point(center: Vector2) -> void:
	var target := root
	var motion := InputEventMouseMotion.new()
	motion.position = center
	target.push_input(motion, true)
	var press := InputEventMouseButton.new()
	press.position = center
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	target.push_input(press, true)
	await process_frame
	var release := InputEventMouseButton.new()
	release.position = center
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	target.push_input(release, true)
	await process_frame
	await process_frame
	await create_timer(0.04).timeout

func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(output_dir + "/" + name)
	check(result == OK, "real rendered screenshot: " + name)

func _run() -> void:
	output_dir = ProjectSettings.globalize_path("res://../test-results/ui-" + str(Time.get_ticks_usec()))
	var world_file := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output-dir="):
			output_dir = arg.trim_prefix("--output-dir=")
		if arg.begins_with("--world-file="):
			world_file = ProjectSettings.globalize_path(arg.trim_prefix("--world-file=")).simplify_path()
	# UI tests must never fall back to the application's default user world.
	var parent := world_file.get_base_dir().to_lower()
	var expected := ProjectSettings.globalize_path(output_dir).simplify_path().to_lower()
	if world_file.is_empty() or parent != expected or FileAccess.file_exists(world_file) or FileAccess.file_exists(world_file + ".bak"):
		push_error("UI verification requires a new --world-file inside --output-dir.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	for frame in range(45):
		await process_frame
	var initial_count: int = app.service.model.snapshot().objects.size()
	check(app.world_view.bodies.size() == initial_count and initial_count > 30, "UI scene loads the V3 demonstration objects")
	check(app.ui.buttons.apply.get_global_rect().end.x < root.size.x, "inspector controls fit the window")
	check(app.ui.mode_button.get_global_rect().end.y < root.size.y, "bottom toolbar fits the window")
	await _capture("overview.png")
	var selected: Dictionary = app.service.model.object(app.selected_id)
	var before_position: Array = selected.position.duplicate()
	app.ui.name_input.text = "仅改名称"
	await _click(app.ui.buttons.apply)
	check(app.service.model.object(app.selected_id).position == before_position, "name-only edit preserves unrounded transform values")
	await _click(app.ui.buttons.create)
	var id: String = app.selected_id
	check(app.service.model.snapshot().objects.size() == initial_count + 1 and not id.is_empty(), "create button adds and selects a new world object")
	app.ui.name_input.text = "重启恢复验证方块"
	app.ui.fields.position0.value = 137.25
	app.ui.fields.position1.value = 119.5
	app.ui.fields.position2.value = 2.75
	app.ui.fields.size0.value = 2.5
	app.ui.fields.size1.value = 3.5
	app.ui.fields.size2.value = 4.5
	app.ui.fields.yaw.value = 35
	app.ui.color_input.color = Color("#E9B45D")
	await _click(app.ui.buttons.apply)
	var changed: Dictionary = app.service.model.object(id)
	check(changed.position == [137.25, 119.5, 2.75] and changed.size == [2.5, 3.5, 4.5] and changed.name == "重启恢复验证方块", "inspector applies name, position and size via command gateway")
	check(changed.color == "#E9B45D" and abs(changed.rotation[2]) > 0.1, "inspector applies color and rotation")
	check(app.world_view.bodies[id].position.distance_to(Vector3(137.25, 2.75, -119.5)) < 0.0001, "command result updates real scene transform")
	await _click(app.ui.buttons.save)
	check(not app.service.dirty and FileAccess.file_exists(app.service.repository.path), "save button publishes validated snapshot")
	app.ui.fields.position0.value = 145.25
	await _click(app.ui.buttons.apply)
	check(app.service.dirty, "subsequent edit marks world dirty")
	await _click(app.ui.buttons.load)
	check(app._dialog.visible, "reload asks before discarding unsaved edits")
	await _click(app._dialog.get_ok_button())
	check(app.service.model.object(id).position == [137.25, 119.5, 2.75], "confirmed reload restores saved attributes")
	await _click(app.ui.buttons.delete)
	check(app.service.model.object(id).is_empty() and not app.world_view.bodies.has(id), "delete button removes data and collider")
	await _click(app.ui.buttons.undo)
	check(not app.service.model.object(id).is_empty() and app.world_view.bodies.has(id), "undo restores object ID and collider")
	app._select(id)
	await _click(app.ui.buttons.walk)
	check(app.avatar.active and app.avatar.camera.current, "walk button switches to live avatar camera")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	root.push_input(escape)
	await process_frame
	check(not app.avatar.active and app.camera.current and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Escape returns to edit mode and releases mouse")
	await _click(app.ui.buttons.save)
	for frame in range(15):
		await process_frame
	await _capture("edited.png")
	await preload("res://tests/verify_v3_ui.gd").new().run(self)
	await preload("res://tests/verify_v31_ui.gd").new().run(self)
	await _terrain_checks()
	var passed := 0
	for item in cases:
		if item.ok:
			passed += 1
	var report := {"suite": "native-ui-events-and-render", "engine": Engine.get_version_info().string, "passed": passed, "failed": cases.size() - passed, "cases": cases}
	var file := FileAccess.open(output_dir + "/report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("UI_RESULT " + JSON.stringify(report))
	app.free()
	quit(0 if passed == cases.size() else 1)

func _terrain_checks() -> void:
	await _click(app.ui.buttons.terrain_mode)
	check(app.ui.inspector_tabs.current_tab == 1, "terrain tool opens terrain inspector")
	var panel = app.ui.terrain_panel
	check(panel.apply_button.get_global_rect().end.x < root.size.x, "terrain controls fit the inspector width")
	var before: Dictionary = app.service.model.snapshot()
	var index := 35 * 65 + 29
	panel.fields.east.value = 116
	panel.fields.north.value = 140
	panel.fields.radius.value = 12
	panel.fields.strength.value = 75
	await _click(panel.apply_button)
	var raised: Dictionary = app.service.model.snapshot()
	check(abs(raised.terrain.heights[index] - before.terrain.heights[index] - 6.0) < 0.002, "terrain apply button changes the selected height samples")
	check(raised.objects == before.objects, "terrain UI edit preserves all object transforms")
	for frame in range(4):
		await physics_frame
	var hit: Dictionary = app.world_view.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(116, 90, -140), Vector3(116, -50, -140), 1))
	check(not hit.is_empty() and abs(hit.position.y - raised.terrain.heights[index]) < 0.002, "terrain UI edit reaches the native collider")
	await _click(app.ui.buttons.undo)
	check(app.service.model.snapshot().terrain == before.terrain, "terrain undo button restores height field")
	await _click(app.ui.buttons.redo)
	check(app.service.model.snapshot().terrain == raised.terrain, "terrain redo button restores height field")
	await _click(app.ui.buttons.save)
	panel.mode.select(1)
	await _click(panel.apply_button)
	await _click(app.ui.buttons.load)
	await _click(app._dialog.get_ok_button())
	check(_same_terrain(app.service.model.snapshot().terrain, raised.terrain), "terrain save and reload restores the edited height field")
	check(app.service.history_state() == {"undo": 0, "redo": 0}, "terrain reload clears UI history")
	# Center a visible, unobstructed piece of ground for a real viewport pick.
	app.orbit_target = Vector3(116, 3, -140)
	app.orbit_distance = 55.0
	app._update_camera()
	panel.mode.select(0)
	var position := Vector3(110, app.world_view.ground_height(110, 135), -135)
	var screen: Vector2 = app.camera.unproject_position(position)
	var revision: int = app.service.model.revision()
	await _click_point(screen)
	check(app.service.model.revision() == revision + 1 and panel.center().distance_to(Vector2(110, 135)) < 0.4, "viewport click picks terrain and applies one stamp")
	check(is_instance_valid(app.world_view._brush) and app.world_view._brush.visible, "terrain brush footprint is displayed")
	# Terrain rising underneath the capsule lifts it without changing horizontal position.
	app.avatar.position = Vector3(116, -1, -140)
	panel.set_center(Vector2(116, 140))
	await _click(panel.apply_button)
	check(abs(app.avatar.position.x - 116) < 0.01 and abs(app.avatar.position.z + 140) < 0.01 and app.avatar.position.y >= app.world_view.ground_height(116, 140) - 0.05, "terrain edit prevents avatar burial without resetting horizontal position")
	await _click(app.ui.buttons.save)
	await _capture("terrain.png")
	panel.set_center(Vector2(128, 107))
	panel.mode.select(2)
	panel.fields.height.value = 16
	panel.fields.strength.value = 100
	for frame in range(3):
		await process_frame
	await _click(panel.apply_button)
	await _click(app.ui.buttons.save)
	await _click(app.ui.buttons.load)
	check(app.avatar.position.y >= app.world_view.ground_height(128, 107) - 0.05 and Vector2(app.avatar.position.x, -app.avatar.position.z).distance_to(Vector2(128, 107)) < 0.01, "reload places avatar above edited spawn terrain")

func _same_terrain(a: Dictionary, b: Dictionary) -> bool:
	if a.columns != b.columns or a.rows != b.rows or a.spacing != b.spacing or a.heights.size() != b.heights.size():
		return false
	for i in range(a.heights.size()):
		if abs(float(a.heights[i]) - float(b.heights[i])) > 0.000001:
			return false
	return true
