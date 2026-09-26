extends Node3D
const Schema = preload("res://domain/world_schema.gd")
const Wire = preload("res://network/wire.gd")
const View = preload("res://adapters/world_view.gd")
const Transforms = preload("res://domain/world_transforms.gd")
const Avatar = preload("res://network/network_avatar.gd")
const BuildPreview = preload("res://network/build_preview.gd")
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
var flying := false
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
var selected_ids: Array = []
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
var panning := false
var right_origin := Vector2.ZERO
var context_hit: Dictionary = {}
var auto_target: Array = []
var auto_last_distance := INF
var auto_stalled := 0.0
var created_requests: Dictionary = {}
var pending_selection := ""
var upload_requests: Dictionary = {}
var session_assets: Dictionary = {}
var inventory_items: Dictionary = {}
var inventory_requests: Dictionary = {}
var inventory_loaded := false
var inventory_requested := false
var placing := false
var placement_asset_id := ""
var placement_item_id := ""
var placement_bounds: Array = [1.0, 1.0, 1.0]
var placement_name := "共享方块"
var placement_rotation: Array = [0.0, 0.0, 0.0, 1.0]
var placement_position: Array = []
var placement_valid := false
var moving := false
var moving_id := ""
var preview = BuildPreview.new()
var capture_requested_at := 0
var capture_confirmed := false
var review_ids: Array = []
var review_selected_id := ""
var review_records: Array = []
var review_store_error := ""

func _ready() -> void:
	# Keep text/control sizes readable when resizing the network workspace.
	get_window().content_scale_size = Vector2i.ZERO
	_sync_web_scale()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--network-config="): local_config = JSON.parse_string(FileAccess.get_file_as_string(arg.trim_prefix("--network-config=")))
		if arg.begins_with("--profile="): profile = arg.trim_prefix("--profile=")
		if arg.begins_with("--network-testdir="): test_directory = arg.trim_prefix("--network-testdir=")
	_load_reviews()
	add_child(connection); add_child(view); add_child(environment); add_child(own); add_child(camera); add_child(preview)
	own.enabled = false; own.visible = false
	camera.current = true; camera.near = 0.08; camera.far = 1200
	_overview()
	_ui()
	startup_profile.ui_ms = Time.get_ticks_msec() - _started
	connection.assets.changed.connect(func(): dirty = true)
	connection.updated.connect(_updated)
	connection.welcomed.connect(func(): built = false; first_snapshot_ms = 0; input_sequence = 0)
	connection.inventory_result_received.connect(_inventory_result)
	connection.result_received.connect(func(result):
		receipt_field.text = result.request_id
		last_message = "修改已保存 · 修订 " + str(int(result.revision)) if result.ok else "操作未保存：" + str(result.code)
		if upload_requests.has(result.request_id):
			var asset: Dictionary = upload_requests[result.request_id]
			if result.ok and result.payload.get("id", "") == asset.id:
				session_assets[asset.id] = asset; _upload_bytes = ""
				connection.inventory("add", {"asset_id": asset.id, "name": asset.name})
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
		orbiting = false; panning = false)

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
	_cancel_place(); _stop_walk(); built = false; collision_projection_ready = false; render_generation += 1; interactive = false; selected = ""; selected_ids.clear(); last_message = ""; draft_dirty = false; draft_source = {}
	_upload_bytes = ""
	session_assets.clear(); upload_requests.clear(); created_requests.clear(); pending_selection = ""; inventory_items.clear(); inventory_requests.clear(); inventory_loaded = false; inventory_requested = false
	ui.clear_inventory()
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
	else:
		if view._region_size != Vector2(world.region.size[0], world.region.size[1]): view.rebuild(world)
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
		selected_ids = [selected]
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
		selected = ""; selected_ids.clear(); draft_dirty = false; draft_source = {}; view.select("")
		name_field.clear()
		for value in coordinates: value.set_value_no_signal(0)
		ui.tabs.get_child(1).scroll_vertical = 0
		last_message = "所选对象已离开当前视野范围或被删除"
	_refresh_reviews(state)
	selected_ids = selected_ids.filter(func(id): return objects.has(id))
	_sync_selected_outlines()

func _review_path() -> String:
	return test_directory.path_join("expert-reviews.json") if not test_directory.is_empty() else "user://expert-reviews.json"

func _load_reviews() -> void:
	var path := ProjectSettings.globalize_path(_review_path())
	if not FileAccess.file_exists(path):
		var recovery := path + ".bak" if FileAccess.file_exists(path + ".bak") else path + ".tmp"
		if not FileAccess.file_exists(recovery): return
		var recovered: Variant = _read_reviews(recovery)
		if not recovered is Array or DirAccess.rename_absolute(recovery, path) != OK:
			review_store_error = "本地审阅备份无法恢复，请先备份原文件"; return
		review_records = recovered
		return
	var loaded: Variant = _read_reviews(path)
	if loaded is Array: review_records = loaded
	else: review_store_error = "本地审阅记录格式无效，请先备份原文件"

func _read_reviews(path: String) -> Variant:
	var input := FileAccess.open(path, FileAccess.READ)
	if input == null: return null
	if input.get_length() > 1024 * 1024:
		input.close(); return null
	var loaded: Variant = JSON.parse_string(input.get_as_text())
	input.close()
	if loaded is Dictionary and loaded.get("format") == "region-lab.expert-review" and loaded.get("version") == 1 and loaded.get("records") is Array and loaded.records.size() <= 1000:
		return loaded.records
	return null

func _persist_reviews() -> bool:
	var path := ProjectSettings.globalize_path(_review_path())
	var temp := path + ".tmp"
	var backup := path + ".bak"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null: return false
	file.store_string(Wire.canonical({"format": "region-lab.expert-review", "version": 1, "records": review_records}) + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK: return false
	# On Windows rename_absolute removes an existing target before moving the
	# source. Keep the previous complete file until the new one is in place.
	if FileAccess.file_exists(path) and DirAccess.rename_absolute(path, backup) != OK: return false
	if DirAccess.rename_absolute(temp, path) == OK: return true
	if not FileAccess.file_exists(path) and FileAccess.file_exists(backup):
		DirAccess.rename_absolute(backup, path)
	return false

func _refresh_reviews(state: Dictionary) -> void:
	ui.review_list.clear(); review_ids.clear()
	var objects: Dictionary = state.get("objects", {})
	var markers: Array = objects.values().filter(func(item): return str(item.get("name", "")).begins_with("预测点 · "))
	markers.sort_custom(func(a, b): return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	for item in markers:
		review_ids.append(item.id)
		ui.review_list.add_item(item.name)
		if item.id == review_selected_id: ui.review_list.select(review_ids.size() - 1)
	if not objects.has(review_selected_id): review_selected_id = ""
	ui.review_info.text = "选择预测点查看位置并记录判断。" if review_selected_id.is_empty() else _review_description(objects[review_selected_id])

func _review_description(item: Dictionary) -> String:
	return "%s\n展示位置：东 %.1f / 北 %.1f / 高 %.1f 米\n真实预测坐标见实验包；标记不代表街区积水范围。" % [item.name, float(item.position[0]), float(item.position[1]), float(item.position[2])]

func _review_select(index: int) -> void:
	if index < 0 or index >= review_ids.size(): return
	review_selected_id = str(review_ids[index])
	var state: Dictionary = connection.local.snapshot()
	if state.get("objects", {}).has(review_selected_id): ui.review_info.text = _review_description(state.objects[review_selected_id])

func _review_focus() -> void:
	if review_selected_id.is_empty(): return
	_select_id(review_selected_id)
	if selected != review_selected_id: return
	_focus_selected()
	ui.tabs.current_tab = ui.review_tab_index

func _review_save() -> void:
	var state: Dictionary = connection.local.snapshot()
	var item: Dictionary = state.get("objects", {}).get(review_selected_id, {})
	if not review_store_error.is_empty(): last_message = review_store_error; return
	if not connection.online() or item.is_empty() or not str(item.name).begins_with("预测点 · "):
		last_message = "请先连接场景并选择预测点"; return
	if not Schema.is_uuid(str(connection.welcome.get("world_instance_id", ""))):
		last_message = "场景服务缺少实例标识，请重新启动服务后审阅"; return
	var note: String = ui.review_note.text.strip_edges()
	if note.length() > 500: last_message = "审阅说明最多 500 字"; return
	if review_records.size() >= 1000: last_message = "本地审阅记录已达 1000 条，请先导出归档"; return
	var record := {"review_id": Schema.uuid(), "at_utc": Time.get_datetime_string_from_system(true, false) + "Z", "world_instance_id": connection.welcome.world_instance_id, "world_epoch": connection.local.epoch, "region_id": connection.welcome.region_id, "world_revision": int(state.meta.revision), "reviewer_account_id": connection.welcome.principal_id, "marker_object_id": review_selected_id, "marker_name": item.name, "marker_position": item.position.duplicate(), "assessment": ui.review_status.get_item_metadata(ui.review_status.selected), "note": note, "reviewer_position": View.to_world(own.position)}
	review_records.append(record)
	if not _persist_reviews():
		review_records.pop_back(); last_message = "无法保存本地审阅记录，请检查原文件或备份"; return
	ui.review_note.clear()
	last_message = "已保存审阅记录 · 可在推演审阅页导出"

func _review_export() -> void:
	var content := Wire.canonical({"format": "region-lab.expert-review", "version": 1, "records": review_records}) + "\n"
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(content.to_utf8_buffer(), "expert-reviews.json", "application/json")
	else:
		var dialog := FileDialog.new(); dialog.access = FileDialog.ACCESS_FILESYSTEM; dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE; dialog.current_file = "expert-reviews.json"; add_child(dialog)
		dialog.file_selected.connect(func(path):
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_string(content)
				file.close()
			dialog.queue_free())
		dialog.canceled.connect(dialog.queue_free); dialog.popup_centered(Vector2i(850, 580))

func _select(index: int) -> void:
	if index < 0 or index >= selection_ids.size(): return
	_select_id(selection_ids[index])

func _select_id(id: String, additive: bool = false) -> void:
	var state: Dictionary = connection.local.snapshot()
	if not state.get("objects", {}).has(id): return
	if selected == id and draft_dirty and not additive: ui.show_inspector(); return
	if selected != id and draft_dirty:
		last_message = "请先保存或撤回当前对象的修改，再选择其他对象"
		_refresh_list(state)
		return
	if additive and draft_dirty:
		last_message = "请先保存或撤回当前对象的修改，再多选其他物体"; return
	if additive:
		if id in selected_ids: selected_ids.erase(id)
		else: selected_ids.append(id)
		if selected_ids.is_empty():
			selected = ""; view.select(""); _sync_selected_outlines(); return
		id = str(selected_ids[-1])
	else:
		selected_ids = [id]
	selected = id
	_fill_fields(state.objects[selected], state.groups.values())
	view.select(selected); _sync_selected_outlines(); ui.show_inspector()

func _sync_selected_outlines() -> void:
	for id in view.bodies:
		var outline = view.bodies[id].get_node_or_null("Outline")
		if outline != null: outline.visible = id in selected_ids

func _fill_fields(item: Dictionary, groups: Array) -> void:
	var resolved := Transforms.resolve(item, groups)
	name_field.text = item.name
	for index in range(3): coordinates[index].set_value_no_signal(resolved.position[index])
	draft_source = {"name": item.name, "position": resolved.position.duplicate(), "group_id": item.group_id}
	draft_dirty = false

func _reset_draft() -> void:
	var state: Dictionary = connection.local.snapshot()
	if state.get("objects", {}).has(selected): _fill_fields(state.objects[selected], state.groups.values())
	else: draft_dirty = false; draft_source = {}
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
	var distance: float = maxf(1.5, Vector3(record.size[0], record.size[1], record.size[2]).length() * 1.8)
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
	if not interactive: return
	var point: Array = View.to_world(own.position + Vector3(0, 0, -3).rotated(Vector3.UP, yaw))
	var region: Array = connection.local.snapshot().meta.region.size
	point[0] = clampf(float(point[0]), 0.5, float(region[0]) - 0.5)
	point[1] = clampf(float(point[1]), 0.5, float(region[1]) - 0.5)
	point[2] = view.ground_height(point[0], point[1])
	_place_at(point, "")

func _context_at(point: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(point)
	var ray := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(point) * 1200.0, 3)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty(): return {}
	var position: Array = View.to_world(hit.position)
	var size: Array = connection.local.snapshot().meta.region.size
	if position[0] < 0 or position[1] < 0 or position[0] > size[0] or position[1] > size[1]: return {}
	return {"position": position, "normal": hit.normal, "id": str(hit.collider.get_meta("world_id", "")), "engine": hit.position}

func _show_context(point: Vector2) -> void:
	context_hit = _context_at(point)
	if context_hit.is_empty(): return
	var item: Dictionary = connection.local.snapshot().get("objects", {}).get(context_hit.id, {})
	var can_toggle: bool = not item.is_empty() and item.get("state", {}).has("active") and item.get("owner_id", "") == connection.welcome.get("actor_id", "")
	ui.show_context_menu(point, context_hit.normal.y > 0.45, not context_hit.id.is_empty(), ui.asset_picker.selected >= 0 and not ui.asset_ids.is_empty(), can_toggle, bool(item.get("state", {}).get("active", false)))

func _context_action(id: int) -> void:
	if context_hit.is_empty(): return
	match id:
		0:
			if context_hit.normal.y <= 0.45: return
			var destination: Array = context_hit.position.duplicate()
			destination[0] = clampf(float(destination[0]), 1, float(connection.local.snapshot().meta.region.size[0]) - 1)
			destination[1] = clampf(float(destination[1]), 1, float(connection.local.snapshot().meta.region.size[1]) - 1)
			if not walking: _walk()
			if walking:
				auto_target = destination; auto_last_distance = INF; auto_stalled = 0.0
				last_message = "正在前往所选地点 · WASD 可接管控制"
		1:
			if context_hit.normal.y <= 0.45: return
			_place_at(context_hit.position, "")
		2:
			if context_hit.normal.y <= 0.45 or ui.asset_picker.selected < 0 or ui.asset_ids.is_empty(): return
			_place_at(context_hit.position, ui.asset_ids[ui.asset_picker.selected])
		3:
			overview_target = context_hit.engine
			var offset := camera.position - overview_target
			camera.position = overview_target + (offset.normalized() if offset.length() > 0.1 else Vector3(1, 1, 1).normalized()) * clampf(offset.length(), 4, 80)
			camera.look_at(overview_target)
		4:
			if not context_hit.id.is_empty(): _select_id(context_hit.id)
		5:
			if not context_hit.id.is_empty(): _toggle_object(context_hit.id)

func _toggle_object(id: String) -> void:
	var item: Dictionary = connection.local.snapshot().get("objects", {}).get(id, {})
	if item.is_empty() or not item.get("state", {}).has("active"): return
	if not connection.pending.is_empty():
		last_message = "上一项修改尚未保存，请稍候"
		return
	if item.get("owner_id", "") != connection.welcome.get("actor_id", ""):
		last_message = "只有物体所有者可以使用这扇门或灯"
		return
	_command("SetObjectState", {"id": id, "active": not item.state.active})

func _nearby_interaction() -> Dictionary:
	if not walking or not interactive: return {}
	var start := camera.global_position
	var ray := PhysicsRayQueryParameters3D.create(start, start - camera.global_basis.z * 3.5, 2)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty(): return {}
	var id := str(hit.collider.get_meta("world_id", ""))
	var item: Dictionary = connection.local.snapshot().get("objects", {}).get(id, {})
	if item.is_empty() or not item.get("state", {}).has("active"): return {}
	return {"id": id, "name": str(item.name), "active": bool(item.state.active), "owned": item.owner_id == connection.welcome.get("actor_id", "")}

func _interact_nearby() -> void:
	var target := _nearby_interaction()
	if target.is_empty(): last_message = "附近没有可使用的门或灯"; return
	if not target.owned: last_message = "只有物体所有者可以使用这扇门或灯"; return
	_toggle_object(target.id)

func _place_at(hit: Array, asset_id: String) -> void:
	var bounds: Array = [1.0, 1.0, 1.0]
	var name := "共享方块"
	if not asset_id.is_empty():
		var assets := _available_assets(connection.local.snapshot())
		if not assets.has(asset_id): last_message = "资产已不可用，请重新选择"; return
		bounds = assets[asset_id].bounds.duplicate()
		name = str(assets[asset_id].name).left(80)
	var size: Array = connection.local.snapshot().meta.region.size
	var position := [clampf(float(hit[0]), float(bounds[0]) * 0.5, float(size[0]) - float(bounds[0]) * 0.5), clampf(float(hit[1]), float(bounds[1]) * 0.5, float(size[1]) - float(bounds[1]) * 0.5), float(hit[2]) + float(bounds[2]) * 0.5 + 0.05]
	var item := Schema.box(name, position, bounds, "#ffffff" if not asset_id.is_empty() else "#78a5b5")
	if not asset_id.is_empty(): item.asset_id = asset_id
	item.owner_id = connection.welcome.get("actor_id", "")
	var request := _command("CreateObject", {"object": item})
	if not request.is_empty(): created_requests[request] = item.id

func _expand_region() -> void:
	if not interactive: return
	var region: Dictionary = connection.local.snapshot().meta.region
	if float(region.size[0]) >= 512: last_message = "区域已经是 512 × 512 米"; return
	_command("SetRegionSize", {"size": 512})

func _place_asset() -> void:
	if ui.asset_picker.selected < 0 or ui.asset_ids.is_empty(): return
	var id: String = ui.asset_ids[ui.asset_picker.selected]
	var assets: Dictionary = _available_assets(connection.local.snapshot())
	if not assets.has(id): last_message = "资产已不可用，请重新选择"; return
	var asset: Dictionary = assets[id]
	var position: Array = View.to_world(own.position + Vector3(0, 0, -5).rotated(Vector3.UP, yaw))
	var region: Array = connection.local.snapshot().meta.region.size
	position[0] = clampf(position[0], float(asset.bounds[0]) * 0.5 + 1, float(region[0]) - 1 - float(asset.bounds[0]) * 0.5)
	position[1] = clampf(position[1], float(asset.bounds[1]) * 0.5 + 1, float(region[1]) - 1 - float(asset.bounds[1]) * 0.5)
	position[2] = view.ground_height(position[0], position[1]) + float(asset.bounds[2]) * 0.5 + 0.05
	var item := Schema.box(str(asset.name).left(80), position, asset.bounds.duplicate(), "#ffffff")
	item.asset_id = id; item.owner_id = connection.welcome.get("actor_id", "")
	var request := _command("CreateObject", {"object": item})
	if not request.is_empty(): created_requests[request] = item.id

func _begin_place(asset_id: String) -> void:
	if not interactive or connection.welcome.get("role", "") == "observer" or not connection.pending.is_empty():
		last_message = "当前不能开始建造，请等待连接或上一次修改完成"; return
	if walking: _stop_walk()
	_cancel_place()
	var bounds: Array = [1.0, 1.0, 1.0]
	var name := "共享方块"
	if not asset_id.is_empty():
		var assets := _available_assets(connection.local.snapshot())
		if not assets.has(asset_id): last_message = "模型已不可用，请重新选择"; return
		bounds = assets[asset_id].bounds.duplicate()
		name = str(assets[asset_id].name).left(80)
	placement_asset_id = asset_id
	placement_item_id = ""
	placement_bounds = bounds
	placement_name = name
	placement_rotation = [0.0, 0.0, 0.0, 1.0]
	placing = true
	_show_initial_preview()
	last_message = "移动鼠标选择位置 · 点击放置 · R 旋转 15° · Esc 取消"

func _begin_move_selected() -> void:
	var item := _editable_selected()
	if item.is_empty(): return
	if walking: _stop_walk()
	_cancel_place()
	moving = true
	moving_id = selected
	placement_bounds = item.size.duplicate()
	placement_name = item.name
	placement_rotation = item.rotation.duplicate()
	placement_position = item.position.duplicate()
	placement_valid = true
	preview.show_pose(placement_position, placement_bounds, placement_rotation, true)
	last_message = "移动鼠标选择新位置 · 点击保存 · Esc 取消"

func _show_initial_preview() -> void:
	var point: Array = View.to_world(own.position + Vector3(0, 0, -4).rotated(Vector3.UP, yaw))
	var region: Array = connection.local.snapshot().meta.region.size
	point[0] = clampf(float(point[0]), 0.5, float(region[0]) - 0.5)
	point[1] = clampf(float(point[1]), 0.5, float(region[1]) - 0.5)
	point[2] = view.ground_height(point[0], point[1]) + float(placement_bounds[2]) * 0.5 + 0.05
	_set_preview_position(point)

func _set_preview_position(point: Array) -> void:
	placement_position = point.duplicate()
	var item := Schema.box(placement_name, point, placement_bounds, "#ffffff")
	item.rotation = placement_rotation.duplicate()
	if moving:
		var source: Dictionary = connection.local.snapshot().get("objects", {}).get(moving_id, {})
		if source.is_empty(): _cancel_place(); return
		item = Transforms.resolve(source, connection.local.snapshot().groups.values())
		item.position = point.duplicate()
		item.rotation = placement_rotation.duplicate()
	elif not placement_asset_id.is_empty(): item.asset_id = placement_asset_id
	var asset_ids: Array = []
	if Schema.kind(item.asset_id).is_empty(): asset_ids.append(item.asset_id)
	placement_valid = Schema.validate_object(item, connection.local.snapshot().meta.region, asset_ids).is_empty()
	preview.show_pose(point, placement_bounds, placement_rotation, placement_valid)

func _update_placement_preview(screen_point: Vector2) -> void:
	if not placing and not moving: return
	var origin := camera.project_ray_origin(screen_point)
	var ray := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(screen_point) * 1200.0, 3)
	if moving and view.bodies.has(moving_id): ray.exclude = [view.bodies[moving_id].get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty() or hit.normal.y <= 0.45:
		placement_valid = false; preview.hide_pose(); return
	var point: Array = View.to_world(hit.position)
	var region: Array = connection.local.snapshot().meta.region.size
	if point[0] < 0 or point[1] < 0 or point[0] > region[0] or point[1] > region[1]:
		placement_valid = false; preview.hide_pose(); return
	if moving:
		var source: Dictionary = connection.local.snapshot().objects.get(moving_id, {})
		if source.is_empty(): _cancel_place(); return
		var resolved := Transforms.resolve(source, connection.local.snapshot().groups.values())
		var source_ground := view.ground_height(float(resolved.position[0]), float(resolved.position[1]))
		point[2] += float(resolved.position[2]) - source_ground
	else: point[2] += float(placement_bounds[2]) * 0.5 + 0.05
	_set_preview_position(point)

func _confirm_preview() -> void:
	if not placement_valid or placement_position.is_empty(): last_message = "这里无法放置，请选择区域内的可行走表面"; return
	if not connection.pending.is_empty(): last_message = "上一项修改尚未保存，请稍候"; return
	if moving:
		if placement_position == connection.local.snapshot().objects.get(moving_id, {}).get("position", []):
			_cancel_place(); last_message = "位置没有变化"; return
		var move_request := _command("UpdateObject", {"id": moving_id, "patch": {"position": placement_position.duplicate()}})
		if not move_request.is_empty(): _cancel_place(); last_message = "正在保存移动结果"
		return
	if not placement_item_id.is_empty():
		var inventory_request := _command("PlaceInventoryItem", {"item_id": placement_item_id, "position": placement_position.duplicate(), "rotation": placement_rotation.duplicate(), "name": placement_name})
		if not inventory_request.is_empty(): _cancel_place(); last_message = "正在从我的素材放入场景"
		return
	var item := Schema.box(placement_name, placement_position.duplicate(), placement_bounds.duplicate(), "#ffffff")
	item.rotation = placement_rotation.duplicate()
	if not placement_asset_id.is_empty(): item.asset_id = placement_asset_id
	item.owner_id = connection.welcome.get("actor_id", "")
	var request := _command("CreateObject", {"object": item})
	if not request.is_empty():
		created_requests[request] = item.id
		_cancel_place(); last_message = "正在保存新物体"

func _cancel_place() -> void:
	placing = false; moving = false; moving_id = ""; placement_asset_id = ""; placement_item_id = ""
	placement_position.clear(); placement_valid = false
	if is_instance_valid(preview): preview.hide_pose()

func _rotate_preview(degrees: float) -> void:
	if not placing: return
	var current := Transforms.quat(placement_rotation)
	placement_rotation = Transforms.rotation(Quaternion(Vector3(0, 0, 1), deg_to_rad(degrees)) * current)
	if not placement_position.is_empty(): _set_preview_position(placement_position)

func _editable_selected() -> Dictionary:
	var state: Dictionary = connection.local.snapshot()
	var source: Dictionary = state.get("objects", {}).get(selected, {})
	if not interactive or source.is_empty() or connection.welcome.get("role", "") == "observer":
		last_message = "请先选择可编辑的对象"; return {}
	if source.get("owner_id", "") != connection.welcome.get("actor_id", ""):
		last_message = "只能修改自己的物体"; return {}
	if not source.get("group_id", "").is_empty():
		last_message = "组合成员请先解除组合，再单独编辑"; return {}
	if draft_dirty or not connection.pending.is_empty():
		last_message = "请先保存或撤回当前修改，并等待上次提交完成"; return {}
	return source

func _rotate_selected(degrees: float) -> void:
	var source := _editable_selected()
	if source.is_empty(): return
	var current := Transforms.quat(source.rotation)
	var rotation := Transforms.rotation(Quaternion(Vector3(0, 0, 1), deg_to_rad(degrees)) * current)
	_command("UpdateObject", {"id": selected, "patch": {"rotation": rotation}})

func _scale_selected(factor: float) -> void:
	var source := _editable_selected()
	if source.is_empty(): return
	if not is_finite(factor) or factor <= 0: return
	var dimensions: Array = []
	for axis in source.size:
		var value := snappedf(float(axis) * factor, 0.01)
		if value < 0.2 or value > 32.0:
			last_message = "尺寸需保持在每个方向 0.2–32 米"; return
		dimensions.append(value)
	_command("UpdateObject", {"id": selected, "patch": {"size": dimensions}})

func _group_selected() -> void:
	if selected_ids.size() < 2: last_message = "按住 Ctrl 在场景中选择至少两个自己的物体"; return
	if draft_dirty or not connection.pending.is_empty(): last_message = "请先完成当前修改"; return
	var objects: Dictionary = connection.local.snapshot().get("objects", {})
	for id in selected_ids:
		var item: Dictionary = objects.get(id, {})
		if item.is_empty() or item.owner_id != connection.welcome.get("actor_id", "") or not item.group_id.is_empty():
			last_message = "组合只能包含自己的、尚未组合的物体"; return
	_command("GroupObjects", {"id": Schema.uuid(), "name": "新组合", "root_id": selected_ids[0], "object_ids": selected_ids.duplicate()})

func _ungroup_selected() -> void:
	var item: Dictionary = connection.local.snapshot().get("objects", {}).get(selected, {})
	if item.is_empty() or item.get("group_id", "").is_empty(): last_message = "请先选择一个组合成员"; return
	if item.owner_id != connection.welcome.get("actor_id", "") or not connection.pending.is_empty(): last_message = "当前无法解除组合"; return
	_command("UngroupObjects", {"id": item.group_id})

func _available_assets(state: Dictionary) -> Dictionary:
	# Uploaded but uninstantiated assets are not in the server's spatial projection.
	# Retain only this session's successfully committed upload metadata, never world state.
	var assets: Dictionary = session_assets.duplicate(true)
	assets.merge(state.get("assets", {}), true)
	return assets

func _inventory_refresh() -> void:
	if not connection.online(): last_message = "连接后才能读取我的素材"; return
	var request: String = connection.inventory("list")
	if not request.is_empty(): inventory_requests[request] = "list"; inventory_requested = true

func _inventory_add_selected() -> void:
	var state: Dictionary = connection.local.snapshot()
	var item: Dictionary = state.get("objects", {}).get(selected, {})
	var asset_id := ""
	if ui.asset_picker.selected >= 0 and ui.asset_picker.selected < ui.asset_ids.size(): asset_id = str(ui.asset_ids[ui.asset_picker.selected])
	if asset_id.is_empty(): asset_id = str(item.get("asset_id", ""))
	var assets := _available_assets(state)
	if not assets.has(asset_id) or assets[asset_id].kind != "mesh":
		last_message = "先选择一个已导入的模型，再加入我的素材"; return
	var request: String = connection.inventory("add", {"asset_id": asset_id, "name": str(assets[asset_id].name)})
	if request.is_empty(): last_message = "无法连接素材库，请重新连接"; return
	inventory_requests[request] = "add"
	last_message = "正在保存到我的素材"

func _inventory_result(result: Dictionary) -> void:
	var request_id := str(result.get("request_id", ""))
	var action := str(inventory_requests.get(request_id, ""))
	inventory_requests.erase(request_id)
	if not result.get("ok", false):
		if result.get("code", "") == "CONNECTION_CLOSED":
			inventory_requested = false
			return
		if action != "list" or connection.online(): last_message = "素材操作失败：" + str(result.get("code", "UNKNOWN"))
		return
	var data: Dictionary = result.get("data", {})
	if data.has("items") and data.has("folders"):
		inventory_items.clear()
		for entry in data.items: inventory_items[entry.id] = entry
		inventory_loaded = true
		ui.refresh_inventory(data)
	elif data.has("item") or action == "add":
		last_message = "模型已保存到我的素材"
		_inventory_refresh()

func _place_inventory_item(item_id: String) -> void:
	if not inventory_items.has(item_id): last_message = "素材列表已过期，请刷新"; return
	var entry: Dictionary = inventory_items[item_id]
	if entry.has("asset_error") or not entry.get("bounds") is Array:
		last_message = "素材内容不可用（" + str(entry.get("asset_error", "缺少尺寸")) + "），请刷新或重新导入"
		return
	if not interactive or connection.welcome.get("role", "") == "observer" or not connection.pending.is_empty():
		last_message = "当前不能放置素材"; return
	if walking: _stop_walk()
	_cancel_place()
	placement_item_id = item_id
	placement_name = str(entry.get("name", "我的模型")).left(80)
	placement_bounds = entry.bounds.duplicate()
	for asset in _available_assets(connection.local.snapshot()).values():
		if asset.get("sha256", "") == entry.get("asset_sha256", ""):
			placement_bounds = asset.bounds.duplicate(); break
	placement_rotation = [0.0, 0.0, 0.0, 1.0]
	placing = true
	_show_initial_preview()
	last_message = "移动鼠标选择位置 · 点击放入场景 · R 旋转 15° · Esc 取消"

func _submit_upload() -> void:
	var bytes := Marshalls.base64_to_raw(_upload_bytes)
	var geometry: Dictionary = preload("res://adapters/glb_reader.gd").new().parse(bytes)
	if geometry.has("error"): last_message = "无法导入模型：" + str(geometry.error); return
	var payload := {"name": ui.upload_name.text.strip_edges(), "license": ui.upload_license.text.strip_edges(), "attribution": ui.upload_source.text.strip_edges()}
	var request := _command("UploadAsset", payload)
	if not request.is_empty():
		var id: String = Schema.MeshAssets.content_id(Schema.MeshAssets.sha256(bytes))
		upload_requests[request] = {"id": id, "kind": "mesh", "name": payload.name, "bounds": geometry.bounds.duplicate(), "sha256": Schema.MeshAssets.sha256(bytes)}

func _pick_file() -> void:
	if OS.has_feature("web"): JavaScriptBridge.eval("document.getElementById('region-file').click()"); return
	var dialog := FileDialog.new(); dialog.access = FileDialog.ACCESS_FILESYSTEM; dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE; dialog.filters = PackedStringArray(["*.glb, *.gltf, *.obj ; Static GLB, glTF or OBJ"])
	add_child(dialog); dialog.file_selected.connect(func(path):
		var source: Dictionary = Schema.MeshAssets.read_source(path)
		if source.has("error"): last_message = "无法读取模型：" + str(source.error)
		else: _upload(Marshalls.raw_to_base64(source.bytes), path.get_file())
		dialog.queue_free())
	dialog.canceled.connect(func(): last_message = "已取消选择，世界未更改"; dialog.queue_free())
	dialog.popup_centered(Vector2i(850, 580))

func _upload(bytes: String, name: String) -> void:
	# Provenance is supplied explicitly in the command form for non-CC0 assets.
	_upload_bytes = bytes
	operation_picker.select(Wire.MUTATIONS.find("UploadAsset"))
	payload_field.text = Wire.canonical({"name": name, "license": "请填写授权许可", "attribution": "请填写来源"})
	last_message = "已读取模型；请在资产页填写来源与许可"
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
	if placing or moving: _cancel_place()
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null: focus.release_focus()
	walking = true; orbiting = false; panning = false; Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	camera.fov = 75
	capture_requested_at = Time.get_ticks_msec(); capture_confirmed = false
	last_message = "已进入漫游 · WASD 移动，鼠标转向，Esc 返回编辑"
	ui.layout()

func _stop_walk() -> void:
	walking = false; flying = false; movement = Vector2.ZERO; auto_target.clear(); own.jumping = false; own.sprinting = false; own.flying = false; own.lift = 0.0; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; _overview()
	capture_confirmed = false
	if ui.root != null: ui.layout()

func _overview() -> void:
	overview_target = View.to_engine(overview_spawn) - Vector3(0, 1.5, 0)
	var offset := Vector3(-26, 28, 33)
	camera.fov = 75
	if connection.local != null:
		var objects: Array = connection.local.snapshot().get("objects", {}).values()
		if objects.size() >= 2:
			var minimum := Vector3(INF, INF, INF)
			var maximum := Vector3(-INF, -INF, -INF)
			var imported_only := true
			var imported_count := 0
			for item in objects:
				if not Schema.kind(item.asset_id).is_empty():
					imported_only = false
					continue
				imported_count += 1
				var center := View.to_engine(item.position)
				var half := Vector3(item.size[0], item.size[2], item.size[1]) * 0.5
				var basis := View.rotation_to_engine(item.rotation)
				var extent := basis.x.abs() * half.x + basis.y.abs() * half.y + basis.z.abs() * half.z
				minimum = minimum.min(center - extent)
				maximum = maximum.max(center + extent)
			if imported_only:
				overview_target = (minimum + maximum) * 0.5
				var scene_span := maxf(maximum.x - minimum.x, maximum.z - minimum.z)
				if scene_span <= 24:
					overview_target.y = minimum.y + 0.5
					var from_scene := View.to_engine(overview_spawn) - overview_target
					from_scene.y = 0
					if from_scene.length() > 4:
						offset = Vector3(from_scene.x, from_scene.length() * 0.12, from_scene.z).normalized() * clampf(scene_span * 1.6, 20, 30)
					else:
						offset = Vector3(-0.8, 0.85, -0.4).normalized() * 45
				else:
					offset = Vector3(-0.8, 0.85, -0.4).normalized() * clampf(scene_span * 1.65, 45, 600)
				camera.fov = 52
			elif imported_count >= 8:
				var span := maxf(maximum.x - minimum.x, maximum.z - minimum.z)
				var cross_span := minf(maximum.x - minimum.x, maximum.z - minimum.z)
				if span >= 40 and span >= cross_span * 2.0:
					# An assembled street with builtin road pieces is best viewed
					# from its open end, looking between the two inward-facing rows.
					overview_target = (minimum + maximum) * 0.5
					overview_target.y = minimum.y + 2.0
					if maximum.x - minimum.x >= maximum.z - minimum.z:
						offset = Vector3(-span * 0.65, span * 0.25, 0)
						yaw = -PI * 0.5
					else:
						offset = Vector3(0, span * 0.25, span * 0.65)
						yaw = 0.0
					pitch = 0.0
	camera.position = overview_target + offset
	camera.look_at(overview_target)

func _input(event: InputEvent) -> void:
	if ui.delete_dialog.visible: return
	for child in get_children():
		if child is Window and child.visible: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and (placing or moving):
			_cancel_place(); last_message = "已取消预览，场景没有修改"; get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_ESCAPE and walking:
			_stop_walk(); get_viewport().set_input_as_handled(); return
		var focus := get_viewport().gui_get_focus_owner()
		var typing := focus is LineEdit or focus is TextEdit
		if not typing and event.keycode == KEY_R and placing:
			_rotate_preview(-15.0 if event.shift_pressed else 15.0)
			get_viewport().set_input_as_handled(); return
		if not typing and not walking and not placing and not moving and event.keycode == KEY_R:
			_rotate_selected(-15.0 if event.shift_pressed else 15.0)
			get_viewport().set_input_as_handled(); return
		if not typing and not walking and not placing and not moving and event.keycode == KEY_G:
			_begin_move_selected(); get_viewport().set_input_as_handled(); return
		if event.ctrl_pressed and not typing and event.keycode in [KEY_0, KEY_8, KEY_9]:
			if event.keycode == KEY_9:
				if walking: camera.fov = 75
				else: _overview()
			else: _zoom(1 if event.keycode == KEY_0 else -1)
			get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_TAB and not typing:
			_walk(); get_viewport().set_input_as_handled()
		elif event.keycode == KEY_E and walking:
			_interact_nearby(); get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F and walking:
			if connection.welcome.get("capabilities", []).has("flight_input"):
				flying = not flying; auto_target.clear()
				last_message = "已进入飞行 · 空格上升，Ctrl 下降，F 落地" if flying else "已退出飞行 · 正在按重力下降"
			else: last_message = "当前服务不支持飞行"
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F and not typing and not walking:
			_focus_selected(); get_viewport().set_input_as_handled()
		elif event.keycode == KEY_HOME and not typing and not walking:
			_overview(); get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if walking:
		if event is InputEventMouseMotion: yaw -= event.relative.x * 0.003; pitch = clampf(pitch - event.relative.y * 0.003, -1.3, 1.3)
		if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]: _zoom(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
		return
	if not interactive: return
	if placing or moving:
		if event is InputEventMouseMotion:
			_update_placement_preview(event.position)
			return
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_update_placement_preview(event.position)
				_confirm_preview(); get_viewport().set_input_as_handled(); return
			if event.button_index == MOUSE_BUTTON_RIGHT:
				_cancel_place(); last_message = "已取消预览，场景没有修改"
				get_viewport().set_input_as_handled(); return
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				_zoom(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
				get_viewport().set_input_as_handled(); return
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE: panning = event.pressed
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed: orbiting = true; right_origin = event.position
			else:
				orbiting = false
				if event.position.distance_to(right_origin) < 6: _show_context(event.position)
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if event.alt_pressed:
				var focus_hit := _context_at(event.position)
				if not focus_hit.is_empty(): overview_target = focus_hit.engine; camera.look_at(overview_target)
			else:
				var id: String = view.pick(camera, event.position)
				if not id.is_empty():
					_select_id(id, event.ctrl_pressed)
					if event.double_click and selected == id: _focus_selected()
				elif event.double_click:
					context_hit = _context_at(event.position)
					if not context_hit.is_empty() and context_hit.normal.y > 0.45: _context_action(0)
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_zoom(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
	if event is InputEventMouseMotion and panning:
		var distance := camera.position.distance_to(overview_target)
		var shift: Vector3 = (-camera.global_basis.x * event.relative.x + camera.global_basis.y * event.relative.y) * clampf(distance / 650.0, 0.015, 1.2)
		camera.position += shift; overview_target += shift
		return
	if event is InputEventMouseMotion and orbiting:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT): orbiting = false; return
		var offset := camera.position - overview_target
		offset = offset.rotated(Vector3.UP, -event.relative.x * 0.006)
		var next := offset.rotated(camera.global_basis.x, -event.relative.y * 0.006)
		if next.normalized().y > 0.05 and next.normalized().y < 0.96: offset = next
		camera.position = overview_target + offset; camera.look_at(overview_target)

func _zoom(direction: int) -> void:
	if walking:
		camera.fov = clampf(camera.fov - direction * 5.0, 35, 95)
		return
	var offset := camera.position - overview_target
	if offset.length() < 0.1: return
	camera.position = overview_target + offset.normalized() * clampf(offset.length() * (0.8 if direction > 0 else 1.25), 1, 900)
	camera.look_at(overview_target)

func _process(delta: float) -> void:
	var online: bool = connection.online()
	if online and not _was_online:
		ui.tabs.current_tab = 0
	if _was_online and not online:
		_cancel_place()
		for node in view.get_children(): node.free()
		view.bodies.clear(); view._records.clear(); view.mesh_view.cache.clear()
		ui.tabs.current_tab = 2; ui.tools_open = true; ui.layout()
		if not draft_request.is_empty(): last_message = "连接中断，保存结果未知；重连后请在高级页查询请求 ID"
		created_requests.clear(); pending_selection = ""; draft_dirty = false; draft_source = {}
		session_assets.clear(); upload_requests.clear(); inventory_items.clear(); inventory_requests.clear(); inventory_loaded = false; inventory_requested = false; ui.refresh_assets({})
		ui.clear_inventory()
		for node in remote.values(): node.free()
		remote.clear(); tracks.clear(); object_list.clear(); selection_ids.clear(); selected_ids.clear(); selected = ""; built = false; dirty = false; _upload_bytes = ""
	_was_online = online
	if online and not inventory_requested: _inventory_refresh()
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
	own.sprinting = false
	own.flying = flying and walking and interactive
	own.lift = 0.0
	own.world_size = view._region_size.x
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
		if not auto_target.is_empty():
			if axes.length() > 0.1:
				auto_target.clear(); last_message = "已接管角色移动"
			else:
				var delta_to := Vector2(float(auto_target[0]) - own.position.x, float(auto_target[1]) + own.position.z)
				var distance := delta_to.length()
				if distance < 1.2:
					auto_target.clear(); last_message = "已到达所选地点"
				elif distance > auto_last_distance - 0.02:
					auto_stalled += delta
					if auto_stalled > 3.0: auto_target.clear(); last_message = "前方被建筑或地形阻挡，请手动绕行"
				else: auto_stalled = 0.0
				if not auto_target.is_empty():
					movement = delta_to.normalized(); yaw = atan2(-movement.x, movement.y)
				auto_last_distance = distance
		if flying:
			own.lift = float(Input.is_physical_key_pressed(KEY_SPACE)) - float(Input.is_physical_key_pressed(KEY_CTRL))
		else: own.jumping = Input.is_physical_key_pressed(KEY_SPACE)
		own.sprinting = connection.welcome.get("capabilities", []).has("sprint_input") and Input.is_physical_key_pressed(KEY_SHIFT) and axes.length() > 0.1 and auto_target.is_empty()
	if Time.get_ticks_msec() < test_movement_until and interactive: movement = test_movement
	if OS.has_feature("web") and bool(JavaScriptBridge.eval("document.hidden")): movement = Vector2.ZERO; own.jumping = false; own.sprinting = false; own.lift = 0.0
	own.controls = movement; own.yaw = yaw; own.input_at = Time.get_ticks_msec()
	send_elapsed += delta
	if send_elapsed >= 0.05 and interactive:
		send_elapsed = fmod(send_elapsed, 0.05); input_sequence += 1
		var controls_packet := {"sequence": input_sequence, "axis": [movement.x, movement.y], "yaw": yaw, "jump": own.jumping}
		if connection.welcome.get("capabilities", []).has("sprint_input"): controls_packet.sprint = own.sprinting
		if connection.welcome.get("capabilities", []).has("flight_input"): controls_packet.merge({"fly": own.flying, "lift": own.lift})
		connection.send(Wire.packet("input", controls_packet))
	if walking: camera.position = own.position + Vector3(0, 1.65, 0); camera.rotation = Vector3(pitch, yaw, 0)
	var nearby := _nearby_interaction()
	ui.interaction_prompt.text = "E · %s %s" % ["关闭" if nearby.get("active", false) else "打开", str(nearby.get("name", ""))] if nearby.get("owned", false) else ""
	ui.interaction_panel.visible = not ui.interaction_prompt.text.is_empty()
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
	return {"interactive": interactive, "online": connection.online(), "status": connection.status, "welcome": connection.welcome, "state": connection.local.snapshot(), "seq": connection.local.sequence, "resyncs": connection.local.resyncs, "duplicates": connection.local.duplicates, "results": connection.results, "pending": connection.pending.keys(), "commands": test_commands, "nodes": view.bodies.size(), "remote_avatars": remote.size(), "position": View.to_world(own.position), "correction_m": last_correction, "max_correction_m": max_correction, "assets_ready": connection.assets.ready(), "asset_error": connection.assets.error, "asset_attempts": connection.assets.attempts, "asset_cache_count": connection.assets.cache.size(), "bytes_received": connection.bytes_received, "first_snapshot_ms": first_snapshot_ms, "first_interactive_ms": first_interactive_ms, "rendered_revision": rendered_revision, "test_serial": test_serial, "message": last_message, "fps": Engine.get_frames_per_second(), "startup_profile": startup_profile, "walking": walking, "ui_tab": ui.tabs.current_tab, "draft_dirty": draft_dirty, "review_marker_count": review_ids.size(), "review_record_count": review_records.size(), "review_selected_id": review_selected_id, "ui": ui.observation()}

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
		"test_review_open":
			if not test_directory.is_empty():
				ui.help_open = false; ui.tools_open = true; ui.tabs.current_tab = ui.review_tab_index; ui.layout()
		"test_review_label":
			if not test_directory.is_empty() and not review_ids.is_empty():
				_review_select(0)
				ui.review_status.select(0)
				ui.review_note.text = str(action.get("note", "现场待核查"))
				_review_save()
		"drop_delta":
			if not test_directory.is_empty(): connection.test_drop_delta = true
		"duplicate_delta":
			if not test_directory.is_empty(): connection.test_duplicate_delta = true

func _screenshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
