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
var ui = preload("res://network/workspace_ui.gd").new(self)
var draft_dirty := false
var draft_request := ""
var draft_source: Dictionary = {}
var overview_target := Vector3(124, 2, -139)
var overview_spawn: Array = [124.0, 139.0, 2.0]
var orbiting := false
var created_requests: Dictionary = {}
var pending_selection := ""
var upload_requests: Dictionary = {}
var session_assets: Dictionary = {}
var capture_requested_at := 0
var capture_confirmed := false

func _ready() -> void:
	# Keep text/control sizes readable when resizing the network workspace.
	get_window().content_scale_size = Vector2i.ZERO
	_sync_web_scale()
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
		last_message = "修改已保存 · 修订 " + str(int(result.revision)) if result.ok else "操作未保存：" + str(result.code)
		if upload_requests.has(result.request_id):
			var asset: Dictionary = upload_requests[result.request_id]
			if result.ok and result.payload.get("id", "") == asset.id:
				session_assets[asset.id] = asset; _upload_bytes = ""
				ui.refresh_assets(connection.local.snapshot())
				ui.asset_picker.select(ui.asset_ids.find(asset.id))
				ui.upload_note.text = "模型已保存，可以从上方列表选择并放入场景。"
				last_message = "模型资产已保存 · 在资产页选择模型并放入场景"
			upload_requests.erase(result.request_id)
		if created_requests.has(result.request_id):
			if result.ok: pending_selection = created_requests[result.request_id]
			created_requests.erase(result.request_id)
		if result.request_id == draft_request:
			draft_request = ""
			if result.ok:
				draft_dirty = false
				_refresh_list(connection.local.snapshot()))
	if OS.has_feature("web"):
		ui.tabs.current_tab = 2; ui.help_open = false; ui.layout()
		endpoint.text = str(JavaScriptBridge.eval("location.origin"))
		JavaScriptBridge.eval("window.regionLabBooted=true; window.regionLabActions=[]; window.regionLabFile=null; window.regionLabFileEvent='';")
	elif not local_config.is_empty():
		endpoint.text = "https://127.0.0.1:" + str(int(local_config.https_port))
		ca = X509Certificate.new(); ca.load(str(local_config.certificate).get_base_dir().path_join("localhost.pem"))
		for principal in local_config.principals:
			if principal.name == profile: token_field.text = principal.token
		_login()

func _ui() -> void:
	ui.build()
	get_window().focus_exited.connect(func():
		if walking: _stop_walk()
		orbiting = false)

func _sync_web_scale() -> void:
	if not OS.has_feature("web"): return
	var dimensions: Variant = JSON.parse_string(str(JavaScriptBridge.eval("JSON.stringify([innerWidth,innerHeight])")))
	if dimensions is Array and dimensions.size() == 2:
		var size := Vector2i(int(dimensions[0]), int(dimensions[1]))
		if size.x > 0 and size.y > 0 and get_window().content_scale_size != size: get_window().content_scale_size = size

func _login() -> void:
	if token_field.text.is_empty(): last_message = "请输入实例生成的会话令牌"; return
	var base := endpoint.text.trim_suffix("/")
	if not base.begins_with("http://") and not base.begins_with("https://"): last_message = "服务地址必须使用 http 或 https"; return
	_stop_walk(); built = false; collision_projection_ready = false; render_generation += 1; interactive = false; selected = ""; last_message = ""; draft_dirty = false; draft_source = {}
	_upload_bytes = ""
	session_assets.clear(); upload_requests.clear(); created_requests.clear(); pending_selection = ""
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
	if not built:
		overview_spawn = world.region.spawn.duplicate()
		if not walking: _overview()
		view.rebuild(world); built = true
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
	var objects: Dictionary = state.get("objects", {})
	ui.refresh_assets(state)
	if not pending_selection.is_empty() and objects.has(pending_selection) and not draft_dirty:
		selected = pending_selection; pending_selection = ""
		view.select(selected); ui.show_inspector()
	var query: String = ui.search.text.strip_edges().to_lower()
	var ordered: Array = objects.values()
	ordered.sort_custom(func(a, b): return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	for item in ordered:
		if not query.is_empty() and not str(item.name).to_lower().contains(query): continue
		selection_ids.append(item.id); object_list.add_item(item.name + ("  ·  组合" if not item.group_id.is_empty() else ""))
		if item.id == selected: object_list.select(selection_ids.size() - 1)
	if objects.has(selected):
		if not draft_dirty: _fill_fields(objects[selected], state.groups.values())
	elif not selected.is_empty():
		selected = ""; draft_dirty = false; draft_source = {}; view.select("")
		name_field.clear()
		for value in coordinates: value.set_value_no_signal(0)
		ui.tabs.get_child(1).scroll_vertical = 0
		last_message = "所选对象已离开当前视野范围或被删除"

func _select(index: int) -> void:
	if index < 0 or index >= selection_ids.size(): return
	_select_id(selection_ids[index])

func _select_id(id: String) -> void:
	var state: Dictionary = connection.local.snapshot()
	if not state.get("objects", {}).has(id): return
	if selected == id and draft_dirty: ui.show_inspector(); return
	if selected != id and draft_dirty:
		last_message = "请先保存或撤回当前对象的修改，再选择其他对象"
		_refresh_list(state)
		return
	selected = id
	_fill_fields(state.objects[selected], state.groups.values())
	view.select(selected); ui.show_inspector()

func _fill_fields(item: Dictionary, groups: Array) -> void:
	var resolved := Transforms.resolve(item, groups)
	name_field.text = item.name
	for index in range(3): coordinates[index].set_value_no_signal(resolved.position[index])
	draft_source = {"name": item.name, "position": resolved.position.duplicate(), "group_id": item.group_id}
	draft_dirty = false

func _reset_draft() -> void:
	var state: Dictionary = connection.local.snapshot()
	if state.get("objects", {}).has(selected): _fill_fields(state.objects[selected], state.groups.values())
	last_message = "已撤回未提交的修改"

func _edit() -> void:
	if selected.is_empty() or draft_source.is_empty(): return
	var patch := {}
	if name_field.text != draft_source.name: patch.name = name_field.text
	var position: Array = draft_source.position.duplicate()
	for index in range(3):
		# Keep exact source coordinates for unchanged displayed values.
		if not is_equal_approx(coordinates[index].value, snappedf(float(position[index]), 0.1)): position[index] = coordinates[index].value
	if position != draft_source.position: patch.position = position
	if patch.is_empty(): draft_dirty = false; last_message = "没有需要保存的修改"; return
	draft_request = _command("UpdateObject", {"id": selected, "patch": patch})

func _focus_selected() -> void:
	if not view.bodies.has(selected): return
	if walking: _stop_walk()
	var body: Node3D = view.bodies[selected]
	overview_target = body.position
	var record: Dictionary = view._records[selected]
	var distance: float = maxf(6.0, Vector3(record.size[0], record.size[1], record.size[2]).length() * 1.8)
	camera.position = overview_target + Vector3(0.8, 0.65, 1.0).normalized() * distance
	camera.look_at(overview_target)

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
	var request := _command("CreateObject", {"object": item})
	if not request.is_empty(): created_requests[request] = item.id

func _place_asset() -> void:
	if ui.asset_picker.selected < 0 or ui.asset_ids.is_empty(): return
	var id: String = ui.asset_ids[ui.asset_picker.selected]
	var assets: Dictionary = _available_assets(connection.local.snapshot())
	if not assets.has(id): last_message = "资产已不可用，请重新选择"; return
	var asset: Dictionary = assets[id]
	var position: Array = View.to_world(own.position + Vector3(0, 0, -5).rotated(Vector3.UP, yaw))
	position[0] = clampf(position[0], float(asset.bounds[0]) * 0.5 + 1, 255 - float(asset.bounds[0]) * 0.5)
	position[1] = clampf(position[1], float(asset.bounds[1]) * 0.5 + 1, 255 - float(asset.bounds[1]) * 0.5)
	position[2] = view.ground_height(position[0], position[1]) + float(asset.bounds[2]) * 0.5 + 0.05
	var item := Schema.box(str(asset.name).left(80), position, asset.bounds.duplicate(), "#ffffff")
	item.asset_id = id; item.owner_id = connection.welcome.get("actor_id", "")
	var request := _command("CreateObject", {"object": item})
	if not request.is_empty(): created_requests[request] = item.id

func _available_assets(state: Dictionary) -> Dictionary:
	# Uploaded but uninstantiated assets are not in the server's spatial projection.
	# Retain only this session's successfully committed upload metadata, never world state.
	var assets: Dictionary = session_assets.duplicate(true)
	assets.merge(state.get("assets", {}), true)
	return assets

func _submit_upload() -> void:
	var bytes := Marshalls.base64_to_raw(_upload_bytes)
	var geometry: Dictionary = preload("res://adapters/glb_reader.gd").new().parse(bytes)
	if geometry.has("error"): last_message = "无法导入模型：" + str(geometry.error); return
	var payload := {"name": ui.upload_name.text.strip_edges(), "license": ui.upload_license.text.strip_edges(), "attribution": ui.upload_source.text.strip_edges()}
	var request := _command("UploadAsset", payload)
	if not request.is_empty():
		var id: String = Schema.MeshAssets.content_id(Schema.MeshAssets.sha256(bytes))
		upload_requests[request] = {"id": id, "kind": "mesh", "name": payload.name, "bounds": geometry.bounds.duplicate()}

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
	last_message = "已读取 GLB；请在资产页填写来源与许可"
	ui.stage_upload(name)

func _download() -> void:
	var snapshot := Wire.canonical({"format": "region-lab.observation", "version": 1, "world_epoch": connection.local.epoch, "seq": connection.local.sequence, "state": connection.local.snapshot(), "results": connection.results, "pending_request_ids": connection.pending.keys()})
	if OS.has_feature("web"): JavaScriptBridge.download_buffer(snapshot.to_utf8_buffer(), "region-observation.json", "application/json")
	else:
		var dialog := FileDialog.new(); dialog.access = FileDialog.ACCESS_FILESYSTEM; dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE; dialog.current_file = "region-observation.json"; add_child(dialog)
		dialog.file_selected.connect(func(path): var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(snapshot); file.close(); dialog.queue_free())
		dialog.canceled.connect(dialog.queue_free); dialog.popup_centered(Vector2i(850, 580))

func _walk() -> void:
	if walking: _stop_walk(); return
	if not interactive:
		last_message = "请等待连接与场景资源准备完成，再进入漫游"
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null: focus.release_focus()
	walking = true; orbiting = false; Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	capture_requested_at = Time.get_ticks_msec(); capture_confirmed = false
	last_message = "已进入漫游 · WASD 移动，鼠标转向，Esc 返回编辑"
	ui.layout()

func _stop_walk() -> void:
	walking = false; movement = Vector2.ZERO; own.jumping = false; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; _overview()
	capture_confirmed = false
	if ui.root != null: ui.layout()

func _overview() -> void:
	overview_target = View.to_engine(overview_spawn) - Vector3(0, 1.5, 0)
	camera.position = overview_target + Vector3(-26, 28, 33)
	camera.look_at(overview_target)

func _input(event: InputEvent) -> void:
	if ui.delete_dialog.visible: return
	for child in get_children():
		if child is Window and child.visible: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and walking:
			_stop_walk(); get_viewport().set_input_as_handled(); return
		var focus := get_viewport().gui_get_focus_owner()
		var typing := focus is LineEdit or focus is TextEdit
		if event.keycode == KEY_TAB and not typing:
			_walk(); get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F and not typing and not walking:
			_focus_selected(); get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if walking:
		if event is InputEventMouseMotion: yaw -= event.relative.x * 0.003; pitch = clampf(pitch - event.relative.y * 0.003, -1.3, 1.3)
		return
	if not interactive: return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT: orbiting = event.pressed
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var id: String = view.pick(camera, event.position)
			if not id.is_empty(): _select_id(id)
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var offset := camera.position - overview_target
			var factor := 0.88 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.12
			camera.position = overview_target + offset.normalized() * clampf(offset.length() * factor, 2, 180)
	if event is InputEventMouseMotion and orbiting:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT): orbiting = false; return
		var offset := camera.position - overview_target
		offset = offset.rotated(Vector3.UP, -event.relative.x * 0.006)
		var next := offset.rotated(camera.global_basis.x, -event.relative.y * 0.006)
		if next.normalized().y > 0.05 and next.normalized().y < 0.96: offset = next
		camera.position = overview_target + offset; camera.look_at(overview_target)

func _process(delta: float) -> void:
	var online: bool = connection.online()
	if online and not _was_online:
		ui.tabs.current_tab = 0
	if _was_online and not online:
		for node in view.get_children(): node.free()
		view.bodies.clear(); view._records.clear(); view.mesh_view.cache.clear()
		ui.tabs.current_tab = 2; ui.tools_open = true; ui.layout()
		if not draft_request.is_empty(): last_message = "连接中断，保存结果未知；重连后请在高级页查询请求 ID"
		created_requests.clear(); pending_selection = ""; draft_dirty = false; draft_source = {}
		session_assets.clear(); upload_requests.clear(); ui.refresh_assets({})
		for node in remote.values(): node.free()
		remote.clear(); tracks.clear(); object_list.clear(); selection_ids.clear(); selected = ""; built = false; dirty = false; _upload_bytes = ""
	_was_online = online
	interactive = online and built and collision_projection_ready and connection.assets.ready()
	own.enabled = interactive
	if dirty and online: _render_world()
	if not pending_selection.is_empty() and online: _refresh_list(connection.local.snapshot())
	if interactive and first_interactive_ms == 0: first_interactive_ms = Time.get_ticks_msec() - _started
	if not online:
		own.enabled = false
		if walking: _stop_walk()
	movement = Vector2.ZERO
	own.jumping = false
	if walking:
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		if OS.has_feature("web"): captured = bool(JavaScriptBridge.eval("document.pointerLockElement !== null"))
		if captured: capture_confirmed = true
		elif capture_confirmed: _stop_walk()
		elif Time.get_ticks_msec() - capture_requested_at > 2000:
			_stop_walk(); last_message = "未能获取鼠标控制，请再次点击「进入漫游」"
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
	ui.update()
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
	return {"interactive": interactive, "online": connection.online(), "status": connection.status, "welcome": connection.welcome, "state": connection.local.snapshot(), "seq": connection.local.sequence, "resyncs": connection.local.resyncs, "duplicates": connection.local.duplicates, "results": connection.results, "pending": connection.pending.keys(), "commands": test_commands, "nodes": view.bodies.size(), "remote_avatars": remote.size(), "position": View.to_world(own.position), "correction_m": last_correction, "max_correction_m": max_correction, "assets_ready": connection.assets.ready(), "asset_error": connection.assets.error, "asset_attempts": connection.assets.attempts, "asset_cache_count": connection.assets.cache.size(), "bytes_received": connection.bytes_received, "first_snapshot_ms": first_snapshot_ms, "first_interactive_ms": first_interactive_ms, "rendered_revision": rendered_revision, "test_serial": test_serial, "message": last_message, "fps": Engine.get_frames_per_second(), "startup_profile": startup_profile, "walking": walking, "ui_tab": ui.tabs.current_tab, "draft_dirty": draft_dirty, "ui": ui.observation()}

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
		"dismiss_help":
			if not test_directory.is_empty(): ui.help_open = false; ui.layout()
		"drop_delta":
			if not test_directory.is_empty(): connection.test_drop_delta = true
		"duplicate_delta":
			if not test_directory.is_empty(): connection.test_duplicate_delta = true

func _screenshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
