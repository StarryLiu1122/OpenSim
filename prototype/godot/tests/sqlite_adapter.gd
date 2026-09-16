extends SceneTree
const Service = preload("res://domain/world_service.gd")
const Schema = preload("res://domain/world_schema.gd")
const Repository = preload("res://adapters/sqlite_repository.gd")
const Demo = preload("res://domain/demo_region.gd")
var checks: Array = []

func check(value: bool, name: String) -> void:
	checks.append({"name": name, "passed": value}); print("SQLITE_ADAPTER ", value, " ", name)

func _initialize() -> void:
	var options: Dictionary = {}
	for argument in OS.get_cmdline_user_args():
		var pair := argument.trim_prefix("--").split("=", true, 1)
		if pair.size() == 2: options[pair[0]] = pair[1]
	if not options.has_all(["directory", "store"]): quit(2); return
	var path: String = options.directory
	if DirAccess.dir_exists_absolute(path): quit(2); return
	var first = Service.new("", Repository.new(path, options.store))
	check(not first.repository.exists(), "new database repository is empty")
	check(first.repository._invoke({"operation": "init"}).get("ok", false), "empty database initializes through the executable adapter")
	check(not first.repository.exists(), "initialized database without this region is still a fresh world")
	check(first.model.replace(Demo.create()).is_empty(), "domain validates initial grouped demonstration")
	var saved: Dictionary = first.request("SaveRegion")
	check(saved.ok and not first.dirty, "WorldService confirms SQLite commit before clearing dirty state")
	if not saved.ok: _finish(path); return
	var second = Service.new("", Repository.new(path, options.store))
	check(second.request("LoadRegion").ok and second.model.snapshot().groups.size() == 1, "second service loads grouped world through repository contract")
	var id: String = second.model.snapshot().objects[0].id
	check(second.request("UpdateObject", {"id": id, "patch": {"name": "SQLite owner update"}}).ok and second.request("SaveRegion").ok, "existing editor command persists through SQLite adapter")
	check(first.request("UpdateEnvironment", {"patch": {"sun_hour": 20}}).ok, "stale client retains a legitimate unsaved edit")
	check(not first.request("SaveRegion").ok and first.dirty, "stale storage token refuses overwrite and retains dirty state")
	check(first.request("LoadRegion").ok and first.model.object(id).name == "SQLite owner update", "explicit reload resolves storage conflict")
	check(first.request("UpdateEnvironment", {"patch": {"sun_hour": 20}}).ok and first.request("SaveRegion").ok, "new edit can commit after reload")
	var final_reader = Service.new("", Repository.new(path, options.store))
	check(final_reader.request("LoadRegion").ok and final_reader.model.snapshot().environment.sun_hour == 20, "third repository instance restores committed environment")
	_finish(path)

func _finish(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)
	var passed := checks.all(func(c: Dictionary) -> bool: return c.passed)
	var file := FileAccess.open(path + "/adapter-report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed": passed, "checks": checks}, "  ") + "\n"); file.close()
	quit(0 if passed else 1)
