extends RefCounted
## Presentation only. Commands and authoritative state remain in the client/service.
const INK := Color("f5f1e9")
const MUTED := Color("b3bdc4")
const ACCENT := Color("f2c574")
const SURFACE := Color("101c29ed")
var app: Node
var root: Control
var header: PanelContainer
var action_bar: PanelContainer
var dock: PanelContainer
var welcome: PanelContainer
var footer: PanelContainer
var tabs: TabContainer
var badge: Label
var region_label: Label
var summary: Label
var source_credit: LinkButton
var source_credit_url := ""
var hint: Label
var selection_title: Label
var selection_note: Label
var search: LineEdit
var walk_button: Button
var build_button: Button
var library_button: Button
var return_button: Button
var guide_start_button: Button
var tools_button: Button
var help_button: Button
var apply_button: Button
var toggle_button: Button
var reset_button: Button
var delete_button: Button
var focus_button: Button
var create_button: Button
var expand_button: Button
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
var preview_asset_button: Button
var preview_box_button: Button
var cancel_place_button: Button
var move_button: Button
var rotate_left_button: Button
var rotate_right_button: Button
var scale_down_button: Button
var scale_up_button: Button
var group_button: Button
var ungroup_button: Button
var terrain_mode: OptionButton
var terrain_fields: Dictionary = {}
var terrain_apply_button: Button
var environment_fields: Dictionary = {}
var water_enabled: CheckBox
var terrain_grid: CheckBox
var environment_apply_button: Button
var environment_snapshot: Dictionary = {}
var environment_target: Dictionary = {}
var environment_dirty := false
var library_search: LineEdit
var library_list: ItemList
var library_info: Label
var library_refresh_button: Button
var library_place_button: Button
var library_add_button: Button
var library_item_ids: Array = []
var library_items: Array = []
var review_list: ItemList
var review_info: Label
var review_status: OptionButton
var review_note: TextEdit
var review_save_button: Button
var review_focus_button: Button
var review_export_button: Button
var review_tab_index := -1
var asset_ids: Array = []
var delete_dialog: ConfirmationDialog
var context_menu: PopupMenu
var delete_id := ""
var crosshair: Label
var interaction_panel: PanelContainer
var interaction_prompt: Label
var tools_open := true
var help_open := true

func _init(client: Node) -> void:
	app = client

func box(color: Color, border: Color = Color("2c4152"), radius: int = 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color; style.border_color = border
	style.set_border_width_all(1); style.set_corner_radius_all(radius)
	style.anti_aliasing = true
	style.content_margin_left = 16; style.content_margin_right = 16
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
		result.set_color("font_disabled_color", kind, Color("84919c"))
		result.set_color("font_placeholder_color", kind, MUTED)
		result.set_color("caret_color", kind, ACCENT)
		result.set_stylebox("normal", kind, box(Color("213142f2"), Color("415160")))
		result.set_stylebox("hover", kind, box(Color("32465b"), ACCENT))
		result.set_stylebox("pressed", kind, box(Color("425c69"), ACCENT))
		result.set_stylebox("focus", kind, box(Color(0, 0, 0, 0), ACCENT))
		result.set_stylebox("disabled", kind, box(Color("1b2935d9"), Color("30404a")))
		result.set_stylebox("read_only", kind, box(Color("192936")))
	result.set_stylebox("panel", "PanelContainer", box(SURFACE, Color("52616b88"), 16))
	result.set_stylebox("panel", "TabContainer", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0))
	var selected_tab := box(Color("46505a"), ACCENT, 9)
	var quiet_tab := box(Color("1c2a36"), Color("1c2a36"), 9)
	for tab_style in [selected_tab, quiet_tab]:
		tab_style.content_margin_left = 7
		tab_style.content_margin_right = 7
	result.set_stylebox("tab_selected", "TabContainer", selected_tab)
	result.set_stylebox("tab_unselected", "TabContainer", quiet_tab)
	result.set_color("font_selected_color", "TabContainer", ACCENT)
	result.set_color("font_unselected_color", "TabContainer", MUTED)
	result.set_stylebox("panel", "ItemList", box(Color("0c1722bb"), Color("40515b")))
	result.set_stylebox("selected", "ItemList", box(Color("405160"), ACCENT, 8))
	result.set_stylebox("selected_focus", "ItemList", box(Color("405160"), ACCENT, 8))
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

func number_field(parent: Node, caption: String, minimum: float, maximum: float, step: float, initial: float) -> SpinBox:
	label(parent, caption, 13, MUTED)
	var value := SpinBox.new(); value.min_value = minimum; value.max_value = maximum
	value.step = step; value.value = initial; value.custom_minimum_size.y = 38
	parent.add_child(value)
	return value

func row(parent: Node) -> HBoxContainer:
	var value := HBoxContainer.new(); value.add_theme_constant_override("separation", 6)
	parent.add_child(value)
	return value

func section(parent: Node, title: String, description: String = "") -> void:
	label(parent, title, 17, ACCENT)
	if not description.is_empty(): note(parent, description)

func page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new(); scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; tabs.add_child(scroll)
	return column(scroll)

func start_exploring() -> void:
	app._walk()
	if app.walking:
		help_open = false
		layout()

func open_page(index: int) -> void:
	tools_open = true; help_open = false; tabs.current_tab = index
	layout()

func toggle_help() -> void:
	var compact := app.get_viewport().get_visible_rect().size.x < 1120
	if welcome.visible:
		help_open = false
		if compact: tools_open = true
	else:
		help_open = true
		if compact: tools_open = false
	layout()

func _build_world_controls(parent: Node) -> void:
	section(parent, "地形", "以地图坐标（东 X、北 Y）定位笔刷；可从视角中心读取地面位置。")
	terrain_mode = OptionButton.new(); terrain_mode.custom_minimum_size.y = 38
	for name in ["抬升", "降低", "设为指定高程", "平滑"]: terrain_mode.add_item(name)
	parent.add_child(terrain_mode)
	var centre := row(parent)
	terrain_fields.east = number_field(column(centre, 4), "东 X / 米", 0, 512, 0.25, 128)
	terrain_fields.north = number_field(column(centre, 4), "北 Y / 米", 0, 512, 0.25, 128)
	for value in [terrain_fields.east, terrain_fields.north]: value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button(parent, "读取视角中心的地面坐标", _choose_terrain_center)
	terrain_fields.radius = number_field(parent, "笔刷半径 / 米", 4, 32, 1, 12)
	terrain_fields.strength = number_field(parent, "笔刷强度 / %", 5, 100, 5, 50)
	terrain_fields.height = number_field(parent, "目标高程 / 米（设高时使用）", -40, 80, 0.1, 5)
	terrain_apply_button = button(parent, "应用一次地形笔刷", _apply_terrain)
	section(parent, "环境", "调整时间、雾和水面；保存后所有访问者都能看到。")
	environment_fields.sun_hour = number_field(parent, "太阳时刻 / 24 小时", 0, 24, 0.25, 15.5)
	environment_fields.water_height = number_field(parent, "水面高程 / 米", -40, 80, 0.1, -1)
	environment_fields.fog_density = number_field(parent, "雾密度 / 0–0.02", 0, 0.02, 0.0005, 0.0015)
	for value in environment_fields.values(): value.value_changed.connect(func(_value): _mark_environment_dirty())
	water_enabled = CheckBox.new(); water_enabled.text = "显示水面"; parent.add_child(water_enabled)
	terrain_grid = CheckBox.new(); terrain_grid.text = "显示地形测量网格"; parent.add_child(terrain_grid)
	water_enabled.toggled.connect(func(_value): _mark_environment_dirty())
	terrain_grid.toggled.connect(func(_value): _mark_environment_dirty())
	environment_apply_button = button(parent, "保存环境设置", _apply_environment)
	section(parent, "区域")
	expand_button = button(parent, "扩展区域至 512 × 512 米", app._expand_region)
	note(parent, "地形和环境仅由区域所有者修改；保存成功后才会同步到其他用户。")

func _choose_terrain_center() -> void:
	var centre := app.get_viewport().get_visible_rect().size * 0.5
	var hit: Dictionary = app._context_at(centre)
	if hit.is_empty() or hit.normal.y <= 0.45 or not str(hit.id).is_empty():
		app.last_message = "视角中心没有可编辑的地面，请移动视角后重试"
		return
	terrain_fields.east.set_value_no_signal(float(hit.position[0]))
	terrain_fields.north.set_value_no_signal(float(hit.position[1]))
	app.last_message = "已读取笔刷中心：X %.1f、Y %.1f" % [terrain_fields.east.value, terrain_fields.north.value]

func _apply_terrain() -> void:
	for value in terrain_fields.values(): value.apply()
	var region: Array = app.connection.local.snapshot().get("meta", {}).get("region", {}).get("size", [256.0, 256.0])
	if terrain_fields.east.value > float(region[0]) or terrain_fields.north.value > float(region[1]):
		app.last_message = "笔刷中心超出区域边界，请调整 X / Y 坐标"
		return
	app._command("SculptTerrain", {"mode": ["raise", "lower", "flatten", "smooth"][terrain_mode.selected], "center": [terrain_fields.east.value, terrain_fields.north.value], "radius": terrain_fields.radius.value, "strength": terrain_fields.strength.value / 100.0, "target_height": terrain_fields.height.value})

func _apply_environment() -> void:
	for value in environment_fields.values(): value.apply()
	var patch := {"sun_hour": environment_fields.sun_hour.value, "water_enabled": water_enabled.button_pressed, "water_height": environment_fields.water_height.value, "fog_density": environment_fields.fog_density.value, "terrain_grid": terrain_grid.button_pressed}
	if patch == environment_snapshot:
		environment_dirty = false; app.last_message = "环境设置没有变化"
		return
	if not app._command("UpdateEnvironment", {"patch": patch}).is_empty(): environment_target = patch

func _mark_environment_dirty() -> void:
	environment_dirty = true
	environment_target.clear()

func _sync_environment(data: Dictionary) -> void:
	if data.is_empty(): return
	if environment_dirty:
		if not environment_target.is_empty() and data == environment_target: environment_dirty = false; environment_target.clear()
		else: return
	if data == environment_snapshot: return
	environment_snapshot = data.duplicate(true)
	for key in environment_fields:
		environment_fields[key].set_value_no_signal(float(data.get(key, environment_fields[key].value)))
	water_enabled.set_pressed_no_signal(bool(data.get("water_enabled", false)))
	terrain_grid.set_pressed_no_signal(bool(data.get("terrain_grid", false)))

func build() -> void:
	var layer := CanvasLayer.new(); app.add_child(layer)
	root = Control.new(); layer.add_child(root); root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.theme = theme()
	crosshair = label(root, "+", 22, Color("e8eff5aa"))
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	interaction_panel = PanelContainer.new(); interaction_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.add_child(interaction_panel)
	interaction_panel.add_theme_stylebox_override("panel", box(Color("18283aee"), ACCENT))
	interaction_prompt = label(interaction_panel, "", 15, ACCENT); interaction_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	interaction_prompt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	interaction_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE; interaction_panel.visible = false
	header = PanelContainer.new(); root.add_child(header)
	header.add_theme_stylebox_override("panel", box(SURFACE, Color("f2c57477"), 14))
	var identity := HBoxContainer.new(); identity.add_theme_constant_override("separation", 12); header.add_child(identity)
	var brand := column(identity, 1)
	label(brand, "REGION LAB", 19)
	region_label = label(brand, "共享三维世界", 12, MUTED)
	region_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	badge = label(identity, "未连接", 12, ACCENT)
	action_bar = PanelContainer.new(); root.add_child(action_bar)
	action_bar.add_theme_stylebox_override("panel", box(SURFACE, Color("52616b88"), 14))
	var actions := HBoxContainer.new(); actions.add_theme_constant_override("separation", 6); action_bar.add_child(actions)
	walk_button = button(actions, "漫游  ·  Tab", app._walk, true)
	build_button = button(actions, "建造", func(): open_page(1))
	library_button = button(actions, "我的素材", func(): open_page(4))
	tools_button = button(actions, "收起面板", func(): tools_open = not tools_open; layout())
	help_button = button(actions, "指南", toggle_help)
	return_button = button(root, "返回编辑  ·  Esc", app._walk, true)
	return_button.visible = false
	welcome = PanelContainer.new(); root.add_child(welcome)
	welcome.add_theme_stylebox_override("panel", box(Color("101c29f2"), Color("f2c57499"), 16))
	var guide := column(welcome, 9)
	label(guide, "欢迎来到世界", 23)
	note(guide, "先探索地点，再用建造工具放置、修改和保存物体。")
	guide_start_button = button(guide, "开始探索  →", start_exploring, true)
	button(guide, "开始建造", func(): open_page(1))
	button(guide, "查看我的素材", func(): open_page(4))
	label(guide, "探索快捷键", 13, ACCENT)
	note(guide, "WASD 移动  ·  Shift 快跑  ·  F 飞行\n空格跳跃 / 上升  ·  Ctrl 下降  ·  E 互动\nEsc 返回编辑  ·  Tab 切换漫游")
	note(guide, "编辑时右键地点可前往或建造；滚轮缩放，双击定位。更多操作见指南。")
	dock = PanelContainer.new(); root.add_child(dock)
	dock.add_theme_stylebox_override("panel", box(Color("101c29f1"), Color("52616b99"), 16))
	var workbench := column(dock, 9)
	var workbench_head := HBoxContainer.new(); workbench.add_child(workbench_head)
	var workbench_title := label(workbench_head, "世界工作台", 17)
	workbench_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label(workbench_head, "编辑模式", 12, ACCENT)
	tabs = TabContainer.new(); tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL; workbench.add_child(tabs)
	var scene := page("探索")
	label(scene, "探索这个世界", 20)
	note(scene, "从对象列表找到地点，双击定位；右键场景可前往或在此建造。")
	button(scene, "进入漫游  ·  Tab", start_exploring, true)
	section(scene, "世界中的对象")
	search = LineEdit.new(); search.placeholder_text = "搜索对象名称…"; search.clear_button_enabled = true
	search.custom_minimum_size.y = 40; scene.add_child(search)
	search.text_changed.connect(func(_text): app._refresh_list(app.connection.local.snapshot()))
	app.object_list = ItemList.new(); app.object_list.custom_minimum_size.y = 220
	app.object_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	scene.add_child(app.object_list); app.object_list.item_selected.connect(app._select)
	app.object_list.item_activated.connect(func(index): app._select(index); app._focus_selected())
	note(scene, "单击选择 · 双击定位 · 场景中也可直接点选")
	button(scene, "打开建造工具", func(): open_page(1))
	var inspector := page("建造")
	label(inspector, "建造和编辑", 20)
	note(inspector, "选中对象后可移动、旋转和缩放；修改会在服务端保存后同步。")
	section(inspector, "放置物体")
	preview_box_button = button(inspector, "预览方块位置，再点击放置", func(): app._begin_place(""))
	create_button = button(inspector, "在角色附近快速新建方块", app._create)
	cancel_place_button = button(inspector, "取消当前预览  ·  Esc", app._cancel_place)
	section(inspector, "编辑选中对象")
	selection_title = label(inspector, "尚未选择对象", 20)
	selection_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	selection_note = note(inspector, "在场景或对象列表中选择一个对象。")
	var selection_actions := row(inspector)
	focus_button = button(selection_actions, "定位  ·  F", app._focus_selected)
	move_button = button(selection_actions, "在场景中移动", app._begin_move_selected)
	app.name_field = field(inspector, "对象名称", "选择后编辑")
	app.name_field.text_changed.connect(func(_text): app.draft_dirty = true)
	label(inspector, "位置 / 米", 13, MUTED)
	for axis in ["东  X", "北  Y", "高  Z"]:
		var row := HBoxContainer.new(); inspector.add_child(row)
		var caption := label(row, axis, 14, MUTED); caption.custom_minimum_size.x = 62
		var value := SpinBox.new(); value.min_value = -64; value.max_value = 512; value.step = 0.1
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL; value.custom_minimum_size.y = 40
		row.add_child(value); app.coordinates.append(value)
		value.value_changed.connect(func(_value): app.draft_dirty = true)
	apply_button = button(inspector, "保存名称和位置", app._edit, true)
	reset_button = button(inspector, "撤回未提交的修改", app._reset_draft)
	var rotate_actions := row(inspector)
	rotate_left_button = button(rotate_actions, "左转 15°", func(): app._rotate_selected(-15))
	rotate_right_button = button(rotate_actions, "右转 15°", func(): app._rotate_selected(15))
	var scale_actions := row(inspector)
	scale_down_button = button(scale_actions, "缩小 25%", func(): app._scale_selected(0.75))
	scale_up_button = button(scale_actions, "放大 25%", func(): app._scale_selected(1.25))
	var group_actions := row(inspector)
	group_button = button(group_actions, "组合选中对象", app._group_selected)
	ungroup_button = button(group_actions, "解除组合", app._ungroup_selected)
	toggle_button = button(inspector, "切换门 / 灯", app._toggle)
	delete_button = button(inspector, "删除对象…", request_delete)
	delete_button.add_theme_color_override("font_color", Color("ffa899"))
	note(inspector, "按住 Ctrl 点击可多选并组合。组合成员的位置按世界坐标显示；旋转和缩放请先解除组合。")
	_build_world_controls(inspector)
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
	var assets := page("素材")
	label(assets, "我的素材", 20)
	note(assets, "个人素材保存在实例中。重新连接后仍可查找并放回世界。")
	section(assets, "个人素材库")
	library_search = LineEdit.new(); library_search.placeholder_text = "搜索我的素材…"; library_search.clear_button_enabled = true
	library_search.custom_minimum_size.y = 38; assets.add_child(library_search)
	library_search.text_changed.connect(func(_text): _render_inventory())
	library_list = ItemList.new(); library_list.custom_minimum_size.y = 170
	library_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS; assets.add_child(library_list)
	library_list.item_selected.connect(func(_index): _selected_inventory())
	library_list.item_activated.connect(func(_index): _place_inventory())
	library_info = note(assets, "连接后刷新素材库，选择素材可查看来源与许可。")
	library_refresh_button = button(assets, "刷新我的素材", app._inventory_refresh)
	library_place_button = button(assets, "预览选中素材并放置", _place_inventory, true)
	section(assets, "当前世界的模型", "可先将模型存入个人素材库，再在其他会话中使用。")
	asset_picker = OptionButton.new(); asset_picker.custom_minimum_size.y = 40; assets.add_child(asset_picker)
	library_add_button = button(assets, "将当前模型存入我的素材", app._inventory_add_selected)
	preview_asset_button = button(assets, "预览后点击场景放置", func():
		if asset_picker.selected >= 0 and asset_picker.selected < asset_ids.size(): app._begin_place(asset_ids[asset_picker.selected]))
	place_button = button(assets, "在角色前方快速放置", app._place_asset)
	note(assets, "预览模式下移动鼠标选择位置，点击确认，Esc 取消。")
	import_button = button(assets, "选择新的 GLB…" if OS.has_feature("web") else "选择新的 GLB / glTF / OBJ…", app._pick_file)
	upload_note = note(assets, "先选择 GLB 文件。" if OS.has_feature("web") else "先选择 GLB、glTF 或 OBJ 文件。")
	upload_name = field(assets, "资产名称")
	upload_license = field(assets, "授权许可", "例如 CC0-1.0，或实际授权条款")
	upload_source = field(assets, "来源与署名", "作者、来源链接或授权说明")
	upload_button = button(assets, "提交模型资产", app._submit_upload, true)
	note(assets, "桌面支持 OBJ + MTL + PNG/JPEG；GLB 上限 2 MiB。上传成功后会自动存入我的素材。")
	var review := page("推演审阅")
	review_tab_index = tabs.get_child_count() - 1
	label(review, "世界模型预测点", 20)
	note(review, "预测点由实验工具提交到权威场景。这里记录人的核查意见；不会修改原始预测或模拟洪水范围。")
	review_list = ItemList.new(); review_list.custom_minimum_size.y = 130; review.add_child(review_list)
	review_list.item_selected.connect(app._review_select)
	review_info = note(review, "连接世界后，选择预测点查看位置。")
	review_focus_button = button(review, "定位到预测点", app._review_focus)
	label(review, "现场判断", 13, MUTED)
	review_status = OptionButton.new(); review_status.custom_minimum_size.y = 40; review.add_child(review_status)
	for pair in [["待核查", "unverified"], ["与现场一致", "consistent"], ["与现场不符", "inconsistent"]]:
		review_status.add_item(pair[0]); review_status.set_item_metadata(review_status.item_count - 1, pair[1])
	label(review, "说明 / 证据（最多 500 字）", 13, MUTED)
	review_note = TextEdit.new(); review_note.custom_minimum_size.y = 90; review.add_child(review_note)
	review_save_button = button(review, "保存这条审阅", app._review_save, true)
	review_export_button = button(review, "导出专家审阅 JSON", app._review_export)
	note(review, "记录保存在本机当前用户目录；导出后可与实验包按预测点 ID 和场景版本核对。")
	footer = PanelContainer.new(); root.add_child(footer)
	footer.add_theme_stylebox_override("panel", box(Color("101c29d8"), Color("52616b66"), 12))
	var bottom := column(footer, 3)
	app.notice = label(bottom, "准备连接共享世界", 15)
	app.notice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	app.notice.tooltip_text = ""
	var line := HBoxContainer.new(); bottom.add_child(line)
	hint = label(line, "Tab 探索  ·  点击选择  ·  F 定位  ·  右键菜单", 12, MUTED)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary = label(line, "", 13, ACCENT)
	source_credit = LinkButton.new()
	source_credit.text = "来源与许可"
	source_credit.add_theme_font_size_override("font_size", 12)
	source_credit.add_theme_color_override("font_color", ACCENT)
	source_credit.pressed.connect(func():
		if not source_credit_url.is_empty(): OS.shell_open(source_credit_url))
	source_credit.visible = false
	line.add_child(source_credit)
	delete_dialog = ConfirmationDialog.new(); root.add_child(delete_dialog)
	delete_dialog.title = "确认删除对象"; delete_dialog.ok_button_text = "删除"; delete_dialog.cancel_button_text = "取消"
	delete_dialog.confirmed.connect(func():
		if app.selected == delete_id: app._delete()
		else: app.last_message = "选择已改变，未执行删除")
	context_menu = PopupMenu.new(); root.add_child(context_menu)
	context_menu.add_item("前往此处", 0)
	context_menu.add_item("在此建造方块", 1)
	context_menu.add_item("在此放置当前模型", 2)
	context_menu.add_separator()
	context_menu.add_item("聚焦此处", 3)
	context_menu.add_item("选择此对象", 4)
	context_menu.add_item("打开门 / 灯", 5)
	context_menu.id_pressed.connect(app._context_action)
	app.get_viewport().size_changed.connect(layout)
	help_open = app.get_viewport().get_visible_rect().size.x >= 1120
	layout()

func layout() -> void:
	app._sync_web_scale()
	var size: Vector2 = app.get_viewport().get_visible_rect().size
	if app.walking: help_open = false
	var compact := size.x < 1020
	header.position = Vector2(16, 12); header.size = Vector2(minf(300, size.x - 32), 64)
	action_bar.position = Vector2(16, 84) if compact else Vector2(size.x - 566, 12)
	action_bar.size = Vector2(minf(size.x - 32, 550), 64)
	action_bar.visible = not app.walking
	return_button.position = Vector2(size.x - 188, 20)
	return_button.size = Vector2(170, 48)
	return_button.visible = app.walking
	var dock_top := 160 if compact else 92
	var dock_width := minf(400, size.x - 32)
	dock.position = Vector2(size.x - dock_width - 16, dock_top)
	dock.size = Vector2(dock_width, maxf(200, size.y - dock_top - 82))
	welcome.position = Vector2(16, dock_top if compact else 92); welcome.size = Vector2(minf(330, size.x - 32), 0)
	var footer_width := minf(size.x - 40, 920) if app.walking else size.x - 40
	footer.position = Vector2((size.x - footer_width) * 0.5, size.y - 72)
	footer.size = Vector2(footer_width, 58)
	dock.visible = tools_open and not app.walking
	welcome.visible = help_open and not app.walking and (size.x >= 1120 or not tools_open)
	tools_button.visible = not app.walking; help_button.visible = not app.walking
	tools_button.text = "收起面板" if tools_open else "显示面板"
	help_button.text = "关闭指南" if welcome.visible else "指南"
	crosshair.position = size * 0.5 - Vector2(7, 16); crosshair.visible = app.walking
	interaction_panel.position = Vector2((size.x - 300) * 0.5, size.y - 158)
	interaction_panel.size = Vector2(300, 46)

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

func show_context_menu(point: Vector2, walkable: bool, has_object: bool, has_asset: bool, can_toggle: bool, active: bool) -> void:
	var editable: bool = app.interactive and app.connection.welcome.get("role", "") != "observer" and app.connection.pending.is_empty()
	context_menu.set_item_disabled(context_menu.get_item_index(0), not walkable)
	context_menu.set_item_disabled(context_menu.get_item_index(1), not walkable or not editable)
	context_menu.set_item_disabled(context_menu.get_item_index(2), not walkable or not editable or not has_asset)
	context_menu.set_item_disabled(context_menu.get_item_index(4), not has_object)
	context_menu.set_item_text(context_menu.get_item_index(5), "关闭门 / 灯" if active else "打开门 / 灯")
	context_menu.set_item_disabled(context_menu.get_item_index(5), not can_toggle or not editable)
	var screen := app.get_window().position + Vector2i(point)
	context_menu.popup(Rect2i(screen, Vector2i(240, 0)))

func update() -> void:
	var online: bool = app.connection.online()
	var state: Dictionary = app.connection.local.snapshot()
	_sync_environment(state.get("meta", {}).get("environment", {}))
	source_credit.visible = false
	var credits := {}
	for asset in state.get("assets", {}).values():
		if asset.get("kind", "") == "mesh":
			credits[str(asset.get("attribution", ""))] = str(asset.get("license", ""))
	if not credits.is_empty():
		var credit: String = str(credits.keys()[0])
		var credit_lines := PackedStringArray()
		for entry in credits: credit_lines.append(str(entry) + " · " + str(credits[entry]))
		source_credit.visible = true
		source_credit.text = ("© City of Helsinki" if "City of Helsinki" in credit else "来源与许可") if credits.size() == 1 else "来源与许可（%d）" % credits.size()
		source_credit.tooltip_text = "\n".join(credit_lines)
		source_credit_url = ("https://docs.3dbag.nl/en/copyright/" if "3DBAG" in credit else ("https://www.hel.fi/en/decision-making/information-on-helsinki/maps-and-geospatial-data/helsinki-3d" if "City of Helsinki" in credit else "")) if credits.size() == 1 else ""
	region_label.text = str(state.get("meta", {}).get("region", {}).get("name", "共享三维世界")) if online else "共享三维世界"
	var editable: bool = app.interactive and app.connection.welcome.get("role", "") != "observer"
	var owner_editable: bool = editable and state.get("meta", {}).get("region", {}).get("owner_id", "") == app.connection.welcome.get("actor_id", "")
	var objects: Dictionary = state.get("objects", {})
	var item: Dictionary = objects.get(app.selected, {})
	var chosen := not item.is_empty()
	var pending: bool = not app.connection.pending.is_empty()
	var object_editable: bool = editable and chosen and item.get("owner_id", "") == app.connection.welcome.get("actor_id", "")
	badge.text = ("正在飞行" if app.flying else "正在漫游") if app.walking else ("已连接 · 可探索" if app.interactive else ("场景加载中" if online else "未连接"))
	badge.add_theme_color_override("font_color", ACCENT if app.interactive else Color("efc680"))
	walk_button.text = "返回编辑  ·  Esc" if app.walking else "漫游  ·  Tab"
	walk_button.disabled = not app.interactive
	return_button.disabled = not app.interactive
	guide_start_button.disabled = not app.interactive
	walk_button.tooltip_text = "等待连接和场景资源就绪" if not app.interactive else "WASD 移动，Shift 快跑，F 飞行，E 使用附近的门或灯"
	create_button.disabled = not editable or pending; preview_box_button.disabled = not editable or pending
	cancel_place_button.disabled = not app.placing and not app.moving
	import_button.disabled = not editable
	expand_button.disabled = not owner_editable or pending or float(state.get("meta", {}).get("region", {}).get("size", [256.0])[0]) >= 512
	terrain_apply_button.disabled = not owner_editable or pending
	environment_apply_button.disabled = not owner_editable or pending or not environment_dirty
	for value in terrain_fields.values(): value.editable = owner_editable and not pending
	for value in environment_fields.values(): value.editable = owner_editable and not pending
	terrain_mode.disabled = not owner_editable or pending
	water_enabled.disabled = not owner_editable or pending
	terrain_grid.disabled = not owner_editable or pending
	send_button.disabled = not editable or pending
	upload_button.disabled = not editable or pending or app._upload_bytes.is_empty() or upload_name.text.strip_edges().is_empty() or upload_license.text.strip_edges().is_empty() or upload_source.text.strip_edges().is_empty()
	place_button.disabled = not editable or pending or asset_ids.is_empty()
	preview_asset_button.disabled = not editable or pending or asset_ids.is_empty()
	library_add_button.disabled = not online or asset_ids.is_empty()
	library_refresh_button.disabled = not online
	var library_selection := library_list.get_selected_items()
	var library_ready := not library_selection.is_empty() and library_selection[0] < library_item_ids.size()
	if library_ready:
		var library_entry: Dictionary = app.inventory_items.get(str(library_item_ids[library_selection[0]]), {})
		library_ready = library_entry.get("bounds") is Array and not library_entry.has("asset_error")
	library_place_button.disabled = not editable or pending or not library_ready
	focus_button.disabled = not chosen
	move_button.disabled = not object_editable or pending or not item.get("group_id", "").is_empty()
	for control in [rotate_left_button, rotate_right_button, scale_down_button, scale_up_button]: control.disabled = not object_editable or pending or not item.get("group_id", "").is_empty()
	group_button.disabled = not editable or pending or app.selected_ids.size() < 2
	ungroup_button.disabled = not object_editable or pending or item.get("group_id", "").is_empty()
	apply_button.disabled = not object_editable or not app.draft_dirty or pending
	reset_button.disabled = not chosen or not app.draft_dirty or pending
	delete_button.disabled = not object_editable or pending or not item.get("group_id", "").is_empty()
	delete_button.tooltip_text = "组合成员需先解除组合，或通过高级命令删除整个组合" if not item.get("group_id", "").is_empty() else "删除前需要确认"
	toggle_button.disabled = not object_editable or not item.get("state", {}).has("active") or pending
	review_focus_button.disabled = app.review_selected_id.is_empty() or not online
	review_save_button.disabled = app.review_selected_id.is_empty() or not online
	review_export_button.disabled = app.review_records.is_empty()
	app.name_field.editable = object_editable and not pending
	for value in app.coordinates: value.editable = object_editable and not pending
	selection_title.text = str(item.get("name", "尚未选择对象"))
	selection_note.text = "在场景或对象列表中选择一个对象。" if not chosen else ("有未提交的修改" if app.draft_dirty else ("组合成员 · 当前显示世界坐标" if not item.get("group_id", "").is_empty() else "独立对象 · 可修改名称与位置"))
	if chosen and app.connection.welcome.get("role", "") == "observer": selection_note.text = "只读会话 · 可以查看和漫游"
	connect_button.disabled = app.connection.status == "Connecting"
	disconnect_button.disabled = app.connection.peer == null
	hint.text = ("WASD 飞行  ·  空格上升  ·  Ctrl 下降  ·  F 落地" if app.flying else "WASD 移动  ·  Shift 快跑  ·  F 飞行  ·  E 使用") if app.walking else ("移动鼠标预览  ·  点击确认  ·  Esc 取消" if app.placing or app.moving else ("已选「%s」  ·  G 移动  ·  F 定位" % str(item.get("name", "")) if chosen else "双击前往  ·  右键菜单  ·  中键平移  ·  滚轮缩放"))
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

func refresh_inventory(data: Dictionary) -> void:
	if not data.get("items") is Array: return
	library_items = data.items.duplicate(true)
	_render_inventory()

func clear_inventory() -> void:
	library_items.clear(); library_item_ids.clear(); library_list.clear()
	library_info.text = "连接后刷新素材库，选择素材可查看来源与许可。"

func _render_inventory() -> void:
	var selected_id := ""
	if library_list.get_selected_items().size() > 0:
		var old_index: int = library_list.get_selected_items()[0]
		if old_index < library_item_ids.size(): selected_id = str(library_item_ids[old_index])
	library_list.clear(); library_item_ids.clear()
	var query := library_search.text.strip_edges().to_lower()
	var ordered: Array = library_items.duplicate(true)
	ordered.sort_custom(func(a, b): return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0)
	for item in ordered:
		if not query.is_empty() and not str(item.get("name", "")).to_lower().contains(query): continue
		library_item_ids.append(str(item.id))
		library_list.add_item(str(item.name))
		if item.id == selected_id: library_list.select(library_item_ids.size() - 1)
	if library_item_ids.is_empty(): library_list.add_item("没有匹配的个人素材" if not query.is_empty() else "素材库为空")
	_selected_inventory()

func _selected_inventory() -> void:
	var chosen := library_list.get_selected_items()
	if chosen.is_empty() or chosen[0] >= library_item_ids.size():
		library_info.text = "选择素材可查看来源与许可。"
		return
	var id: String = library_item_ids[chosen[0]]
	for item in library_items:
		if str(item.id) == id:
			library_info.text = "%s\n许可：%s\n来源：%s" % [str(item.name), str(item.get("license", "未填写")), str(item.get("attribution", "未填写"))]
			if item.has("asset_error"): library_info.text += "\n素材不可用：" + str(item.asset_error)
			return

func _place_inventory() -> void:
	var chosen := library_list.get_selected_items()
	if chosen.is_empty() or chosen[0] >= library_item_ids.size():
		app.last_message = "请先选择一件个人素材"
		return
	app._place_inventory_item(library_item_ids[chosen[0]])

func observation() -> Dictionary:
	var rect := walk_button.get_global_rect()
	var viewport: Vector2 = app.get_viewport().get_visible_rect().size
	return {"walk_button": [rect.position.x, rect.position.y, rect.size.x, rect.size.y], "viewport": [viewport.x, viewport.y], "tools_visible": dock.visible}
