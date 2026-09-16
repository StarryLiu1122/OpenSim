extends SceneTree
const Service = preload("res://domain/world_service.gd")
const Schema = preload("res://domain/world_schema.gd")
const Demo = preload("res://domain/demo_region.gd")

func _initialize() -> void:
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	if output.is_empty() or FileAccess.file_exists(output): quit(2); return
	var service = Service.new(output)
	service.model.replace(Demo.create())
	var imported: Dictionary = service.request("ImportGlb", {"path": "res://../fixtures/buildings/pioneer-log-cabin/pioneer-log-cabin.glb", "name": "Pioneer Log Cabin", "license": "CC0-1.0", "attribution": "LOC HABS WIS-18; Region Lab measured-drawing derivative"})
	if not imported.ok: quit(1); return
	var asset: Dictionary = service.model.snapshot().assets[-1]
	var item := Schema.box("Database building", [70, 69.3096, 2.1209], asset.bounds, "#FFFFFF"); item.asset_id = asset.id
	if not service.request("CreateObject", {"object": item}).ok: quit(1); return
	for record in service.model.snapshot().objects:
		if Schema.kind(record.asset_id) in ["door", "lamp"]:
			if not service.request("SetObjectState", {"id": record.id, "active": true}).ok: quit(1); return
	quit(0 if service.request("SaveRegion").ok else 1)
