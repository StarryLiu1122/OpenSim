extends CanvasLayer
signal action_requested(action: String)
signal object_selected(id: String)
signal patch_requested(patch: Dictionary)

const INK := Color("eef4f0")
const MUTED := Color("9cb3bb")
const ACCENT := Color("bee8ce")
const TerrainPanel = preload("res://client/terrain_panel.gd")
var inspector_tabs: TabContainer
var terrain_panel
var root: Control
var list: ItemList
var status: Label
var footer: Label
var count_label: Label
var selection_label: Label
var selection_id: Label
var name_input: LineEdit
var color_input: ColorPickerButton
var fields: Dictionary = {}
var buttons: Dictionary = {}
var mode_button: Button
var _ids: Array[String] = []
var _selected := ""
var _rotation: Array = [0.0, 0.0, 0.0, 1.0]
var _original_yaw := 0.0
var _original_item: Dictionary = {}
var _displayed: Dictionary = {}
var _inspector: VBoxContainer

func _ready() -> void:
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.theme = _theme()
	_build_header()
	_build_list()
	_build_inspector()
	_build_footer()

func _theme() -> Theme:
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Arial"])
	theme.default_font = font
	theme.default_font_size = 14
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", ACCENT)
	theme.set_color("font_disabled_color", "Button", Color("67818b"))
	theme.set_stylebox("normal", "Button", _style(Color("263f48")))
	theme.set_stylebox("hover", "Button", _style(Color("35525b")))
	theme.set_stylebox("pressed", "Button", _style(Color("426570")))
	theme.set_stylebox("disabled", "Button", _style(Color("20343c")))
	theme.set_stylebox("normal", "LineEdit", _style(Color("233c45")))
	theme.set_stylebox("focus", "LineEdit", _style(Color("294850"), Color("80bda4")))
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("caret_color", "LineEdit", ACCENT)
	theme.set_stylebox("panel", "ItemList", _style(Color("172e37")))
	theme.set_stylebox("selected", "ItemList", _style(Color("33564e")))
	theme.set_stylebox("selected_focus", "ItemList", _style(Color("33564e")))
	theme.set_color("font_color", "ItemList", INK)
	theme.set_color("font_selected_color", "ItemList", ACCENT)
	theme.set_constant("v_separation", "ItemList", 14)
	theme.set_constant("separation", "VBoxContainer", 12)
	theme.set_constant("separation", "HBoxContainer", 10)
	return theme

func _style(color: Color, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(7)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 9
	style.content_margin_bottom = 9
	if border.a > 0:
		style.set_border_width_all(1)
		style.border_color = border
	return style

func _panel(rect: Rect2, anchors: Vector4 = Vector4.ZERO) -> PanelContainer:
	var panel := PanelContainer.new()
	root.add_child(panel)
	panel.anchor_left = anchors.x
	panel.anchor_top = anchors.y
	panel.anchor_right = anchors.z
	panel.anchor_bottom = anchors.w
	if anchors.x == 1:
		panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = rect.position.x
	panel.offset_top = rect.position.y
	panel.offset_right = rect.position.x + rect.size.x
	panel.offset_bottom = rect.position.y + rect.size.y
	var style := _style(Color("172e37"), Color("34505a"))
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	return panel

func _label(text: String, size: int = 14, color: Color = INK) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label

func _button(text: String, action: String, accent: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 38
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func(): action_requested.emit(action))
	if accent:
		button.add_theme_stylebox_override("normal", _style(ACCENT))
		button.add_theme_stylebox_override("hover", _style(Color("d6f5df")))
		button.add_theme_stylebox_override("pressed", _style(Color("9bd2b2")))
		button.add_theme_color_override("font_color", Color("19352e"))
		button.add_theme_color_override("font_hover_color", Color("19352e"))
		button.add_theme_color_override("font_pressed_color", Color("19352e"))
	buttons[action] = button
	return button

func _build_header() -> void:
	var bar := _panel(Rect2(16, 14, -32, 66), Vector4(0, 0, 1, 0))
	var row := HBoxContainer.new()
	bar.add_child(row)
	row.add_child(_label("◈  REGION LAB", 23, ACCENT))
	row.add_child(_label("  /  青屿实验区", 17))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	status = _label("●  尚未保存", 13, Color("f0cb88"))
	row.add_child(status)
	row.add_child(_button("操作指南", "help"))
	row.add_child(_button("恢复存档", "load"))
	row.add_child(_button("保存世界  Ctrl+S", "save", true))

func _build_list() -> void:
	var panel := _panel(Rect2(16, 94, 246, -174), Vector4(0, 0, 0, 1))
	var column := VBoxContainer.new()
	panel.add_child(column)
	column.add_child(_label("场景对象", 19))
	count_label = _label("", 12, MUTED)
	column.add_child(count_label)
	column.add_child(_button("＋  添加立方体", "create", true))
	column.add_child(_button("地形编辑", "terrain_mode"))
	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size.y = 160
	list.fixed_icon_size = Vector2i(12, 12)
	list.allow_reselect = true
	list.item_selected.connect(func(index: int): object_selected.emit(_ids[index]))
	list.item_activated.connect(func(_index: int): action_requested.emit("focus"))
	column.add_child(list)
	var row := HBoxContainer.new()
	row.add_child(_button("复制", "duplicate"))
	row.add_child(_button("删除", "delete"))
	column.add_child(row)
	column.add_child(_label("点击对象或列表进行选择\n双击列表 · 聚焦对象", 12, MUTED))

func _build_inspector() -> void:
	var panel := _panel(Rect2(-366, 94, 350, -174), Vector4(1, 0, 1, 1))
	inspector_tabs = TabContainer.new()
	inspector_tabs.add_theme_stylebox_override("panel", _style(Color("172e37")))
	panel.add_child(inspector_tabs)
	var scroll := ScrollContainer.new()
	scroll.name = "对象"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inspector_tabs.add_child(scroll)
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_inspector)
	_inspector.add_child(_label("对象属性", 19))
	selection_label = _label("请选择一个对象", 13, MUTED)
	_inspector.add_child(selection_label)
	name_input = LineEdit.new()
	name_input.placeholder_text = "对象名称"
	name_input.max_length = 80
	_inspector.add_child(name_input)
	_inspector.add_child(_label("位置 / 米", 13, ACCENT))
	_vector_fields("position", [-40.0, 256.0], ["X · 东", "Y · 北", "Z · 高"])
	_inspector.add_child(_label("尺寸 / 米", 13, ACCENT))
	_vector_fields("size", [0.2, 32.0], ["宽 X", "深 Y", "高 Z"])
	_inspector.add_child(_label("水平旋转 / 度", 13, ACCENT))
	var yaw := _spin(-180, 180, 5)
	fields["yaw"] = yaw
	_inspector.add_child(yaw)
	_inspector.add_child(_label("表面颜色", 13, ACCENT))
	color_input = ColorPickerButton.new()
	color_input.custom_minimum_size.y = 32
	color_input.edit_alpha = false
	_inspector.add_child(color_input)
	var swatches := HBoxContainer.new()
	for hex in ["#50A696", "#E9B45D", "#758FAD", "#F0EADC", "#BE7E70"]:
		var button := Button.new()
		button.custom_minimum_size = Vector2(37, 26)
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_stylebox_override("normal", _style(Color(hex)))
		button.add_theme_stylebox_override("hover", _style(Color(hex).lightened(0.18)))
		button.pressed.connect(func(): color_input.color = Color(hex))
		swatches.add_child(button)
	_inspector.add_child(swatches)
	var apply := _button("应用修改", "apply", true)
	apply.pressed.connect(_apply)
	_inspector.add_child(apply)
	_inspector.add_child(_button("放到地面", "ground"))
	selection_id = _label("", 10, MUTED)
	selection_id.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_inspector.add_child(selection_id)
	var terrain_scroll := ScrollContainer.new()
	terrain_scroll.name = "地形"
	terrain_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inspector_tabs.add_child(terrain_scroll)
	terrain_panel = TerrainPanel.new()
	terrain_scroll.add_child(terrain_panel)

func _vector_fields(key: String, limits: Array, names: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for i in range(3):
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 4)
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(_label(names[i], 11, MUTED))
		var spin := _spin(limits[0], limits[1], 0.01)
		spin.custom_minimum_size.x = 72
		column.add_child(spin)
		fields[key + str(i)] = spin
		row.add_child(column)
	_inspector.add_child(row)

func _spin(minimum: float, maximum: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.custom_minimum_size.y = 34
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_LEFT
	return spin

func _build_footer() -> void:
	var tools := _panel(Rect2(-265, -88, 530, 74), Vector4(0.5, 1, 0.5, 1))
	var row := HBoxContainer.new()
	tools.add_child(row)
	mode_button = _button("进入漫游  Tab", "walk")
	row.add_child(mode_button)
	row.add_child(_button("聚焦  F", "focus"))
	row.add_child(_button("撤销  Ctrl+Z", "undo"))
	row.add_child(_button("重做", "redo"))
	footer = _label("256 × 256 m  ·  编辑模式", 12, Color("183f35"))
	root.add_child(footer)
	footer.anchor_top = 1
	footer.anchor_bottom = 1
	footer.offset_left = 20
	footer.offset_top = -53
	footer.offset_bottom = -19
	var hint := _label("右键旋转  ·  中键平移  ·  滚轮缩放", 12, Color("183f35"))
	root.add_child(hint)
	hint.anchor_left = 1
	hint.anchor_right = 1
	hint.anchor_top = 1
	hint.anchor_bottom = 1
	hint.offset_left = -302
	hint.offset_top = -52
	hint.offset_right = -18
	hint.offset_bottom = -18

func show_world(world: Dictionary, id: String) -> void:
	_selected = id
	_ids.clear()
	list.clear()
	count_label.text = "%d 个对象  ·  256 × 256 米" % world.objects.size()
	var item: Dictionary = {}
	for obj in world.objects:
		_ids.append(obj.id)
		list.add_item(obj.name)
		list.set_item_tooltip(list.item_count - 1, obj.id)
		if obj.id == id:
			item = obj
			list.select(list.item_count - 1)
	var enabled := not item.is_empty()
	for key in ["duplicate", "delete", "apply", "ground"]:
		buttons[key].disabled = not enabled
	name_input.editable = enabled
	for field in fields.values():
		field.editable = enabled
	color_input.disabled = not enabled
	selection_label.text = "立方体 · 可编辑" if enabled else "请选择一个对象"
	selection_id.text = "对象 ID\n" + id if enabled else "从左侧添加对象，或在场景中点击选择。"
	if not enabled:
		name_input.text = ""
		return
	name_input.text = item.name
	_original_item = item.duplicate(true)
	for i in range(3):
		fields["position" + str(i)].set_value_no_signal(item.position[i])
		fields["size" + str(i)].set_value_no_signal(item.size[i])
		_displayed["position" + str(i)] = fields["position" + str(i)].value
		_displayed["size" + str(i)] = fields["size" + str(i)].value
	_rotation = item.rotation.duplicate()
	_original_yaw = rad_to_deg(Quaternion(_rotation[0], _rotation[1], _rotation[2], _rotation[3]).get_euler().z)
	fields.yaw.set_value_no_signal(_original_yaw)
	color_input.color = Color(item.color)

func _apply() -> void:
	if _selected.is_empty():
		return
	# Commit any text still being edited before reading SpinBox values.
	for field in fields.values():
		field.apply()
	var rotation := _rotation.duplicate()
	if not is_equal_approx(fields.yaw.value, _original_yaw):
		var quaternion := Quaternion(Vector3(0, 0, 1), deg_to_rad(fields.yaw.value))
		rotation = [quaternion.x, quaternion.y, quaternion.z, quaternion.w]
	var position: Array = _original_item.position.duplicate()
	var dimensions: Array = _original_item.size.duplicate()
	for i in range(3):
		if not is_equal_approx(fields["position" + str(i)].value, _displayed["position" + str(i)]):
			position[i] = fields["position" + str(i)].value
		if not is_equal_approx(fields["size" + str(i)].value, _displayed["size" + str(i)]):
			dimensions[i] = fields["size" + str(i)].value
	patch_requested.emit({"name": name_input.text.strip_edges(), "position": position, "size": dimensions, "rotation": rotation, "color": "#" + color_input.color.to_html(false).to_upper()})

func set_status(text: String, warning: bool = false) -> void:
	status.text = text
	status.add_theme_color_override("font_color", Color("f0cb88") if warning else ACCENT)

func set_walk(active: bool) -> void:
	mode_button.text = "返回编辑  Esc" if active else "进入漫游  Tab"
	footer.text = "WASD 移动 · 空格跳跃 · Shift 加速" if active else "256 × 256 m  ·  编辑模式"
	terrain_panel.apply_button.disabled = active

func set_history(state: Dictionary) -> void:
	buttons.undo.disabled = state.undo == 0
	buttons.redo.disabled = state.redo == 0

func typing() -> bool:
	var focus := root.get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit
