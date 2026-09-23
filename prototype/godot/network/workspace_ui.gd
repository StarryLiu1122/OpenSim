extends RefCounted
## Presentation only. Commands and authoritative state remain in the client/service.
const INK := Color("e8eff5")
const MUTED := Color("a4b5c5")
const ACCENT := Color("70dfce")
var app: Node
var root: Control
var header: PanelContainer
var dock: PanelContainer
var welcome: PanelContainer
var footer: PanelContainer
var tabs: TabContainer
var badge: Label
var region_label: Label
var summary: Label
var source_credit: LinkButton
var hint: Label
var selection_title: Label
var selection_note: Label
var search: LineEdit
var walk_button: Button
var tools_button: Button
var help_button: Button
var apply_button: Button
var toggle_button: Button
var reset_button: Button
var delete_button: Button
var focus_button: Button
var create_button: Button
var import_button: Button
var send_button: Button
var connect_button: Button
var disconnect_button: Button
var upload_button: Button
var upload_name: LineEdit
var upload_license: LineEdit
var upload_source: LineEdit
var upload_note: Label
var asset_picker: OptionButton
var place_button: Button
var asset_ids: Array = []
var delete_dialog: ConfirmationDialog
var delete_id := ""
var crosshair: Label
var tools_open := true
var help_open := true

func _init(client: Node) -> void:
	app = client

func box(color: Color, border: Color = Color("2c4152"), radius: int = 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color; style.border_color = border
	style.set_border_width_all(1); style.set_corner_radius_all(radius)
	style.content_margin_left = 14; style.content_margin_right = 14
	style.content_margin_top = 10; style.content_margin_bottom = 10
	return style

func theme() -> Theme:
	var result := Theme.new()
	result.default_font = preload("res://fonts/RegionLabSansSC-Regular.ttf")
	result.default_font_size = 15
	result.set_color("font_color", "Label", INK)
	for kind in ["Button", "OptionButton", "LineEdit", "TextEdit", "SpinBox"]:
		result.set_color("font_color", kind, INK)
		result.set_color("font_hover_color", kind, Color.WHITE)
		result.set_color("font_disabled_color", kind, Color("728393"))
		result.set_color("font_placeholder_color", kind, MUTED)
		result.set_color("caret_color", kind, ACCENT)
		result.set_stylebox("normal", kind, box(Color("203342")))
		result.set_stylebox("hover", kind, box(Color("2b4658"), ACCENT))
		result.set_stylebox("pressed", kind, box(Color("36596a"), ACCENT))
		result.set_stylebox("focus", kind, box(Color(0, 0, 0, 0), ACCENT))
		result.set_stylebox("disabled", kind, box(Color("192936")))
		result.set_stylebox("read_only", kind, box(Color("192936")))
	result.set_stylebox("panel", "PanelContainer", box(Color("132431f5")))
	result.set_stylebox("panel", "TabContainer", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0))
	result.set_stylebox("tab_selected", "TabContainer", box(Color("294a59"), Color("477c83"), 6))
	result.set_stylebox("tab_unselected", "TabContainer", box(Color("172a38"), Color("172a38"), 6))
	result.set_color("font_selected_color", "TabContainer", ACCENT)
	result.set_color("font_unselected_color", "TabContainer", MUTED)
	result.set_stylebox("panel", "ItemList", box(Color("101e2a")))
	result.set_stylebox("selected", "ItemList", box(Color("2a515d"), ACCENT, 6))
	result.set_stylebox("selected_focus", "ItemList", box(Color("2a515d"), ACCENT, 6))
	result.set_color("font_color", "ItemList", INK)
	result.set_constant("v_separation", "ItemList", 12)
	return result

func label(parent: Node, text: String, size: int = 15, color: Color = INK) -> Label:
	var value := Label.new(); value.text = text
	value.add_theme_font_size_override("font_size", size); value.add_theme_color_override("font_color", color)
	parent.add_child(value); return value

func note(parent: Node, text: String) -> Label:
	var value := label(parent, text, 13, MUTED)
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return value

func button(parent: Node, text: String, action: Callable, primary: bool = false) -> Button:
	var value := Button.new(); value.text = text; value.custom_minimum_size.y = 40
	value.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	value.pressed.connect(action); parent.add_child(value)
	if primary:
		value.add_theme_stylebox_override("normal", box(ACCENT, ACCENT))
		value.add_theme_stylebox_override("hover", box(Color("9cefe2"), ACCENT))
		value.add_theme_stylebox_override("pressed", box(Color("48bdae"), ACCENT))
		for state in ["font_color", "font_hover_color", "font_pressed_color"]: value.add_theme_color_override(state, Color("102a31"))
	return value

func column(parent: Node, separation: int = 12) -> VBoxContainer:
	var value := VBoxContainer.new(); value.add_theme_constant_override("separation", separation)
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL; parent.add_child(value); return value

func field(parent: Node, caption: String, placeholder: String = "") -> LineEdit:
	label(parent, caption, 13, MUTED)
	var value := LineEdit.new(); value.placeholder_text = placeholder; value.custom_minimum_size.y = 40
	parent.add_child(value); return value

func page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new(); scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; tabs.add_child(scroll)
	return column(scroll)

func build() -> void:
	var layer := CanvasLayer.new(); app.add_child(layer)
	root = Control.new(); layer.add_child(root); root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.theme = theme()
	crosshair = label(root, "+", 22, Color("e8eff5aa"))
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header = PanelContainer.new(); root.add_child(header)
	var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 16); header.add_child(top)
	var brand := column(top, 0)
	label(brand, "REGION LAB", 22)
	region_label = label(brand, "V6  /  共享三维世界", 12, MUTED)
	badge = label(top, "未连接", 14, ACCENT)
	walk_button = button(top, "进入漫游  ·  Tab", app._walk, true)
	tools_button = button(top, "工具面板", func(): tools_open = not tools_open; layout())
	help_button = button(top, "操作指南", func(): help_open = not help_open; layout())
	welcome = PanelContainer.new(); root.add_child(welcome)
	var guide := column(welcome, 10)
	label(guide, "从这里开始探索", 24)
	note(guide, "连接后，点击顶部「进入漫游」，\n或按 Tab 进入第一人称视角。")
	label(guide, "W A S D  移动    /    鼠标转向", 14, ACCENT)
	label(guide, "空格  跳跃         Esc  返回编辑", 14, ACCENT)
	note(guide, "编辑时点击场景中的对象，或在右侧搜索。\n双击列表对象可定位；右键拖动环视，滚轮缩放。")
	button(guide, "知道了，收起指南", func(): help_open = false; layout())
	dock = PanelContainer.new(); root.add_child(dock)
	tabs = TabContainer.new(); dock.add_child(tabs)
	var scene := page("场景")
	label(scene, "世界中的对象", 20)
	search = LineEdit.new(); search.placeholder_text = "搜索对象名称…"; search.clear_button_enabled = true
	search.custom_minimum_size.y = 40; scene.add_child(search)
	search.text_changed.connect(func(_text): app._refresh_list(app.connection.local.snapshot()))
	app.object_list = ItemList.new(); app.object_list.custom_minimum_size.y = 220
	app.object_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	scene.add_child(app.object_list); app.object_list.item_selected.connect(app._select)
	app.object_list.item_activated.connect(func(index): app._select(index); app._focus_selected())
	note(scene, "单击选择 · 双击定位 · 场景中也可直接点选")
	create_button = button(scene, "＋ 新建方块", app._create)
	import_button = button(scene, "导入 GLB 模型…" if OS.has_feature("web") else "导入 GLB / glTF 模型…", app._pick_file)
	note(scene, "静态模型：最大 2 MiB。选择后填写来源与许可，再提交资产。" if OS.has_feature("web") else "静态 GLB / glTF：打包后最大 2 MiB。选择后填写来源与许可，再提交资产。")
	var inspector := page("属性")
	selection_title = label(inspector, "尚未选择对象", 20)
	selection_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	selection_note = note(inspector, "在场景或对象列表中选择一个对象。")
	focus_button = button(inspector, "定位到对象  ·  F", app._focus_selected)
	app.name_field = field(inspector, "对象名称", "选择后编辑")
	app.name_field.text_changed.connect(func(_text): app.draft_dirty = true)
	label(inspector, "位置 / 米", 13, MUTED)
	for axis in ["东  X", "北  Y", "高  Z"]:
		var row := HBoxContainer.new(); inspector.add_child(row)
		var caption := label(row, axis, 14, MUTED); caption.custom_minimum_size.x = 62
		var value := SpinBox.new(); value.min_value = -64; value.max_value = 256; value.step = 0.1
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL; value.custom_minimum_size.y = 40
		row.add_child(value); app.coordinates.append(value)
		value.value_changed.connect(func(_value): app.draft_dirty = true)
	apply_button = button(inspector, "保存对象修改", app._edit, true)
	reset_button = button(inspector, "撤回未提交的修改", app._reset_draft)
	toggle_button = button(inspector, "切换门 / 灯", app._toggle)
	delete_button = button(inspector, "删除对象…", request_delete)
	delete_button.add_theme_color_override("font_color", Color("ffa899"))
	note(inspector, "修改在服务端保存成功后生效。组合成员使用世界坐标；整体变换可使用高级命令。")
	var session := page("连接")
	label(session, "连接共享世界", 20)
	note(session, "桌面启动器会自动填入本机实例。连接失败时，在这里检查地址与会话令牌。")
	app.endpoint = field(session, "服务地址", "https://127.0.0.1:19632")
	app.endpoint.text = "http://127.0.0.1:19551"
	app.token_field = field(session, "会话令牌", "粘贴分配给你的令牌"); app.token_field.secret = true
	connect_button = button(session, "连接世界", app._login, true)
	disconnect_button = button(session, "断开连接", func(): app.connection.disconnect_from(); app._stop_walk())
	button(session, "重新加载失败的资产", func(): app.connection.assets.retry())
	note(session, "当前实例使用本机连接。令牌仅用于当前会话，请勿分享整个私有配置文件。")
	var advanced := page("高级")
	label(advanced, "高级工具", 20)
	note(advanced, "常用编辑请使用属性页。这里保留完整命令入口和提交记录查询。")
	app.operation_picker = OptionButton.new(); advanced.add_child(app.operation_picker)
	for operation in app.Wire.MUTATIONS: app.operation_picker.add_item(operation)
	app.payload_field = TextEdit.new(); app.payload_field.custom_minimum_size.y = 130; app.payload_field.text = "{}"; advanced.add_child(app.payload_field)
	send_button = button(advanced, "发送命令", func():
		var payload: Variant = JSON.parse_string(app.payload_field.text)
		if payload is Dictionary: app._command(app.operation_picker.get_item_text(app.operation_picker.selected), payload)
		else: app.last_message = "参数必须是有效 JSON 对象")
	app.receipt_field = field(advanced, "提交记录 / 请求 ID", "粘贴请求 ID 查询结果")
	button(advanced, "查询提交结果", func():
		if app.connection.online() and app.Schema.is_uuid(app.receipt_field.text): app.connection.send(app.Wire.packet("query_result", {"request_id": app.receipt_field.text}))
		else: app.last_message = "连接后输入有效请求 ID")
	button(advanced, "导出观察记录", app._download)
	app.statistics = note(advanced, "")
	var assets := page("资产")
	label(assets, "模型资产", 20)
	asset_picker = OptionButton.new(); asset_picker.custom_minimum_size.y = 40; assets.add_child(asset_picker)
	place_button = button(assets, "将模型放到角色前方", app._place_asset)
	note(assets, "按模型原始尺寸放置。成功后可在属性页调整位置。")
	button(assets, "选择新的 GLB…" if OS.has_feature("web") else "选择新的 GLB / glTF…", app._pick_file)
	upload_note = note(assets, "先在场景页选择 GLB 文件。" if OS.has_feature("web") else "先在场景页选择 GLB 或 glTF 文件。")
	upload_name = field(assets, "资产名称")
	upload_license = field(assets, "授权许可", "例如 CC0-1.0，或实际授权条款")
	upload_source = field(assets, "来源与署名", "作者、来源链接或授权说明")
	upload_button = button(assets, "提交模型资产", app._submit_upload, true)
	note(assets, "列表显示当前视野引用的模型和本次会话已提交的模型。新模型提交后请放入场景，便于再次连接时选用。")
	footer = PanelContainer.new(); root.add_child(footer)
	var bottom := column(footer, 3)
	app.notice = label(bottom, "准备连接共享世界", 15)
	app.notice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	app.notice.tooltip_text = ""
	var line := HBoxContainer.new(); bottom.add_child(line)
	hint = label(line, "Tab 进入漫游  ·  点击对象选择  ·  F 定位  ·  右键环视 / 滚轮缩放", 13, MUTED)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary = label(line, "", 13, ACCENT)
	source_credit = LinkButton.new()
	source_credit.text = "© 3DBAG by tudelft3d and 3DGI"
	source_credit.tooltip_text = "https://docs.3dbag.nl/en/copyright/ · 已三角化、平移和演示着色"
	source_credit.add_theme_font_size_override("font_size", 12)
	source_credit.add_theme_color_override("font_color", ACCENT)
	source_credit.pressed.connect(func(): OS.shell_open("https://docs.3dbag.nl/en/copyright/"))
	source_credit.visible = false
	line.add_child(source_credit)
	delete_dialog = ConfirmationDialog.new(); root.add_child(delete_dialog)
	delete_dialog.title = "确认删除对象"; delete_dialog.ok_button_text = "删除"; delete_dialog.cancel_button_text = "取消"
	delete_dialog.confirmed.connect(func():
		if app.selected == delete_id: app._delete()
		else: app.last_message = "选择已改变，未执行删除")
	app.get_viewport().size_changed.connect(layout)
	layout()

func layout() -> void:
	app._sync_web_scale()
	var size: Vector2 = app.get_viewport().get_visible_rect().size
	header.position = Vector2(20, 16); header.size = Vector2(size.x - 40, 72)
	dock.position = Vector2(size.x - 364, 104); dock.size = Vector2(344, maxf(240, size.y - 214))
	welcome.position = Vector2(24, 120); welcome.size = Vector2(352, 0)
	footer.position = Vector2(20, size.y - 94); footer.size = Vector2(size.x - 40, 76)
	dock.visible = tools_open and not app.walking
	welcome.visible = help_open and not app.walking and size.x >= 1000
	tools_button.visible = not app.walking; help_button.visible = not app.walking
	tools_button.text = "收起工具" if tools_open else "展开工具"
	crosshair.position = size * 0.5 - Vector2(7, 16); crosshair.visible = app.walking

func show_inspector() -> void:
	tools_open = true; tabs.current_tab = 1; help_open = false; layout()
	tabs.get_child(1).scroll_vertical = 0

func stage_upload(name: String) -> void:
	tools_open = true; tabs.current_tab = 4
	upload_name.text = name; upload_license.clear(); upload_source.clear()
	upload_note.text = "已读取：" + name + "\n填写来源和许可后提交。"
	layout()

func request_delete() -> void:
	var objects: Dictionary = app.connection.local.snapshot().get("objects", {})
	if not objects.has(app.selected): return
	delete_id = app.selected
	delete_dialog.dialog_text = "删除「%s」？\n此操作会同步给其他用户，当前不提供撤销。" % objects[delete_id].name
	delete_dialog.popup_centered(Vector2i(440, 180))

func update() -> void:
	var online: bool = app.connection.online()
	var state: Dictionary = app.connection.local.snapshot()
	source_credit.visible = false
	for asset in state.get("assets", {}).values():
		if "© 3DBAG by tudelft3d and 3DGI" in str(asset.get("attribution", "")):
			source_credit.visible = true
			break
	region_label.text = "V6  /  " + str(state.get("meta", {}).get("region", {}).get("name", "共享三维世界")) if online else "V6  /  共享三维世界"
	var editable: bool = app.interactive and app.connection.welcome.get("role", "") != "observer"
	var objects: Dictionary = state.get("objects", {})
	var item: Dictionary = objects.get(app.selected, {})
	var chosen := not item.is_empty()
	var pending: bool = not app.connection.pending.is_empty()
	var owner_editable: bool = editable and chosen and item.get("owner_id", "") == app.connection.welcome.get("actor_id", "")
	badge.text = "正在漫游" if app.walking else ("已连接 · 可探索" if app.interactive else ("场景加载中" if online else "未连接"))
	badge.add_theme_color_override("font_color", ACCENT if app.interactive else Color("efc680"))
	walk_button.text = "返回编辑  ·  Esc" if app.walking else "进入漫游  ·  Tab"
	walk_button.disabled = not app.interactive
	walk_button.tooltip_text = "等待连接和场景资源就绪" if not app.interactive else "WASD 移动，鼠标转向，空格跳跃"
	create_button.disabled = not editable or pending; import_button.disabled = not editable
	send_button.disabled = not editable or pending
	upload_button.disabled = not editable or pending or app._upload_bytes.is_empty() or upload_name.text.strip_edges().is_empty() or upload_license.text.strip_edges().is_empty() or upload_source.text.strip_edges().is_empty()
	place_button.disabled = not editable or pending or asset_ids.is_empty()
	focus_button.disabled = not chosen
	apply_button.disabled = not owner_editable or not app.draft_dirty or pending
	reset_button.disabled = not chosen or not app.draft_dirty or pending
	delete_button.disabled = not owner_editable or pending or not item.get("group_id", "").is_empty()
	delete_button.tooltip_text = "组合成员需先解除组合，或通过高级命令删除整个组合" if not item.get("group_id", "").is_empty() else "删除前需要确认"
	toggle_button.disabled = not owner_editable or not item.get("state", {}).has("active") or pending
	app.name_field.editable = owner_editable and not pending
	for value in app.coordinates: value.editable = owner_editable and not pending
	selection_title.text = str(item.get("name", "尚未选择对象"))
	selection_note.text = "在场景或对象列表中选择一个对象。" if not chosen else ("有未提交的修改" if app.draft_dirty else ("组合成员 · 当前显示世界坐标" if not item.get("group_id", "").is_empty() else "独立对象 · 可修改名称与位置"))
	if chosen and app.connection.welcome.get("role", "") == "observer": selection_note.text = "只读会话 · 可以查看和漫游"
	connect_button.disabled = app.connection.status == "Connecting"
	disconnect_button.disabled = app.connection.peer == null
	hint.text = "W A S D 移动  ·  鼠标转向  ·  空格跳跃  ·  Esc 返回编辑" if app.walking else "Tab 漫游  ·  点击选择  ·  F 定位  ·  右键环视 / 滚轮缩放"
	summary.text = "视野内 %d 个对象 / %d 个角色" % [objects.size(), app.remote.size() + int(online)] if online else "等待连接"
	var status: String = app.connection.status
	var translated := {"Disconnected": "尚未连接 · 在连接页填写地址与会话令牌", "Connecting": "正在连接世界…", "Synchronizing": "连接成功，正在同步场景…", "Connection timeout": "连接超时 · 检查服务是否启动及地址是否正确", "Connection failed": "连接失败 · 请在连接页检查地址", "Connected": "场景已就绪 · 点击「进入漫游」开始探索", "Waiting for durable commit": "正在保存修改，请等待服务端确认…", "Recovering stream gap": "正在恢复同步，请稍候…"}
	var message: String = translated.get(status, "连接状态：" + status)
	if online and not app.interactive: message = "正在准备场景与碰撞资源，请稍候…"
	if online and not app.connection.assets.error.is_empty(): message = "资源加载失败 · 请在连接页重试资产：" + app.connection.assets.error
	if app.interactive and not app.last_message.is_empty(): message = app.last_message
	if not online and not app.last_message.is_empty(): message += " · " + app.last_message
	app.notice.text = message; app.notice.tooltip_text = message

func refresh_assets(state: Dictionary) -> void:
	var previous := str(asset_picker.get_item_metadata(asset_picker.selected)) if asset_picker.selected >= 0 else ""
	asset_picker.clear(); asset_ids.clear()
	var assets: Dictionary = app._available_assets(state)
	for asset in assets.values():
		if asset.kind != "mesh": continue
		asset_ids.append(asset.id); asset_picker.add_item(asset.name)
		asset_picker.set_item_metadata(asset_picker.item_count - 1, asset.id)
		if asset.id == previous: asset_picker.select(asset_picker.item_count - 1)
	if asset_ids.is_empty(): asset_picker.add_item("暂无已导入的模型")

func observation() -> Dictionary:
	var rect := walk_button.get_global_rect()
	var viewport: Vector2 = app.get_viewport().get_visible_rect().size
	return {"walk_button": [rect.position.x, rect.position.y, rect.size.x, rect.size.y], "viewport": [viewport.x, viewport.y], "tools_visible": dock.visible}
