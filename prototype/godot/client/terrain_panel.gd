extends VBoxContainer
signal apply_requested(payload: Dictionary)

const MODES := ["raise", "lower", "flatten", "smooth"]
var mode: OptionButton
var fields: Dictionary = {}
var apply_button: Button
var sample_label: Label

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = "地形编辑"
	title.add_theme_font_size_override("font_size", 19)
	add_child(title)
	mode = OptionButton.new()
	for label in ["抬升", "降低", "设高", "平滑"]:
		mode.add_item(label)
	mode.custom_minimum_size.y = 38
	mode.item_selected.connect(func(_index: int): _update_mode())
	add_child(mode)
	var center_row := HBoxContainer.new()
	add_child(center_row)
	_add_number(center_row, "east", "中心 X / 米", 0, 256, 0.25, 116)
	_add_number(center_row, "north", "中心 Y / 米", 0, 256, 0.25, 140)
	_add_number(self, "radius", "笔刷半径 / 米", 4, 32, 1, 12)
	_add_number(self, "strength", "笔刷强度 / %", 5, 100, 5, 50)
	_add_number(self, "height", "目标高程 / 米（设高）", -40, 80, 0.1, 5)
	sample_label = Label.new()
	sample_label.add_theme_color_override("font_color", Color("bee8ce"))
	add_child(sample_label)
	apply_button = Button.new()
	apply_button.text = "应用笔刷"
	apply_button.custom_minimum_size.y = 40
	apply_button.focus_mode = Control.FOCUS_NONE
	apply_button.pressed.connect(func(): apply_requested.emit(parameters()))
	add_child(apply_button)
	var note := Label.new()
	note.text = "左键点击地表：在该处应用一次笔刷。\n数值定位：输入中心坐标后应用。\n\n每次操作可撤销、重做。\n保存世界将同时保存地形和物体。\n\n地形改变后，物体保持原坐标。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", Color("9cb3bb"))
	note.add_theme_font_size_override("font_size", 12)
	add_child(note)
	_update_mode()

func _add_number(parent: Node, key: String, title: String, minimum: float, maximum: float, step: float, initial: float) -> void:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 4)
	parent.add_child(column)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 12)
	column.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = initial
	spin.custom_minimum_size = Vector2(100, 34)
	column.add_child(spin)
	fields[key] = spin

func _update_mode() -> void:
	fields.height.editable = mode.selected == 2

func parameters() -> Dictionary:
	for field in fields.values():
		field.apply()
	return {"mode": MODES[mode.selected], "center": [fields.east.value, fields.north.value], "radius": fields.radius.value, "strength": fields.strength.value / 100.0, "target_height": fields.height.value}

func set_center(center: Vector2) -> void:
	fields.east.set_value_no_signal(center.x)
	fields.north.set_value_no_signal(center.y)

func center() -> Vector2:
	return Vector2(fields.east.value, fields.north.value)

func show_height(value: float) -> void:
	sample_label.text = "中心地面高程：%.3f m" % value
