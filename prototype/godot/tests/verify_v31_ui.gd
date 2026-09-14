extends RefCounted
const T = preload("res://domain/world_transforms.gd")
const Fixtures = preload("res://tests/test_v31.gd")

func run(suite: SceneTree) -> void:
	var app = suite.app
	app._set_walk(false)
	app.ui.inspector_tabs.current_tab = 0
	app.ui.list.get_v_scroll_bar().value = 0
	await _list_click(suite, 0, false)
	await _list_click(suite, 1, true)
	suite.check(app.ui.selected_ids.size() == 2 and not app.ui.buttons.group.disabled, "Ctrl-click selects multiple real scene list entries")
	var count: int = app.service.model.snapshot().groups.size()
	await suite._click(app.ui.buttons.group)
	suite.check(app.service.model.snapshot().groups.size() == count + 1 and app.ui.inspector_tabs.current_tab == 3, "group button creates an assembly and opens its inspector")
	var panel = app.ui.group_panel
	if panel.frame.is_empty():
		return
	var id: String = panel.frame.id
	panel.fields.position0.value -= 10
	panel.fields.yaw.value = 15
	await suite._click(panel.buttons.update)
	suite.check(abs(T.quat(T.group(app.service.model.snapshot(), id).rotation).get_euler().z - deg_to_rad(15)) < 0.0001, "group inspector applies a world rotation")
	await suite._click(panel.buttons.duplicate)
	suite.check(app.service.model.snapshot().groups.size() == count + 2, "group inspector duplicates all members")
	await suite._click(panel.buttons.delete)
	suite.check(app.service.model.snapshot().groups.size() == count + 1, "group inspector deletes the selected copy")
	app.orbit_target = Vector3(128, 2, -137)
	app.orbit_distance = 90
	app._update_camera()
	app._select(app.service.model.snapshot().objects[2].id)
	app.ui.inspector_tabs.current_tab = 3
	await suite._capture("groups.png")
	app.ui.inspector_tabs.current_tab = 4
	var asset_panel = app.ui.asset_panel
	var ids: Array = []
	for name in ["pavilion", "bench", "tree"]:
		var payload := Fixtures.import_payload(name)
		asset_panel.path_input.text = payload.path
		asset_panel.name_input.text = "LongAsset".repeat(17) if name == "bench" else payload.name
		asset_panel.license_input.text = payload.license
		asset_panel.attribution_input.text = payload.attribution
		await suite._click(asset_panel.import_button)
		var asset_id: String = app.ui.chosen_asset_id()
		ids.append(asset_id)
		suite.check(asset_id in app.service.model.snapshot().assets.map(func(a): return a.id) and app.service.model.snapshot().assets.size() == 7 + ids.size() - 1, "UI imports static GLB and selects new asset: " + name)
		await suite._click(app.ui.buttons.create)
		var item: Dictionary = app.service.model.object(app.selected_id)
		suite.check(item.asset_id == asset_id and item.color == "#FFFFFF", "UI creates mesh instance using native dimensions: " + name)
		if name == "bench":
			suite.check(item.name.length() == 80 and app.ui._list_panel.get_global_rect().end.x < 300, "long asset names create bounded object names without expanding the scene panel")
		# Set fields through the same inspector used for built-in objects.
		app.ui.inspector_tabs.current_tab = 0
		var positions: Dictionary = {"pavilion": [149, 136], "bench": [144, 125], "tree": [156, 128]}
		app.ui.fields.position0.value = positions[name][0]
		app.ui.fields.position1.value = positions[name][1]
		app.ui.fields.position2.value = app.world_view.ground_height(positions[name][0], positions[name][1]) + item.size[2] * 0.5
		await suite._click(app.ui.buttons.apply)
		app.ui.inspector_tabs.current_tab = 4
	app.orbit_target = Vector3(140, 1.5, -137)
	app.orbit_distance = 95
	app._update_camera()
	await suite._capture("imported-assets.png")
	await suite._click(app.ui.buttons.save)
	var saved: Dictionary = app.service.model.snapshot()
	await suite._click(app.ui.buttons.load)
	suite.check(app.service.model.snapshot().groups.size() == saved.groups.size() and app.service.model.snapshot().assets.size() == 9 and app.world_view.mesh_view.cache.size() == 3, "UI reload restores group records and all imported geometry")
	suite.check(app.service.history_state() == {"undo": 0, "redo": 0} and not app.service.dirty, "V3.1 restored world has no pending edits or retained history")

func _list_click(suite: SceneTree, index: int, ctrl: bool) -> void:
	var list: ItemList = suite.app.ui.list
	await suite.process_frame
	await RenderingServer.frame_post_draw
	var point := list.global_position + list.get_item_rect(index).get_center()
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.ctrl_pressed = ctrl
	suite.root.push_input(event, true)
	await suite.process_frame
	event = event.duplicate()
	event.pressed = false
	suite.root.push_input(event, true)
	await suite.process_frame
	await suite.create_timer(0.05).timeout
