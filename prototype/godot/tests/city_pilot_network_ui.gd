extends SceneTree
## Read-only visual acceptance against the dedicated Delft network instance.
var app

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var config_path := ""
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--network-config="): config_path = arg.trim_prefix("--network-config=")
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	if config_path.is_empty() or output.is_empty():
		push_error("Required network config and output image.")
		quit(1)
		return
	app = load("res://network/client.tscn").instantiate()
	root.add_child(app)
	var ready := false
	for frame in range(1800):
		if app.interactive:
			ready = true
			break
		await process_frame
	if not ready:
		push_error("City client did not become interactive.")
		quit(1)
		return
	var world: Dictionary = app.connection.local.snapshot()
	var meshes := 0
	for asset in world.assets.values():
		if asset.get("kind", "") == "mesh": meshes += 1
	var ok: bool = world.objects.size() == 12 and meshes == 12 and app.view.bodies.size() == 12 and app.connection.assets.ready() and app.ui.source_credit.visible
	for item in world.objects.values():
		ok = ok and str(item.name).begins_with("代尔夫特建筑 ")
	if not ok:
		push_error("Unexpected city world, model geometry, or asset readiness.")
		quit(1)
		return
	app.ui.welcome.hide()
	for frame in range(20): await process_frame
	await RenderingServer.frame_post_draw
	var saved := root.get_texture().get_image().save_png(output)
	print("CITY_NETWORK_UI " + JSON.stringify({"ok": saved == OK, "objects": world.objects.size(), "mesh_assets": meshes, "sequence": app.connection.local.sequence, "screenshot": output}))
	app.connection.disconnect_from()
	app.queue_free()
	await process_frame
	quit(0 if saved == OK else 1)
