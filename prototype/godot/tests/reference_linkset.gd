extends SceneTree
## The same metre-space C01-C09 fixture as integration/opensim/Test-Linkset.ps1.
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
var service
var output := ""
var phase := ""
var checks: Array = []
var captures: Dictionary = {}
var failed := false

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks.append({"name": label, "ok": ok})
	if not ok:
		failed = true
		push_error(label)

func command(op: String, payload: Dictionary = {}) -> Dictionary:
	var result: Dictionary = service.request(op, payload)
	check(op + " completed", result.ok)
	return result

func capture(label: String) -> Dictionary:
	var world: Dictionary = service.model.snapshot()
	var resolved: Array = []
	for item in world.objects:
		resolved.append(service.model.object(item.id))
	var data := {"groups": world.groups, "objects": world.objects, "resolved": resolved}
	captures[label] = data
	return data

func near(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if abs(float(a[i]) - float(b[i])) > 0.0002:
			return false
	return true

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output-dir="):
			output = arg.trim_prefix("--output-dir=")
		if arg.begins_with("--phase="):
			phase = arg.trim_prefix("--phase=")
	if output.is_empty() or not phase in ["Create", "RestartLinked", "RestartUnlinked"]:
		push_error("Explicit scratch output directory and phase required.")
		quit(1)
		return
	var path := output.path_join("world.json")
	if phase == "Create" and FileAccess.file_exists(path):
		push_error("Refusing to overwrite an existing fixture.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	service = Service.new(path)
	var ids: Dictionary = {}
	if phase == "Create":
		for group in service.model.snapshot().groups:
			command("DeleteGroup", {"id": group.id})
		for item in service.model.snapshot().objects:
			command("DeleteObject", {"id": item.id})
		ids = {"root": Schema.uuid(), "child": Schema.uuid(), "group": Schema.uuid()}
		var root_part := Schema.box("V4-root", [120, 128, 2], [1, 1, 1], "#FFFFFF")
		var child := Schema.box("V4-child", [122, 128, 2], [1, 1, 1], "#FFFFFF")
		root_part.id = ids.root; child.id = ids.child
		command("CreateObject", {"object": root_part})
		command("CreateObject", {"object": child})
		capture("C01")
		command("GroupObjects", {"id": ids.group, "name": "V4-linkset", "root_id": ids.root, "object_ids": [ids.root, ids.child]})
		var c2 := capture("C02")
		check("C02 independent group ID", c2.groups[0].id != ids.root and c2.groups[0].root_id == ids.root)
		command("UpdateGroup", {"id": ids.group, "patch": {"position": [123, 132, 2]}})
		capture("C03")
		check("C03 translation", near(service.model.object(ids.child).position, [125, 132, 2]))
		command("UpdateGroup", {"id": ids.group, "patch": {"position": [120, 128, 2]}})
		command("UpdateGroup", {"id": ids.group, "patch": {"rotation": [0, 0, sqrt(0.5), sqrt(0.5)]}})
		capture("C04")
		check("C04 positive Z rotation", near(service.model.object(ids.child).position, [120, 130, 2]))
		command("UpdateObject", {"id": ids.child, "patch": {"position": [120, 131, 2]}})
		command("UpdateGroup", {"id": ids.group, "patch": {"scale": 2}})
		capture("C05")
		check("C05 child position", near(service.model.object(ids.child).position, [120, 134, 2]))
		check("C05 child size", near(service.model.object(ids.child).size, [2, 2, 2]))
		command("DuplicateGroup", {"id": ids.group, "offset": [10, 0, 0]})
		var c6 := capture("C06")
		check("C06 copied identities", c6.groups.size() == 2 and c6.objects.size() == 4)
		var before: Dictionary = service.model.snapshot()
		for payload in [{"id": ids.group, "patch": {"position": [-1, 128, 2]}}, {"id": ids.group, "patch": {"rotation": [0, 0, 0, 0]}}, {"id": ids.group, "patch": {"scale": 0}}]:
			check("C09 invalid transform rejected", not service.request("UpdateGroup", payload).ok)
		check("C09 duplicate members rejected", not service.request("GroupObjects", {"id": Schema.uuid(), "name": "bad", "root_id": ids.root, "object_ids": [ids.root, ids.root]}).ok)
		check("C09 wrong root rejected", not service.request("UpdateGroup", {"id": ids.child, "patch": {"position": [120, 128, 2]}}).ok)
		service.actor = Schema.uuid()
		check("C09 foreign actor rejected", not service.request("UpdateGroup", {"id": ids.group, "patch": {"position": [122, 128, 2]}}).ok)
		service.actor = Schema.OWNER
		check("C09 rejected mutations preserve world", before == service.model.snapshot())
		capture("C09")
		command("SaveRegion")
		FileAccess.open(output.path_join("ids.json"), FileAccess.WRITE).store_string(JSON.stringify(ids))
	else:
		ids = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("ids.json")))
		command("LoadRegion")
		if phase == "RestartLinked":
			capture("C07")
			check("C07 child persisted", near(service.model.object(ids.child).position, [120, 134, 2]))
			check("C07 two groups", service.model.snapshot().groups.size() == 2)
			command("UngroupObjects", {"id": ids.group})
			capture("C08")
			check("C08 ID and transform preserved", service.model.object(ids.child).group_id == "" and near(service.model.object(ids.child).position, [120, 134, 2]))
			command("SaveRegion")
		else:
			capture("C08-restart")
			check("C08 unlinked restart", service.model.object(ids.child).group_id == "" and near(service.model.object(ids.child).position, [120, 134, 2]))
			check("C08 preserved duplicate", service.model.snapshot().groups.size() == 1 and service.model.snapshot().objects.size() == 4)
	var report := {"phase": phase, "ok": not failed, "checks": checks, "captures": captures}
	FileAccess.open(output.path_join(phase + ".json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify({"test": "reference-linkset", "phase": phase, "ok": not failed, "checks": checks.size()}))
	quit(1 if failed else 0)
