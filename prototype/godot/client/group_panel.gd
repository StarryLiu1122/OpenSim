extends VBoxContainer
signal command_requested(operation: String, payload: Dictionary)
const Schema = preload("res://domain/world_schema.gd")
const T = preload("res://domain/world_transforms.gd")
var title := Label.new()
var name_input := LineEdit.new()
var fields: Dictionary = {}
var buttons: Dictionary = {}
var frame: Dictionary = {}
var _yaw := 0.0
var _displayed: Dictionary = {}

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 9)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(title)
	name_input.max_length = 80
	add_child(name_input)
	_label("组坐标 / 米 · X 东、Y 北、Z 高")
	_vector("position", -100, 600, [0, 0, 0])
	_label("水平旋转 / 度")
	_spin("yaw", -180, 180, 1, 0, self)
	_label("统一缩放倍率")
	_spin("scale", 0.1, 10, 0.05, 1, self)
	_button("应用组合变换", "update", _apply)
	_label("副本偏移 / 米 · X、Y、Z")
	_vector("offset", -256, 256, [24, 0, 0])
	_button("复制整个组合", "duplicate", func(): command_requested.emit("DuplicateGroup", {"id": frame.id, "offset": _values("offset")}))
	_button("解除组合", "ungroup", func(): command_requested.emit("UngroupObjects", {"id": frame.id}))
	_button("删除整个组合", "delete", func(): command_requested.emit("DeleteGroup", {"id": frame.id}))
	_label("在左侧按 Ctrl 多选部件，点击「组合」。\n当前对象成为根部件；组合变换统一作用于所有成员。根部件的位置和旋转请在此编辑。")

func _label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 12)
	add_child(label)

func _spin(key: String, low: float, high: float, step: float, value: float, parent: Node) -> void:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = Vector2(72, 34)
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spin)
	fields[key] = spin

func _vector(key: String, low: float, high: float, values: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	add_child(row)
	for i in range(3):
		_spin(key + str(i), low, high, 0.01, values[i], row)

func _button(text: String, key: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 36
	button.pressed.connect(callback)
	add_child(button)
	buttons[key] = button

func _values(key: String) -> Array:
	var result: Array = []
	for i in range(3):
		fields[key + str(i)].apply()
		result.append(fields[key + str(i)].value)
	return result

func show_group(world: Dictionary, item: Dictionary, selection_count: int) -> void:
	frame = T.group(world, item.get("group_id", "")).duplicate(true)
	var enabled := not frame.is_empty()
	for button in buttons.values():
		button.disabled = not enabled
	for spin in fields.values():
		spin.editable = enabled
	name_input.editable = enabled
	title.text = "已选择 %d 个部件\n尚未选择组合成员" % selection_count
	name_input.text = ""
	if not enabled:
		return
	var count := 0
	for member in world.objects:
		if member.group_id == frame.id:
			count += 1
	title.text = "%s · %d 个部件" % [frame.name, count]
	name_input.text = frame.name
	for i in range(3):
		fields["position" + str(i)].set_value_no_signal(frame.position[i])
		_displayed["position" + str(i)] = fields["position" + str(i)].value
	_yaw = rad_to_deg(T.quat(frame.rotation).get_euler().z)
	fields.yaw.set_value_no_signal(_yaw)
	fields.scale.set_value_no_signal(frame.scale)
	_displayed.scale = fields.scale.value

func _apply() -> void:
	fields.yaw.apply()
	fields.scale.apply()
	var rotation: Array = frame.rotation.duplicate()
	if not is_equal_approx(fields.yaw.value, _yaw):
		rotation = T.rotation(Quaternion(Vector3(0, 0, 1), deg_to_rad(fields.yaw.value)))
	var position := _values("position")
	for i in range(3):
		if is_equal_approx(position[i], _displayed["position" + str(i)]):
			position[i] = frame.position[i]
	var scale_value: float = frame.scale if is_equal_approx(fields.scale.value, _displayed.scale) else fields.scale.value
	command_requested.emit("UpdateGroup", {"id": frame.id, "patch": {"name": name_input.text.strip_edges(), "position": position, "rotation": rotation, "scale": scale_value}})
