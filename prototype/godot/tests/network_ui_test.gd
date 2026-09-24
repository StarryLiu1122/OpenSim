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
	var context_point := root.get_visible_rect().size * 0.5
	var context: Dictionary = app._context_at(context_point)
	check(not context.is_empty(), "overview centre resolves a real terrain or object ray hit")
	if not context.is_empty():
		for pressed in [true, false]:
			var right := InputEventMouseButton.new(); right.position = context_point; right.button_index = MOUSE_BUTTON_RIGHT; right.pressed = pressed
			root.push_input(right, true); await process_frame
		check(app.ui.context_menu.visible, "right click opens a location action menu")
		app.ui.context_menu.hide()
		if context.normal.y > 0.45:
			app.context_hit = context
			app._context_action(0)
			check(app.walking and not app.auto_target.is_empty(), "Go Here starts bounded avatar movement toward clicked point")
			app._stop_walk()
	var old_distance: float = app.camera.position.distance_to(app.overview_target)
	app._zoom(1)
	check(app.camera.position.distance_to(app.overview_target) < old_distance, "camera zoom moves toward focus")
	app._zoom(-1)
	var original_target: Vector3 = app.overview_target
	var pan_press := InputEventMouseButton.new(); pan_press.position = context_point; pan_press.button_index = MOUSE_BUTTON_MIDDLE; pan_press.pressed = true
	root.push_input(pan_press, true); await process_frame
	var pan_motion := InputEventMouseMotion.new(); pan_motion.position = context_point + Vector2(70, 30); pan_motion.relative = Vector2(70, 30)
	root.push_input(pan_motion, true); await process_frame
	pan_press.pressed = false; root.push_input(pan_press, true); await settle()
	check(app.overview_target.distance_to(original_target) > 0.5, "middle drag pans the editing camera")
	await key(KEY_HOME)
	check(app.overview_target.is_equal_approx(original_target), "Home restores the scene overview")
	var ground_point := Vector2(-1, -1)
	for y_ratio in [0.62, 0.68, 0.74]:
		for x_ratio in [0.35, 0.45, 0.55, 0.65]:
			var candidate_point := Vector2(root.size.x * x_ratio, root.size.y * y_ratio)
			var ground_hit: Dictionary = app._context_at(candidate_point)
			if not ground_hit.is_empty() and ground_hit.id.is_empty() and ground_hit.normal.y > 0.45:
				ground_point = candidate_point; break
		if ground_point.x >= 0: break
	if ground_point.x >= 0:
		var double_ground := InputEventMouseButton.new(); double_ground.position = ground_point; double_ground.button_index = MOUSE_BUTTON_LEFT; double_ground.pressed = true; double_ground.double_click = true
		root.push_input(double_ground, true); await process_frame
		check(app.walking and not app.auto_target.is_empty(), "double-clicking terrain starts Go Here movement")
		double_ground.pressed = false; root.push_input(double_ground, true); app._stop_walk(); await settle()
	else: check(false, "double-clicking terrain starts Go Here movement")
	var object_point := Vector2(-1, -1)
	var object_id := ""
	for candidate in app.connection.local.snapshot().objects.values():
		if not app.view.bodies.has(candidate.id): continue
		var projected: Vector2 = app.camera.unproject_position(app.view.bodies[candidate.id].position)
		if projected.x < 430 or projected.x > root.size.x - 380 or projected.y < 110 or projected.y > root.size.y - 120: continue
		if app.view.pick(app.camera, projected) == candidate.id:
			object_point = projected; object_id = candidate.id; break
	if not object_id.is_empty():
		var double_object := InputEventMouseButton.new(); double_object.position = object_point; double_object.button_index = MOUSE_BUTTON_LEFT; double_object.pressed = true; double_object.double_click = true
		root.push_input(double_object, true); await process_frame
		check(app.selected == object_id and app.overview_target.is_equal_approx(app.view.bodies[object_id].position), "double-clicking an object selects and frames it")
		double_object.pressed = false; root.push_input(double_object, true); await settle()
	else: check(false, "double-clicking an object selects and frames it")
	app.selected = ""; app.view.select(""); app.ui.tabs.current_tab = 0; await settle()
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
	var shift := InputEventKey.new(); shift.keycode = KEY_SHIFT; shift.physical_keycode = KEY_SHIFT; shift.pressed = true
	Input.parse_input_event(shift)
	move.pressed = true; Input.parse_input_event(move)
	await create_timer(0.55).timeout
	check(app.own.sprinting and Vector2(app.own.velocity.x, app.own.velocity.z).length() > 6.5, "Shift increases the avatar's actual movement speed")
	var authority_velocity: Array = app.connection.local.snapshot().avatars.get(app.connection.welcome.avatar_id, {}).get("velocity", [0.0, 0.0, 0.0])
	check(Vector2(authority_velocity[0], authority_velocity[1]).length() > 6.5, "authoritative avatar also receives sprint speed")
	move.pressed = false; Input.parse_input_event(move)
	shift.pressed = false; Input.parse_input_event(shift)
	await settle()
	var feet: Array = app.View.to_world(app.own.position)
	var forward := Vector2(0, 2.8).rotated(app.yaw)
	var door: Dictionary = app.Schema.primitive("door", "互动验收门", [feet[0] + forward.x, feet[1] + forward.y, feet[2] + 1.1], [1.0, 0.2, 2.2], "#77aaaa")
	door.owner_id = app.connection.welcome.actor_id
	app._command("CreateObject", {"object": door})
	for frame in range(600):
		if app.connection.local.snapshot().objects.has(door.id) and app.view.bodies.has(door.id) and app.interactive: break
		await process_frame
	check(app._nearby_interaction().get("id", "") == door.id and app.ui.interaction_panel.visible, "nearby owned door shows a contextual E prompt")
	await capture("nearby-door")
	await key(KEY_E)
	for frame in range(600):
		if app.connection.local.snapshot().objects.get(door.id, {}).get("state", {}).get("active", false): break
		await process_frame
	check(app.connection.local.snapshot().objects.get(door.id, {}).get("state", {}).get("active", false), "E opens a nearby door through the authority")
	app.context_hit = {"id": door.id}
	app._context_action(5)
	for frame in range(600):
		if not app.connection.local.snapshot().objects.get(door.id, {}).get("state", {}).get("active", true): break
		await process_frame
	check(not app.connection.local.snapshot().objects.get(door.id, {}).get("state", {}).get("active", true), "context action closes an owned door through the authority")
	app._command("DeleteObject", {"id": door.id})
	for frame in range(600):
		if not app.connection.local.snapshot().objects.has(door.id): break
		await process_frame
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
	if not context.is_empty() and context.normal.y > 0.45:
		app.context_hit = context
		var before_build: int = app.connection.local.snapshot().objects.size()
		app._context_action(1)
		for frame in range(600):
			if app.connection.local.snapshot().objects.size() > before_build and app.connection.pending.is_empty(): break
			await process_frame
		check(app.connection.local.snapshot().objects.size() == before_build + 1, "right-click Build creates an object through the authority")
		for frame in range(900):
			if app.interactive and app.view.bodies.size() == app.connection.local.snapshot().objects.size() and app.rendered_revision == int(app.connection.local.snapshot().meta.revision): break
			await process_frame
		check(app.interactive and app.view.bodies.size() == app.connection.local.snapshot().objects.size(), "new context-built object finishes collision projection")
	app.ui.tabs.current_tab = 0; await settle()
	for frame in range(600):
		if not app.ui.expand_button.disabled and app.connection.pending.is_empty(): break
		await process_frame
	await click(app.ui.expand_button)
	for frame in range(1200):
		if app.connection.local.snapshot().meta.region.size[0] == 512 and app.view._region_size == Vector2(512, 512) and app.interactive: break
		await process_frame
	check(app.connection.local.snapshot().meta.region.size == [512.0, 512.0] and app.view._region_size == Vector2(512, 512), "network button expands authority and rendered region to 512 metres")
	var outer: Dictionary = app.Schema.box("Outer region marker", [400.0, 400.0, 2.0], [1.0, 1.0, 1.0], "#ffffff")
	outer.owner_id = app.connection.welcome.actor_id
	app._command("CreateObject", {"object": outer})
	for frame in range(1200):
		if app.connection.local.snapshot().objects.has(outer.id) and app.view.bodies.has(outer.id): break
		await process_frame
	check(app.connection.local.snapshot().objects.has(outer.id) and app.view.bodies.has(outer.id), "expanded network interest includes an object 400 metres from origin")
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
