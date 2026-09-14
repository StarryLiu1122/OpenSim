extends VBoxContainer
signal apply_requested(patch: Dictionary)
var fields: Dictionary = {}
var water_enabled := CheckBox.new()
var terrain_grid := CheckBox.new()
var apply_button := Button.new()

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var heading := Label.new()
	heading.text = "区域环境"
	heading.add_theme_font_size_override("font_size", 19)
	add_child(heading)
	for entry in [["sun_hour", "太阳时刻 / 24 小时", 0, 24, 0.25], ["water_height", "水面高程 / 米", -40, 80, 0.1], ["fog_density", "雾密度 / 0–0.02", 0, 0.02, 0.0005]]:
		var label := Label.new()
		label.text = entry[1]
		add_child(label)
		var field := SpinBox.new()
		field.min_value = entry[2]
		field.max_value = entry[3]
		field.step = entry[4]
		field.custom_minimum_size.y = 36
		fields[entry[0]] = field
		add_child(field)
	water_enabled.text = "显示区域水面"
	terrain_grid.text = "显示地形测量网格"
	add_child(water_enabled)
	add_child(terrain_grid)
	apply_button.text = "应用环境设置"
	apply_button.custom_minimum_size.y = 40
	apply_button.focus_mode = Control.FOCUS_NONE
	apply_button.pressed.connect(func():
		for field in fields.values():
			field.apply()
		apply_requested.emit({"sun_hour": fields.sun_hour.value, "water_height": fields.water_height.value, "fog_density": fields.fog_density.value, "water_enabled": water_enabled.button_pressed, "terrain_grid": terrain_grid.button_pressed}))
	add_child(apply_button)
	var description := Label.new()
	description.text = "6 时日出，12 时正午，18 时日落。\n时刻固定，修改后随世界保存。\n\n水面用于景观显示，尚未模拟游泳、浮力和水流。"
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(description)

func show_environment(data: Dictionary) -> void:
	for key in fields:
		fields[key].set_value_no_signal(data[key])
	water_enabled.set_pressed_no_signal(data.water_enabled)
	terrain_grid.set_pressed_no_signal(data.terrain_grid)
