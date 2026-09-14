extends Node3D
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const WorldView = preload("res://adapters/world_view.gd")
const Avatar = preload("res://client/avatar.gd")
const EditorUI = preload("res://client/editor_ui.gd")

var service
var world_view
var avatar
var ui
var camera: Camera3D
var selected_id := ""
var walk_mode := false
var orbit_target := Vector3(127, 1.5, -132)
var orbit_yaw := 0.65
var orbit_pitch := 0.66
var orbit_distance := 43.0
var _dialog: ConfirmationDialog
var _dialog_action := ""

func _ready() -> void:
	_install_input()
	get_tree().auto_accept_quit = false
	var world_file := "user://worlds/default.json"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--world-file="):
			world_file = argument.trim_prefix("--world-file=")
	service = Service.new(world_file)
	_build_lighting()
	world_view = WorldView.new()
	add_child(world_view)
	camera = Camera3D.new()
	camera.fov = 52
	camera.far = 700
	add_child(camera)
	camera.current = true
	_update_camera()
	avatar = Avatar.new()
	add_child(avatar)
	ui = EditorUI.new()
	add_child(ui)
	ui.action_requested.connect(_action)
	ui.object_selected.connect(_select)
	ui.patch_requested.connect(_patch)
	ui.terrain_panel.apply_requested.connect(_sculpt)
	_dialog = ConfirmationDialog.new()
	_dialog.title = "确认操作"
	_dialog.ok_button_text = "继续"
	_dialog.cancel_button_text = "取消"
	_dialog.confirmed.connect(_confirmed)
	add_child(_dialog)
	var loaded: Dictionary = {}
	if service.repository.exists():
		loaded = service.request("LoadRegion")
	_rebuild()
	if not loaded.is_empty():
		_feedback(loaded)
	if not service.model.snapshot().objects.is_empty():
		_select(service.model.snapshot().objects[1].id if service.model.snapshot().objects.size() > 1 else service.model.snapshot().objects[0].id)
	if OS.get_cmdline_user_args().has("--verify-render"):
		_verify_render.call_deferred()

func _install_input() -> void:
	var actions := {"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D, "sprint": KEY_SHIFT, "jump": KEY_SPACE}
	for action in actions:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var event := InputEventKey.new()
			event.physical_keycode = actions[action]
			InputMap.action_add_event(action, event)

func _build_lighting() -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("b5ccce")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("dae8ea")
	settings.ambient_light_energy = 0.3
	settings.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	settings.fog_enabled = true
	settings.fog_light_color = Color("c7dad9")
	settings.fog_density = 0.0012
	environment.environment = settings
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_color = Color("fff1d2")
	sun.light_energy = 0.7
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250
	add_child(sun)

func _rebuild() -> void:
	var world: Dictionary = service.model.snapshot()
	world_view.rebuild(world)
	var spawn := WorldView.to_engine(world.region.spawn)
	spawn.y = maxf(spawn.y, world_view.ground_height(spawn.x, -spawn.z) + 0.1)
	avatar.reset_spawn(spawn)
	if service.model.object(selected_id).is_empty():
		selected_id = ""
	_refresh()

func _refresh() -> void:
	var world: Dictionary = service.model.snapshot()
	var terrain_changed: bool = world_view.sync_terrain(world.terrain, world.region.size)
	world_view.sync_objects(world.objects)
	if terrain_changed:
		var floor_y: float = world_view.ground_height(avatar.position.x, -avatar.position.z)
		if avatar.position.y < floor_y + 0.05:
			avatar.position.y = floor_y + 0.1
			avatar.velocity.y = 0
	world_view.select(selected_id)
	ui.show_world(world, selected_id)
	ui.set_history(service.history_state())
	ui.set_status("●  有未保存修改" if service.dirty else "●  已保存", service.dirty)

func _select(id: String) -> void:
	selected_id = id
	ui.inspector_tabs.current_tab = 0
	world_view.select(id)
	ui.show_world(service.model.snapshot(), id)

func _patch(patch: Dictionary) -> void:
	_feedback(service.request("UpdateObject", {"id": selected_id, "patch": patch}))

func _sculpt(payload: Dictionary) -> void:
	if walk_mode:
		return
	_feedback(service.request("SculptTerrain", payload))

func _process(_delta: float) -> void:
	if ui == null:
		return
	var enabled: bool = ui.inspector_tabs.current_tab == 1 and not walk_mode
	if not enabled:
		world_view.show_brush(Vector2.ZERO, 4, false)
		return
	var center: Vector2 = ui.terrain_panel.center()
	ui.terrain_panel.show_height(world_view.ground_height(center.x, center.y))
	if get_viewport().gui_get_hovered_control() == null:
		var hit: Dictionary = world_view.pick_terrain(camera, get_viewport().get_mouse_position())
		if not hit.is_empty():
			center = Vector2(hit.position.x, -hit.position.z)
	world_view.show_brush(center, ui.terrain_panel.fields.radius.value)

func _action(action: String) -> void:
	match action:
		"terrain_mode":
			_set_walk(false)
			ui.inspector_tabs.current_tab = 1
		"create":
			var p := WorldView.to_world(orbit_target)
			p[0] = clampf(p[0] + randf_range(-3, 3), 2, 254)
			p[1] = clampf(p[1] - 8, 2, 254)
			p[2] = world_view.ground_height(p[0], p[1]) + 1
			var item := Schema.box("新立方体", p, [2.0, 2.0, 2.0], "#50A696")
			var result: Dictionary = service.request("CreateObject", {"object": item})
			if result.ok:
				selected_id = item.id
			_feedback(result)
		"duplicate":
			var item: Dictionary = service.model.object(selected_id)
			if item.is_empty():
				return
			item.id = Schema.uuid()
			item.name = item.name.left(75) + " 副本"
			item.position[0] += float(item.size[0]) + 1
			var result: Dictionary = service.request("CreateObject", {"object": item})
			if result.ok:
				selected_id = item.id
			_feedback(result)
		"delete":
			if not selected_id.is_empty():
				_feedback(service.request("DeleteObject", {"id": selected_id}))
				if service.model.object(selected_id).is_empty():
					_select("")
		"ground":
			var item: Dictionary = service.model.object(selected_id)
			if item.is_empty():
				return
			var position: Array = item.position.duplicate()
			position[2] = world_view.ground_height(position[0], position[1]) + item.size[2] * 0.5
			_patch({"position": position})
		"save":
			_feedback(service.request("SaveRegion"))
		"load":
			_confirm("load", "恢复上次存档？当前未保存的修改将被丢弃。") if service.dirty else _load()
		"undo":
			_feedback(service.request("Undo"))
		"redo":
			_feedback(service.request("Redo"))
		"focus":
			var item: Dictionary = service.model.object(selected_id)
			if not item.is_empty():
				orbit_target = WorldView.to_engine(item.position)
				orbit_distance = clampf(maxf(item.size[0], maxf(item.size[1], item.size[2])) * 4.5, 14, 100)
				_update_camera()
		"walk":
			_set_walk(not walk_mode)
		"help":
			var help := AcceptDialog.new()
			help.title = "区域实验室 · 操作指南"
			help.dialog_text = "物体：左键选择，在属性面板编辑后应用。\n地形：切换地形页，选择笔刷，在地表单击或输入坐标后应用。\n右键旋转视角，中键平移，滚轮缩放，F 聚焦对象。\nCtrl+D 复制，Delete 删除，Ctrl+Z 撤销，Ctrl+Y 重做。\n\n漫游：Tab 进入，WASD 移动，空格跳跃，Shift 加速。\nEsc 返回编辑模式。\n\nCtrl+S 保存世界，Ctrl+O 恢复存档。\n物体和地形一起保存；操作历史仅在本次会话中保留。\n\n存档位置：\n" + service.repository.path
			help.min_size = Vector2i(660, 380)
			help.confirmed.connect(help.queue_free)
			help.canceled.connect(help.queue_free)
			add_child(help)
			help.popup_centered()

func _feedback(result: Dictionary) -> void:
	_refresh()
	if not result.ok:
		ui.set_status("操作未完成 · " + result.errors[0].code, true)
		var message := AcceptDialog.new()
		message.title = "操作未完成"
		message.dialog_text = result.errors[0].message
		message.confirmed.connect(message.queue_free)
		message.canceled.connect(message.queue_free)
		add_child(message)
		message.popup_centered(Vector2i(610, 180))
	elif not result.warnings.is_empty():
		ui.set_status("●  已恢复备份，请检查并保存", true)
	elif result.operation == "SaveRegion":
		ui.set_status("●  保存成功 · " + Time.get_time_string_from_system())
	elif result.operation == "SculptTerrain":
		ui.set_status("地形已更新 · %d 个采样点" % result.payload.changed_samples, service.dirty)

func _load() -> void:
	var result: Dictionary = service.request("LoadRegion")
	if result.ok:
		_rebuild()
	_feedback(result)

func _confirm(action: String, message: String) -> void:
	_dialog_action = action
	_dialog.dialog_text = message
	_dialog.popup_centered(Vector2i(530, 170))

func _confirmed() -> void:
	if _dialog_action == "load":
		_load()
	elif _dialog_action == "quit":
		get_tree().quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and service != null:
		_set_walk(false)
		if service.dirty:
			_confirm("quit", "世界有未保存的修改。直接退出将丢失这些修改。\n选择取消后可点击「保存世界」。")
		else:
			get_tree().quit()

func _set_walk(active: bool) -> void:
	walk_mode = active
	avatar.active = active
	avatar.camera.current = active
	camera.current = not active
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if active else Input.MOUSE_MODE_VISIBLE
	ui.set_walk(active)

func _update_camera() -> void:
	camera.position = orbit_target + Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch)) * orbit_distance
	camera.look_at(orbit_target)

func _input(event: InputEvent) -> void:
	if ui == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_set_walk(false)
			get_viewport().set_input_as_handled()
		elif not ui.typing():
			if event.keycode == KEY_TAB:
				_action("walk")
				get_viewport().set_input_as_handled()
			elif event.ctrl_pressed and event.keycode in [KEY_S, KEY_O, KEY_Z, KEY_Y, KEY_D]:
				_action({KEY_S: "save", KEY_O: "load", KEY_Z: "undo", KEY_Y: "redo", KEY_D: "duplicate"}[event.keycode])
				get_viewport().set_input_as_handled()
			elif not walk_mode and event.keycode == KEY_F:
				_action("focus")
			elif not walk_mode and event.keycode == KEY_DELETE:
				_action("delete")
	if walk_mode and event is InputEventMouseMotion:
		avatar.look(event.relative)

func _unhandled_input(event: InputEvent) -> void:
	if walk_mode:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if ui.inspector_tabs.current_tab == 1:
				var hit: Dictionary = world_view.pick_terrain(camera, event.position)
				if not hit.is_empty():
					var payload: Dictionary = ui.terrain_panel.parameters()
					ui.terrain_panel.set_center(Vector2(hit.position.x, -hit.position.z))
					var center: Vector2 = ui.terrain_panel.center()
					payload.center = [center.x, center.y]
					_sculpt(payload)
			else:
				_select(world_view.pick(camera, event.position))
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_distance = clampf(orbit_distance * (0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 8, 180)
			_update_camera()
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			orbit_yaw -= event.relative.x * 0.007
			orbit_pitch = clampf(orbit_pitch + event.relative.y * 0.007, 0.12, 1.45)
			_update_camera()
		elif event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			var right := camera.global_basis.x
			var forward := Vector3(camera.global_basis.z.x, 0, camera.global_basis.z.z).normalized()
			orbit_target += (-right * event.relative.x - forward * event.relative.y) * orbit_distance * 0.0015
			orbit_target.x = clampf(orbit_target.x, 0, 256)
			orbit_target.z = clampf(orbit_target.z, -256, 0)
			_update_camera()

func _verify_render() -> void:
	# Real engine rendering evidence; no replacement UI or synthetic screenshot.
	for i in range(90):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var output := "user://verification.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot="):
			output = argument.trim_prefix("--screenshot=")
	var error := get_viewport().get_texture().get_image().save_png(output)
	print(JSON.stringify({"operation": "render", "ok": error == OK, "path": output, "objects": service.model.snapshot().objects.size()}))
	get_tree().quit(0 if error == OK else 1)
