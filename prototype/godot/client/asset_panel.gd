extends VBoxContainer
signal command_requested(operation: String, payload: Dictionary)
var path_input := LineEdit.new()
var name_input := LineEdit.new()
var license_input := LineEdit.new()
var attribution_input := LineEdit.new()
var browse_button := Button.new()
var import_button := Button.new()
var remove_button := Button.new()
var info := Label.new()
var dialog := FileDialog.new()
var _asset_id := ""

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 9)
	_label("导入静态 GLB / glTF / OBJ")
	for pair in [["文件路径", path_input], ["资产名称", name_input], ["许可证或授权说明", license_input], ["来源与作者", attribution_input]]:
		_label(pair[0])
		pair[1].max_length = 160 if pair[1] != path_input else 2048
		add_child(pair[1])
	browse_button.text = "选择 GLB / glTF / OBJ 文件"
	add_child(browse_button)
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.glb, *.gltf, *.obj ; 静态 GLB、glTF 或 OBJ 模型"])
	add_child(dialog)
	browse_button.pressed.connect(func(): dialog.popup_centered_ratio(0.7))
	dialog.file_selected.connect(func(path: String):
		path_input.text = path
		if name_input.text.is_empty():
			name_input.text = path.get_file().get_basename())
	import_button.text = "导入资产"
	add_child(import_button)
	import_button.pressed.connect(func(): command_requested.emit("ImportGlb", {"path": path_input.text.strip_edges(), "name": name_input.text.strip_edges(), "license": license_input.text.strip_edges(), "attribution": attribution_input.text.strip_edges()}))
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 12)
	add_child(info)
	remove_button.text = "移除当前未使用资产"
	add_child(remove_button)
	remove_button.pressed.connect(func(): command_requested.emit("RemoveAsset", {"id": _asset_id}))
	_label("导入后在左侧资产列表选择模型并添加实例。\n打包后的 GLB 上限 2 MiB、20,000 三角形；支持 PNG/JPEG 贴图。\nglTF 的外部文件及 OBJ 的 MTL/贴图须与模型放在同一目录。文件内容随世界保存。")

func _label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 12)
	add_child(label)

func show_asset(world: Dictionary, id: String) -> void:
	_asset_id = id
	remove_button.disabled = true
	info.text = "请选择已导入的资产。"
	for asset in world.assets:
		if asset.id != id or asset.kind != "mesh":
			continue
		var count := 0
		for item in world.objects:
			if item.asset_id == id:
				count += 1
		info.text = "%s · %d 个实例\n许可：%s\n来源：%s" % [asset.name, count, asset.license, asset.attribution]
		remove_button.disabled = count > 0
