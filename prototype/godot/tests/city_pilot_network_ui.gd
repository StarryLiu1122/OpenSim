extends SceneTree
## Read-only visual acceptance against a dedicated city network instance.
var app

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var config_path := ""
	var output := ""
	var expected := 12
	var prefix := "代尔夫特建筑 "
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--network-config="): config_path = arg.trim_prefix("--network-config=")
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
		if arg.begins_with("--expected="): expected = int(arg.trim_prefix("--expected="))
		if arg.begins_with("--name-prefix="): prefix = arg.trim_prefix("--name-prefix=")
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
	var spawn_clear := true
	if expected == 16 or expected == 64:
		var spawn: Array = world.meta.region.spawn
		var x := float(spawn[0])
		var z := -float(spawn[1])
		var hit: Dictionary = app.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 120, z), Vector3(x, -40, z), 3))
		spawn_clear = not hit.is_empty() and app.view.bodies.values().has(hit.collider) and float(spawn[2]) - hit.position.y > 0.5 and float(spawn[2]) - hit.position.y < 5.0
		print("CITY_SPAWN " + JSON.stringify({"spawn": spawn, "hit_y": hit.get("position", Vector3.ZERO).y, "clear": spawn_clear}))
	var meshes := 0
	for asset in world.assets.values():
		if asset.get("kind", "") == "mesh": meshes += 1
	var textured := 0
	for body in app.view.bodies.values():
		for child in body.get_children():
			if child is MeshInstance3D and child.material_override is StandardMaterial3D and child.material_override.albedo_texture != null:
				textured += 1
	var ok: bool = world.objects.size() == expected and meshes == expected and app.view.bodies.size() == expected and app.connection.assets.ready() and app.ui.source_credit.visible
	if expected == 16 or expected == 64: ok = ok and textured == expected and spawn_clear and app.ui.source_credit.text == "© City of Helsinki"
	for item in world.objects.values():
		ok = ok and str(item.name).begins_with(prefix)
	if not ok:
		print("CITY_NETWORK_DIAGNOSTIC " + JSON.stringify({"objects": world.objects.size(), "meshes": meshes, "bodies": app.view.bodies.size(), "assets_ready": app.connection.assets.ready(), "credit": app.ui.source_credit.visible, "textured": textured, "names": world.objects.values().map(func(item): return item.name)}))
		push_error("Unexpected city world, model geometry, or asset readiness.")
		quit(1)
		return
	if expected == 16 or expected == 64:
		app._walk()
		if not app.walking:
			push_error("Real-city walkthrough did not start.")
			quit(1)
			return
		app._stop_walk()
	app.ui.welcome.hide()
	for frame in range(20): await process_frame
	await RenderingServer.frame_post_draw
	var saved := root.get_texture().get_image().save_png(output)
	print("CITY_NETWORK_UI " + JSON.stringify({"ok": saved == OK, "objects": world.objects.size(), "mesh_assets": meshes, "textured_objects": textured, "sequence": app.connection.local.sequence, "screenshot": output}))
	app.connection.disconnect_from()
	app.queue_free()
	await process_frame
	quit(0 if saved == OK else 1)
