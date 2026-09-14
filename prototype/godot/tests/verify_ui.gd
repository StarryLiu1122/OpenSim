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
	var center := control.get_global_rect().get_center()
	var target := control.get_window()
	if target != root:
		center += Vector2(target.position)
		target = root
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

func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(output_dir + "/" + name)
	check(result == OK, "real rendered screenshot: " + name)

func _run() -> void:
	output_dir = ProjectSettings.globalize_path("res://../test-results/ui")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output-dir="):
			output_dir = arg.trim_prefix("--output-dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	for frame in range(45):
		await process_frame
	check(app.world_view.bodies.size() == 8, "UI scene loads eight native physics objects")
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
	check(app.service.model.snapshot().objects.size() == 9 and not id.is_empty(), "create button adds and selects a new world object")
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
