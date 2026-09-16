extends Node3D
const Schema = preload("res://domain/world_schema.gd")
const Wire = preload("res://network/wire.gd")
const View = preload("res://adapters/world_view.gd")
const Transforms = preload("res://domain/world_transforms.gd")
const Avatar = preload("res://network/network_avatar.gd")
var connection = preload("res://network/connection.gd").new()
var view = View.new()
var environment = preload("res://adapters/environment_view.gd").new()
var own = Avatar.new()
var camera := Camera3D.new()
var remote: Dictionary = {}
var tracks: Dictionary = {}
var dirty := false
var built := false
var collision_projection_ready := false
var render_generation := 0
var interactive := false
var walking := false
var yaw := 0.0
var pitch := 0.0
var input_sequence := 0
var send_elapsed := 0.0
var report_elapsed := 0.0
var movement := Vector2.ZERO
var last_correction := 0.0
var max_correction := 0.0
var rendered_revision := -1
var selected := ""
var selection_ids: Array = []
var test_directory := ""
var test_serial := -1
var test_movement := Vector2.ZERO
var test_movement_until := 0
var test_commands: Dictionary = {}
var profile := "editor-a"
var local_config: Dictionary = {}
var ca: X509Certificate
var endpoint: LineEdit
var token_field: LineEdit
var receipt_field: LineEdit
var notice: Label
var statistics: Label
var object_list: ItemList
var name_field: LineEdit
var coordinates: Array = []
var operation_picker: OptionButton
var payload_field: TextEdit
var last_message := ""
var first_interactive_ms := 0
var first_snapshot_ms := 0
var _started := Time.get_ticks_msec()
var _upload_bytes := ""
var _was_online := false
var startup_profile: Dictionary = {}

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--network-config="): local_config = JSON.parse_string(FileAccess.get_file_as_string(arg.trim_prefix("--network-config=")))
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=")
		if arg.begins_with("--network-testdir="): test_directory = arg.trim_prefix("--network-testdir=")
	add_child(connection); add_child(view); add_child(environment); add_child(own); add_child(camera)
	own.enabled = false; own.visible = false
	camera.current = true; camera.near = 0.08; camera.far = 650
	_overview()
	_ui()
	startup_profile.ui_ms = Time.get_ticks_msec() - _started
	connection.assets.changed.connect(func(): dirty = true)
	connection.updated.connect(_updated)
	connection.welcomed.connect(func(): built = false; first_snapshot_ms = 0; input_sequence = 0)
	connection.result_received.connect(func(result):
		receipt_field.text = result.request_id
		last_message = "已提交，修订 " + str(int(result.revision)) if result.ok else "操作失败：" + str(result.code))
	if OS.has_feature("web"):
		endpoint.text = str(JavaScriptBridge.eval("location.origin"))
		JavaScriptBridge.eval("window.regionLabBooted=true; window.regionLabActions=[]; window.regionLabFile=null; window.regionLabFileEvent='';")
	elif not local_config.is_empty():
		endpoint.text = "https://127.0.0.1:" + str(int(local_config.https_port))
		ca = X509Certificate.new(); ca.load(str(local_config.certificate).get_base_dir().path_join("localhost.pem"))
		for principal in local_config.principals:
			if principal.name == profile: token_field.text = principal.token
		_login()

func _ui() -> void:
	var layer := CanvasLayer.new(); add_child(layer)
	var panel := PanelContainer.new(); panel.position = Vector2(16, 16); panel.size = Vector2(355, 855); layer.add_child(panel)
	var theme := Theme.new(); theme.default_font = preload("res://fonts/RegionLabSansSC-Regular.ttf"); theme.default_font_size = 14; panel.theme = theme
	var margin := MarginContainer.new(); panel.add_child(margin)
	for key in ["margin_left", "margin_top", "margin_right", "margin_bottom"]: margin.add_theme_constant_override(key, 12)
	var scroll := ScrollContainer.new(); scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; margin.add_child(scroll)
	var column := VBoxContainer.new(); column.add_theme_constant_override("separation", 7); column.size_flags_horizontal = Control.SIZE_EXPAND_FILL; scroll.add_child(column)
	get_viewport().size_changed.connect(func(): panel.size.y = minf(855, get_viewport().get_visible_rect().size.y - 32))
	var title := Label.new(); title.text = "REGION LAB  /  V5"; title.add_theme_font_size_override("font_size", 24); column.add_child(title)
	var subtitle := Label.new(); subtitle.text = "权威区域 · 共享世界"; column.add_child(subtitle)
	endpoint = LineEdit.new(); endpoint.text = "http://127.0.0.1:19551"; endpoint.placeholder_text = "服务地址"; column.add_child(endpoint)
	token_field = LineEdit.new(); token_field.secret = true; token_field.placeholder_text = "会话令牌（仅保存在内存）"; column.add_child(token_field)
	var row := HBoxContainer.new(); column.add_child(row)
	_button(row, "连接", _login); _button(row, "断开", func(): connection.disconnect_from(); _stop_walk())
	_button(row, "漫游 / Esc", _walk)
	notice = Label.new(); notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; notice.custom_minimum_size.y = 50; column.add_child(notice)
	statistics = Label.new(); statistics.add_theme_font_size_override("font_size", 13); column.add_child(statistics)
	receipt_field = LineEdit.new(); receipt_field.placeholder_text = "请求 ID：可复制保存或粘贴查询"; column.add_child(receipt_field)
	_button(column, "查询回执", func():
		if connection.online() and Schema.is_uuid(receipt_field.text): connection.send(Wire.packet("query_result", {"request_id": receipt_field.text}))
		else: last_message = "连接后输入有效请求 ID")
	object_list = ItemList.new(); object_list.custom_minimum_size.y = 170; column.add_child(object_list); object_list.item_selected.connect(_select)
	name_field = LineEdit.new(); name_field.placeholder_text = "对象名称"; column.add_child(name_field)
	var axis_row := HBoxContainer.new(); column.add_child(axis_row)
	for axis in ["东 X", "北 Y", "高 Z"]:
		var field := SpinBox.new(); field.min_value = -64; field.max_value = 256; field.step = 0.1; field.prefix = axis; field.size_flags_horizontal = Control.SIZE_EXPAND_FILL; field.custom_minimum_size.x = 98; axis_row.add_child(field); coordinates.append(field)
	var edits := HBoxContainer.new(); column.add_child(edits)
	_button(edits, "提交位置", _edit); _button(edits, "门 / 灯", _toggle); _button(edits, "删除", _delete)
	var create_row := HBoxContainer.new(); column.add_child(create_row)
	_button(create_row, "新建方块", _create); _button(create_row, "选择 GLB", _pick_file); _button(create_row, "重试资产", func(): connection.assets.retry())
	var label := Label.new(); label.text = "命令操作（JSON 参数，服务器校验）"; column.add_child(label)
	operation_picker = OptionButton.new(); column.add_child(operation_picker)
	for operation in Wire.MUTATIONS: operation_picker.add_item(operation)
	payload_field = TextEdit.new(); payload_field.custom_minimum_size.y = 100; payload_field.text = "{}"; column.add_child(payload_field)
	var actions := HBoxContainer.new(); column.add_child(actions)
	_button(actions, "发送命令", func():
		var payload: Variant = JSON.parse_string(payload_field.text)
		if payload is Dictionary: _command(operation_picker.get_item_text(operation_picker.selected), payload)
		else: last_message = "参数必须是有效 JSON 对象")
	_button(actions, "导出观察记录", _download)
	var help := Label.new(); help.text = "漫游：WASD / 空格；鼠标转向；Esc 退出\n编辑收到持久化回执后生效。刷新页面需重新登录。"; help.add_theme_font_size_override("font_size", 12); column.add_child(help)

func _button(parent: Control, text: String, action: Callable) -> void:
	var button := Button.new(); button.text = text; button.pressed.connect(action); parent.add_child(button)

func _login() -> void:
	if token_field.text.is_empty(): last_message = "请输入实例生成的会话令牌"; return
	var base := endpoint.text.trim_suffix("/")
	if not base.begins_with("http://") and not base.begins_with("https://"): last_message = "服务地址必须使用 http 或 https"; return
	_stop_walk(); built = false; collision_projection_ready = false; render_generation += 1; interactive = false; selected = ""; last_message = ""
	_upload_bytes = ""
	for node in remote.values(): node.queue_free()
	remote.clear(); tracks.clear()
	connection.connect_to(base.replace("https://", "wss://").replace("http://", "ws://") + "/ws", token_field.text, base, ca)

func _command(operation: String, payload: Dictionary) -> String:
	if not interactive or connection.welcome.get("role") == "observer": last_message = "当前不可编辑：等待连接、资产或编辑权限"; return ""
	if operation == "UploadAsset":
		if str(payload.get("license", "")).begins_with("请填写") or str(payload.get("attribution", "")).begins_with("请填写"): last_message = "请先填写模型许可和来源"; return ""
		if not payload.has("bytes") and not _upload_bytes.is_empty(): payload = payload.duplicate(true); payload.bytes = _upload_bytes
	var id: String = connection.command(operation, payload)
	receipt_field.text = id
	last_message = "等待服务器提交" if not id.is_empty() else "未发送：连接不可用"
	return id

func _updated(world_changed: bool) -> void:
	if world_changed: collision_projection_ready = false
	if first_snapshot_ms == 0: first_snapshot_ms = Time.get_ticks_msec() - _started
	dirty = dirty or world_changed
	var state: Dictionary = connection.local.snapshot()
	var now := Time.get_ticks_msec()
	var self_id: String = connection.welcome.avatar_id
	for id in state.avatars:
		var record: Dictionary = state.avatars[id]
		if id == self_id:
			var target := View.to_engine(record.position)
			last_correction = own.position.distance_to(target)
			if built: max_correction = maxf(max_correction, last_correction)
			if not built or last_correction > 2: own.position = target; own.velocity = View.to_engine(record.velocity)
			else: own.position = own.position.lerp(target, 0.35)
		else:
			if not remote.has(id):
				var avatar = Avatar.new(); avatar.enabled = false; add_child(avatar); remote[id] = avatar
			if not tracks.has(id): tracks[id] = []
			tracks[id].append({"at": now, "record": record})
			if tracks[id].size() > 12: tracks[id].pop_front()
	for id in remote.keys():
		if not state.avatars.has(id): remote[id].queue_free(); remote.erase(id); tracks.erase(id)

func _render_world() -> void:
	var began := Time.get_ticks_msec()
	render_generation += 1
	var generation := render_generation
	var state: Dictionary = connection.local.snapshot()
	if state.is_empty(): return
	var world: Dictionary = state.meta.duplicate(true)
	world.objects = state.objects.values(); world.groups = state.groups.values(); world.assets = connection.assets.records()
	if not connection.assets.ready():
		# Visible placeholders are never used to permit movement. The entire client
		# stays unready until the collision-bearing content has passed validation.
		for item in world.objects:
			if state.assets[item.asset_id].kind == "mesh": item.asset_id = Schema.BOX_ASSET; item.color = "#c78353"
	else:
		var error := Schema.validate(world)
		if not error.is_empty(): last_message = error; interactive = false; return
	var validated := Time.get_ticks_msec()
	if not built: view.rebuild(world); built = true
	else: view.sync_terrain(world.terrain, world.region.size); view.sync_objects(world.objects, world.groups, world.assets)
	var projected := Time.get_ticks_msec()
	environment.sync(world.environment)
	rendered_revision = int(world.revision)
	_refresh_list(state)
	dirty = false
	if first_interactive_ms == 0: startup_profile[str(Time.get_ticks_msec() - _started)] = {"ready": connection.assets.ready(), "validation_ms": validated - began, "projection_ms": projected - validated, "other_ms": Time.get_ticks_msec() - projected}
	if connection.assets.ready():
		if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw
		if generation == render_generation: collision_projection_ready = true

func _refresh_list(state: Dictionary) -> void:
	object_list.clear(); selection_ids.clear()
	for item in state.objects.values():
		selection_ids.append(item.id); object_list.add_item(item.name + ("  ·  组合" if not item.group_id.is_empty() else ""))
		if item.id == selected: object_list.select(selection_ids.size() - 1)
	if not selected.is_empty() and state.objects.has(selected): _fill_fields(state.objects[selected], state.groups.values())

func _select(index: int) -> void:
	selected = selection_ids[index]
	var state: Dictionary = connection.local.snapshot()
	_fill_fields(state.objects[selected], state.groups.values())
	view.select(selected)

func _fill_fields(item: Dictionary, groups: Array) -> void:
	var resolved := Transforms.resolve(item, groups)
	name_field.text = item.name
	for index in range(3): coordinates[index].value = resolved.position[index]

func _edit() -> void:
	if selected.is_empty(): return
	_command("UpdateObject", {"id": selected, "patch": {"name": name_field.text, "position": [coordinates[0].value, coordinates[1].value, coordinates[2].value]}})

func _toggle() -> void:
	var state: Dictionary = connection.local.snapshot()
	if not state.get("objects", {}).has(selected): return
	var item: Dictionary = state.objects[selected]
	_command("SetObjectState", {"id": selected, "active": not item.state.get("active", false)})

func _delete() -> void:
	if not selected.is_empty(): _command("DeleteObject", {"id": selected})

func _create() -> void:
	var item := Schema.box("共享方块", [132.0, 122.0, 1.0], [1.0, 1.0, 1.0], "#78a5b5")
	item.owner_id = connection.welcome.get("actor_id", "")
	_command("CreateObject", {"object": item})

func _pick_file() -> void:
	if OS.has_feature("web"): JavaScriptBridge.eval("document.getElementById('region-file').click()"); return
	var dialog := FileDialog.new(); dialog.access = FileDialog.ACCESS_FILESYSTEM; dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE; dialog.filters = PackedStringArray(["*.glb ; Static GLB"])
	add_child(dialog); dialog.file_selected.connect(func(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null and file.get_length() <= 2097152: _upload(Marshalls.raw_to_base64(file.get_buffer(file.get_length())), path.get_file())
		else: last_message = "GLB 超过 2 MiB 或不可读取"
		dialog.queue_free())
	dialog.canceled.connect(func(): last_message = "已取消选择，世界未更改"; dialog.queue_free())
	dialog.popup_centered(Vector2i(850, 580))

func _upload(bytes: String, name: String) -> void:
	# Provenance is supplied explicitly in the command form for non-CC0 assets.
	_upload_bytes = bytes
	operation_picker.select(Wire.MUTATIONS.find("UploadAsset"))
	payload_field.text = Wire.canonical({"name": name, "license": "请填写授权许可", "attribution": "请填写来源"})
	last_message = "已读取 GLB；请填写 license / attribution 后发送命令"

func _download() -> void:
	var snapshot := Wire.canonical({"format": "region-lab.observation", "version": 1, "world_epoch": connection.local.epoch, "seq": connection.local.sequence, "state": connection.local.snapshot(), "results": connection.results, "pending_request_ids": connection.pending.keys()})
	if OS.has_feature("web"): JavaScriptBridge.download_buffer(snapshot.to_utf8_buffer(), "region-observation.json", "application/json")
	else:
		var dialog := FileDialog.new(); dialog.access = FileDialog.ACCESS_FILESYSTEM; dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE; dialog.current_file = "region-observation.json"; add_child(dialog)
		dialog.file_selected.connect(func(path): var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(snapshot); file.close(); dialog.queue_free())
		dialog.canceled.connect(dialog.queue_free); dialog.popup_centered(Vector2i(850, 580))

func _walk() -> void:
	if not interactive: return
	walking = true; Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _stop_walk() -> void:
	walking = false; movement = Vector2.ZERO; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; _overview()

func _overview() -> void:
	camera.position = Vector3(155, 27, -99); camera.look_at(Vector3(124, 2, -139))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE: _stop_walk()
	if walking and event is InputEventMouseMotion: yaw -= event.relative.x * 0.003; pitch = clampf(pitch - event.relative.y * 0.003, -1.3, 1.3)

func _process(delta: float) -> void:
	var online: bool = connection.online()
	if _was_online and not online:
		for node in view.get_children(): node.free()
		view.bodies.clear(); view._records.clear(); view.mesh_view.cache.clear()
		for node in remote.values(): node.free()
		remote.clear(); tracks.clear(); object_list.clear(); selection_ids.clear(); selected = ""; built = false; dirty = false; _upload_bytes = ""
	_was_online = online
	interactive = online and built and collision_projection_ready and connection.assets.ready()
	own.enabled = interactive
	if dirty and online: _render_world()
	if interactive and first_interactive_ms == 0: first_interactive_ms = Time.get_ticks_msec() - _started
	if not online:
		own.enabled = false
		if walking: _stop_walk()
	movement = Vector2.ZERO
	if walking and interactive and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var axes := Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S)))
		movement = axes.rotated(yaw).limit_length()
		own.jumping = Input.is_physical_key_pressed(KEY_SPACE)
	if Time.get_ticks_msec() < test_movement_until and interactive: movement = test_movement
	if OS.has_feature("web") and bool(JavaScriptBridge.eval("document.hidden")): movement = Vector2.ZERO; own.jumping = false
	own.controls = movement; own.yaw = yaw; own.input_at = Time.get_ticks_msec()
	send_elapsed += delta
	if send_elapsed >= 0.05 and interactive:
		send_elapsed = fmod(send_elapsed, 0.05); input_sequence += 1
		connection.send(Wire.packet("input", {"sequence": input_sequence, "axis": [movement.x, movement.y], "yaw": yaw, "jump": own.jumping}))
	if walking: camera.position = own.position + Vector3(0, 1.65, 0); camera.rotation = Vector3(pitch, yaw, 0)
	_interpolate()
	notice.text = connection.status + ("\n" + last_message if not last_message.is_empty() else "")
	if online and not connection.assets.ready(): notice.text = "等待必要碰撞资产 · " + connection.assets.error
	statistics.text = "修订 %d  /  序列 %d  /  对象 %d\n角色 %d  /  收到 %.1f KiB  /  校正 %.3f m" % [rendered_revision, connection.local.sequence, view.bodies.size(), remote.size() + int(online), connection.bytes_received / 1024.0, last_correction]
	report_elapsed += delta
	if report_elapsed >= 0.2:
		report_elapsed = 0
		_bridge()

func _interpolate() -> void:
	var time := Time.get_ticks_msec() - 100
	for id in tracks:
		var history: Array = tracks[id]
		if history.is_empty(): continue
		var left: Dictionary = history[0]
		var right: Dictionary = history[-1]
		for sample in history:
			if sample.at <= time: left = sample
			if sample.at >= time: right = sample; break
		var position := View.to_engine(left.record.position)
		if right.at > left.at: position = position.lerp(View.to_engine(right.record.position), clampf(float(time - int(left.at)) / float(int(right.at) - int(left.at)), 0, 1))
		elif time > int(right.at): position = View.to_engine(right.record.position) + View.to_engine(right.record.velocity) * minf(float(time - int(right.at)) / 1000, 0.2)
		remote[id].position = position; remote[id].rotation.y = right.record.yaw

func _observation() -> Dictionary:
	return {"interactive": interactive, "online": connection.online(), "status": connection.status, "welcome": connection.welcome, "state": connection.local.snapshot(), "seq": connection.local.sequence, "resyncs": connection.local.resyncs, "duplicates": connection.local.duplicates, "results": connection.results, "pending": connection.pending.keys(), "commands": test_commands, "nodes": view.bodies.size(), "remote_avatars": remote.size(), "position": View.to_world(own.position), "correction_m": last_correction, "max_correction_m": max_correction, "assets_ready": connection.assets.ready(), "asset_error": connection.assets.error, "asset_attempts": connection.assets.attempts, "asset_cache_count": connection.assets.cache.size(), "bytes_received": connection.bytes_received, "first_snapshot_ms": first_snapshot_ms, "first_interactive_ms": first_interactive_ms, "rendered_revision": rendered_revision, "test_serial": test_serial, "message": last_message, "fps": Engine.get_frames_per_second(), "startup_profile": startup_profile}

func _bridge() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.regionLabObservation=" + Wire.canonical(_observation()) + ";")
		var actions: Variant = JSON.parse_string(str(JavaScriptBridge.eval("JSON.stringify(window.regionLabActions.splice(0))")))
		if actions is Array:
			for action in actions: _action(action)
		var upload: Variant = JSON.parse_string(str(JavaScriptBridge.eval("JSON.stringify(window.regionLabFile)")))
		if upload is Dictionary: _upload(upload.bytes, upload.name); JavaScriptBridge.eval("window.regionLabFile=null")
		var event: String = str(JavaScriptBridge.eval("window.regionLabFileEvent"))
		if not event.is_empty(): last_message = event; JavaScriptBridge.eval("window.regionLabFileEvent=''")
	if test_directory.is_empty(): return
	var control_path := test_directory.path_join("control.json")
	if FileAccess.file_exists(control_path):
		var control: Variant = JSON.parse_string(FileAccess.get_file_as_string(control_path))
		if control is Dictionary and int(control.get("serial", -1)) > test_serial:
			test_serial = int(control.serial)
			for action in control.get("actions", []): _action(action)
	var output := test_directory.path_join("observation.json")
	var file := FileAccess.open(output + ".tmp", FileAccess.WRITE); file.store_string(Wire.canonical(_observation())); file.close()
	DirAccess.rename_absolute(output + ".tmp", output)

func _action(action: Dictionary) -> void:
	match action.get("type", ""):
		"login": endpoint.text = action.url; token_field.text = action.token; _login()
		"disconnect": connection.disconnect_from()
		"command": test_commands[action.get("label", "last")] = _command(action.operation, action.payload)
		"interest": connection.send(Wire.packet("interest", {"centre": action.centre, "radius": action.radius}))
		"input": test_movement = Vector2(action.axis[0], action.axis[1]).limit_length(); test_movement_until = Time.get_ticks_msec() + int(action.get("duration_ms", 1000))
		"retry_assets": connection.assets.retry()
		"query_result": connection.send(Wire.packet("query_result", {"request_id": action.request_id}))
		"resync": connection.send(Wire.packet("resync"))
		"download": _download()
		"walk": _walk()
		"stop_walk": _stop_walk()
		"screenshot":
			if not test_directory.is_empty(): _screenshot(test_directory.path_join("client.png"))
		"drop_delta":
			if not test_directory.is_empty(): connection.test_drop_delta = true
		"duplicate_delta":
			if not test_directory.is_empty(): connection.test_duplicate_delta = true

func _screenshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
