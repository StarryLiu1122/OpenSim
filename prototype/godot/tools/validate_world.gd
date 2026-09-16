extends SceneTree
## Trusted storage tool entry point. Input is data; the only schema authority is
## the same GDScript validator used by WorldService and the native test suite.
const Schema = preload("res://domain/world_schema.gd")
const Snapshot = preload("res://adapters/snapshot_repository.gd")

func _initialize() -> void:
	var options: Dictionary = {}
	for argument in OS.get_cmdline_user_args():
		var pair := argument.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2: options[pair[0]] = pair[1]
	if not options.has_all(["input", "output"]) or options.input == options.output: quit(2); return
	var result: Dictionary
	var file := FileAccess.open(options.input, FileAccess.READ)
	if file == null or file.get_length() > Schema.MAX_FILE_BYTES:
		result = {"error": "World input missing or exceeds 8 MiB."}
	else:
		var parser := JSON.new()
		if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
			result = {"error": "Invalid world JSON."}
		elif parser.data.get("format") == "region-lab.snapshot":
			result = Snapshot.new(options.input)._read(options.input)
		else:
			result = Schema.upgrade(parser.data)
	var out := FileAccess.open(options.output, FileAccess.WRITE)
	if out == null: quit(2); return
	out.store_string(JSON.stringify(result, "", true, true)); out.flush(); out.close()
	quit(1 if result.has("error") else 0)
