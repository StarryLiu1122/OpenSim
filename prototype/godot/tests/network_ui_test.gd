extends SceneTree
## Real Controls + a real authority in an explicitly supplied disposable instance.
var app
var output := ""
var cases: Array = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, name: String) -> void:
	cases.append({"ok": ok, "name": name})
	print(("PASS " if ok else "FAIL ") + name)

func settle() -> void:
	for frame in range(4): await process_frame
	await RenderingServer.frame_post_draw

func click(control: Control) -> void:
	var ancestor := control.get_parent()
	while ancestor != null:
		if ancestor is ScrollContainer: ancestor.ensure_control_visible(control)
		ancestor = ancestor.get_parent()
	await settle()
	var point := control.get_global_rect().get_center()
	var target := control.get_window()
	if target != root: point += Vector2(target.position)
	var motion := InputEventMouseMotion.new(); motion.position = point; root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new(); event.position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = pressed; root.push_input(event, true)
		await process_frame
	await settle()

func key(code: Key, pressed: bool = true) -> void:
	var event := InputEventKey.new(); event.keycode = code; event.physical_keycode = code; event.pressed = pressed
	root.push_input(event, true); await process_frame
	if pressed: await key(code, false)

func capture(name: String) -> void:
	await settle()
	check(root.get_texture().get_image().save_png(output.path_join(name + ".png")) == OK, "rendered " + name)

func wait_ready() -> bool:
	for frame in range(1800):
		if app.interactive: return true
		await process_frame
	return false

func _run() -> void:
	var config_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--network-config="): config_path = arg.trim_prefix("--network-config=")
		if arg.begins_with("--output-dir="): output = arg.trim_prefix("--output-dir=")
	# The disposable config and reports must share a scratch parent; never use a user's instance.
	if output.is_empty() or config_path.is_empty() or DirAccess.dir_exists_absolute(output) or config_path.get_base_dir().get_base_dir() != output.get_base_dir():
		push_error("Use a new output directory beside a disposable instance directory."); quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	app = load("res://network/client.tscn").instantiate(); root.add_child(app)
	if not await wait_ready():
		check(false, "client connects to isolated authority"); finish(); return
	check(true, "client connects to isolated authority")
	await capture("overview")
	check(app.ui.walk_button.get_global_rect().end.x < root.size.x and app.ui.footer.get_global_rect().end.y <= root.size.y, "primary action and footer fit window")
	check(app.ui.tabs.current_tab == 0 and not app.ui.tabs.get_child(3).visible, "advanced JSON is absent from initial workflow")
	var state: Dictionary = app.connection.local.snapshot()
	var item: Dictionary = {}
	for object in state.objects.values():
		if object.group_id.is_empty() and object.state.is_empty(): item = object; break
	app.ui.search.text = item.name; app.ui.search.text_changed.emit(item.name)
	await settle()
	check(app.object_list.item_count > 0 and app.object_list.item_count < state.objects.size(), "name search narrows object list")
	var index: int = app.selection_ids.find(item.id)
	var rect: Rect2 = app.object_list.get_item_rect(index)
	var point: Vector2 = app.object_list.global_position + rect.get_center()
	var press := InputEventMouseButton.new(); press.position = point; press.button_index = MOUSE_BUTTON_LEFT; press.pressed = true; root.push_input(press, true)
	press = press.duplicate(); press.pressed = false; root.push_input(press, true)
	await settle()
	check(app.selected == item.id and app.ui.tabs.current_tab == 1, "real list click selects and opens inspector")
	await capture("inspector")
	var original_position: Array = item.position.duplicate()
	var new_name := "界面验收对象 " + str(Time.get_ticks_msec())
	app.name_field.text = new_name; app.name_field.text_changed.emit(app.name_field.text)
	app._refresh_list(app.connection.local.snapshot())
	check(app.name_field.text == new_name and app.draft_dirty, "world refresh preserves unsaved local draft")
	app._select_id(item.id)
	check(app.draft_dirty and app.name_field.text == new_name, "reselecting same object preserves draft")
	await click(app.ui.apply_button)
	for frame in range(600):
		if app.connection.local.snapshot().objects[item.id].name == new_name and app.draft_request.is_empty(): break
		await process_frame
	check(app.connection.local.snapshot().objects[item.id].name == new_name and not app.draft_dirty, "save button waits for authoritative commit")
	check(app.connection.local.snapshot().objects[item.id].position == original_position, "name-only save preserves exact coordinates")
	app.name_field.text = ""; app.name_field.text_changed.emit("")
	await click(app.ui.apply_button)
	for frame in range(300):
		if app.draft_request.is_empty(): break
		await process_frame
	check(app.draft_dirty and app.name_field.text.is_empty() and app.connection.local.snapshot().objects[item.id].name == new_name, "rejected edit preserves draft and authoritative object")
	await click(app.ui.reset_button)
	check(not app.draft_dirty and app.name_field.text == new_name, "reset draft restores committed properties")
	await click(app.ui.focus_button)
	check(app.overview_target.is_equal_approx(app.view.bodies[item.id].position), "focus button frames selected object")
	await click(app.ui.delete_button)
	check(app.ui.delete_dialog.visible, "delete requires explicit confirmation")
	await key(KEY_TAB)
	check(not app.walking, "modal confirmation owns Tab navigation")
	app.ui.delete_dialog.hide(); await settle()
	check(app.connection.local.snapshot().objects.has(item.id), "cancelling delete preserves world object")
	await click(app.ui.walk_button)
	check(app.walking and not app.ui.dock.visible and not app.ui.welcome.visible, "roam button captures input and clears editing panels")
	var before: Vector3 = app.own.position
	var move := InputEventKey.new(); move.keycode = KEY_W; move.physical_keycode = KEY_W; move.pressed = true
	Input.parse_input_event(move)
	await create_timer(0.6).timeout
	move = move.duplicate(); move.pressed = false; Input.parse_input_event(move)
	await settle()
	check(app.own.position.distance_to(before) > 1.0, "W key advances the real network avatar after entering roam")
	await capture("walking")
	await key(KEY_ESCAPE)
	check(not app.walking and app.ui.dock.visible and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Escape restores editing and pointer")
	app.ui.tabs.current_tab = 2; await settle(); app.endpoint.grab_focus()
	await key(KEY_TAB)
	check(not app.walking, "Tab while entering connection fields does not start roaming")
	var focus: Control = root.gui_get_focus_owner()
	if focus != null: focus.release_focus()
	await key(KEY_TAB)
	check(app.walking, "Tab outside text entry starts roaming")
	app.get_window().focus_exited.emit()
	check(not app.walking and app.movement == Vector2.ZERO, "focus loss stops captured movement")
	app._upload("", "测试模型.glb"); await settle()
	check(app.ui.tabs.current_tab == 4 and app.ui.upload_button.disabled, "model selection opens provenance form and cannot submit incomplete data")
	var bytes := FileAccess.get_file_as_bytes("res://../fixtures/meshes/bench.glb")
	app._upload(Marshalls.raw_to_base64(bytes), "原始验证长凳")
	app.ui.upload_license.text = "CC0-1.0"; app.ui.upload_source.text = "Region Lab original validation asset"
	await click(app.ui.upload_button)
	for frame in range(600):
		if not app.session_assets.is_empty(): break
		await process_frame
	check(not app.session_assets.is_empty() and app._upload_bytes.is_empty(), "provenance form registers model only after durable upload receipt")
	check(app.ui.asset_ids.has(app.session_assets.keys()[0]) if not app.session_assets.is_empty() else false, "committed unused model is available for placement despite spatial filtering")
	await capture("import")
	var count: int = app.connection.local.snapshot().objects.size()
	await click(app.ui.place_button)
	for frame in range(600):
		if app.connection.local.snapshot().objects.size() > count and app.ui.tabs.current_tab == 1: break
		await process_frame
	check(app.connection.local.snapshot().objects.size() == count + 1 and not app.selected.is_empty(), "asset placement creates and selects a committed model without JSON")
	check(await wait_ready(), "placed model finishes validated collision loading before editing")
	await settle()
	await click(app.ui.delete_button)
	check(app.ui.delete_dialog.visible, "loaded placed model can request deletion")
	await click(app.ui.delete_dialog.get_ok_button())
	for frame in range(600):
		if app.connection.local.snapshot().objects.size() == count: break
		await process_frame
	check(app.connection.local.snapshot().objects.size() == count, "confirmed delete removes the placed model through authority")
	var imported_count: int = app.session_assets.size()
	var realistic := FileAccess.get_file_as_bytes("res://../fixtures/meshes/polyhaven-marble-bust-01.glb")
	app._upload(Marshalls.raw_to_base64(realistic), "Marble Bust 01")
	app.ui.upload_license.text = "CC0-1.0"
	app.ui.upload_source.text = "Rico Cilliers / Poly Haven; three.ws 1K GLB conversion"
	await click(app.ui.upload_button)
	for frame in range(900):
		if app.session_assets.size() > imported_count: break
		await process_frame
	check(app.session_assets.size() == imported_count + 1, "JPEG PBR GLB uploads through the authoritative asset service")
	var previous_ids: Array = app.connection.local.snapshot().objects.keys()
	await click(app.ui.place_button)
	for frame in range(900):
		if app.connection.local.snapshot().objects.size() > count: break
		await process_frame
	var placed_id := ""
	for id in app.connection.local.snapshot().objects:
		if id not in previous_ids: placed_id = id; break
	var realistic_ready := false
	for frame in range(1800):
		if not placed_id.is_empty() and app.interactive and app.view.bodies.has(placed_id) and app.view.mesh_view.cache.has(app.connection.local.snapshot().objects[placed_id].asset_id):
			realistic_ready = true
			break
		await process_frame
	check(app.connection.local.snapshot().objects.size() == count + 1 and realistic_ready, "write-once realistic asset reloads with geometry and collision")
	if app.draft_dirty: app._reset_draft()
	if not placed_id.is_empty(): app._select_id(placed_id)
	check(app.selected == placed_id, "realistic model can be selected after placement")
	await settle()
	app._focus_selected(); await settle()
	await capture("real-asset")
	root.size = Vector2i(1100, 700); await settle()
	check(app.ui.header.get_global_rect().end.x <= root.get_visible_rect().size.x and app.ui.dock.get_global_rect().end.y < app.ui.footer.position.y, "minimum supported window keeps tools above footer")
	await capture("compact")
	app.connection.disconnect_from(); await settle()
	check(not app.interactive and app.ui.walk_button.disabled and app.ui.create_button.disabled, "disconnect disables movement and mutations")
	await capture("disconnected")
	for principal in app.local_config.principals:
		if principal.name == "observer": app.token_field.text = principal.token
	app._login()
	check(await wait_ready(), "observer reconnects")
	app._select_id(item.id); await settle()
	check(not app.ui.walk_button.disabled and app.ui.apply_button.disabled and app.ui.delete_button.disabled and not app.name_field.editable, "observer can explore but cannot edit properties")
	await capture("observer")
	finish()

func finish() -> void:
	var failed := 0
	for item in cases:
		if not item.ok: failed += 1
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed": cases.size() - failed, "failed": failed, "checks": cases}, "  ")); file.close()
	app.queue_free(); await process_frame
	quit(0 if failed == 0 else 1)
