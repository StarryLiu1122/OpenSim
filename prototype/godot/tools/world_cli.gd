extends SceneTree
## Offline automation adapter: fixed operations, JSON data only, never generated script eval.
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var options: Dictionary = {}
	for arg in OS.get_cmdline_user_args():
		var pair: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2:
			options[pair[0]] = pair[1]
	if not options.has_all(["world-file", "commands", "output"]):
		_finish({"ok": false, "error": "Required: --world-file=... --commands=... --output=..."}, "", 1)
		return
	var input_path := ProjectSettings.globalize_path(options.commands).simplify_path()
	var output_path := ProjectSettings.globalize_path(options.output).simplify_path()
	var world_path := ProjectSettings.globalize_path(options["world-file"]).simplify_path()
	var compare_output := output_path.to_lower() if OS.get_name() == "Windows" else output_path
	var protected_paths: Array = []
	for protected_path in [input_path, world_path, world_path + ".bak", world_path + ".tmp", world_path + ".bak.tmp"]:
		protected_paths.append(protected_path.to_lower() if OS.get_name() == "Windows" else protected_path)
	if compare_output in protected_paths:
		_finish({"ok": false, "error": "Output report must not replace input or snapshot files."}, "", 1)
		return
	var file := FileAccess.open(input_path, FileAccess.READ)
	if file == null or file.get_length() > 1024 * 1024:
		_finish({"ok": false, "error": "Cannot read commands or file exceeds 1 MiB."}, output_path, 1)
		return
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Array or parser.data.is_empty() or parser.data.size() > 100:
		_finish({"ok": false, "error": "Commands must be a JSON array with 1–100 entries."}, output_path, 1)
		return
	for command in parser.data:
		if not command is Dictionary or not Schema.exact_keys(command, ["operation", "payload"]) or not command.operation is String or not command.payload is Dictionary:
			_finish({"ok": false, "error": "Invalid command descriptor."}, output_path, 1)
			return
	var service = Service.new(world_path)
	if service.repository.exists():
		var loaded: Dictionary = service.request("LoadRegion")
		if not loaded.ok:
			_finish({"ok": false, "results": [loaded]}, output_path, 1)
			return
	var results: Array = []
	for command in parser.data:
		var result: Dictionary = service.request(command.operation, command.payload)
		results.append(result)
		if not result.ok:
			_finish({"ok": false, "results": results}, output_path, 1)
			return
	_finish({"ok": true, "results": results}, output_path, 0)

func _finish(report: Dictionary, path: String, exit_code: int) -> void:
	if not path.is_empty():
		var directory_error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE) if directory_error == OK else null
		if file == null:
			print(JSON.stringify({"ok": false, "error": "Cannot write output report."}))
			quit(1)
			return
		file.store_string(JSON.stringify(report, "\t", true, true) + "\n")
		file.flush()
		if file.get_error() != OK:
			quit(1)
			return
		file.close()
	print(JSON.stringify({"ok": report.ok, "operation": "WorldBatch", "report": path}))
	quit(exit_code)
