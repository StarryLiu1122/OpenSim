extends SceneTree
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const Assets = preload("res://adapters/mesh_assets.gd")
const View = preload("res://adapters/world_view.gd")
const ID := "99999999-9999-4999-8999-999999999999"
const GROUP := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--world-file="):
			path = arg.trim_prefix("--world-file=")
	if path.is_empty():
		push_error("An isolated world file is required.")
		quit(1)
		return
	var service = Service.new(path)
	var ok := false
	var mode := "read"
	if OS.get_cmdline_user_args().has("--write"):
		mode = "write"
		var source := path.get_base_dir() + "/temporary-source.glb"
		DirAccess.copy_absolute(ProjectSettings.globalize_path("res://../fixtures/meshes/pavilion.glb"), source)
		var imported: Dictionary = service.request("ImportGlb", {"path": source, "name": "pavilion", "license": "CC0-1.0", "attribution": "Region Lab contributors"})
		ok = imported.ok and DirAccess.remove_absolute(source) == OK
		if ok:
			var asset: Dictionary = service.model.snapshot().assets[6]
			var item := Schema.box("Portable pavilion", [80, 80, 1.9], asset.bounds, "#FFFFFF")
			item.asset_id = asset.id; item.id = ID
			ok = service.request("CreateObject", {"object": item}).ok
			var other: String = service.model.snapshot().objects[0].id
			ok = ok and service.request("GroupObjects", {"id": GROUP, "name": "Portable group", "root_id": ID, "object_ids": [ID, other]}).ok and service.request("SaveRegion").ok
	else:
		ok = service.request("LoadRegion").ok
		var world: Dictionary = service.model.snapshot()
		ok = ok and world.assets.size() == 7 and world.groups.size() == 1 and service.model.object(ID).group_id == GROUP
		if ok:
			var geometry := Assets.read(world.assets[6])
			ok = not geometry.has("error") and geometry.collision_mode == "proxy" and geometry.surfaces.size() == 8
			var view = View.new(); root.add_child(view); view.rebuild(world)
			await physics_frame
			ok = ok and view.bodies.has(ID) and not view.mesh_view.cache.is_empty()
			view.free()
	print(JSON.stringify({"test": "separate-process-embedded-assets", "mode": mode, "ok": ok}))
	quit(0 if ok else 1)
