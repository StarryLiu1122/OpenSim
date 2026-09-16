extends SceneTree
## Fixed native rendering workload. Frame intervals include scheduling and presentation.
const Schema = preload("res://domain/world_schema.gd")
const Demo = preload("res://domain/demo_region.gd")
const View = preload("res://adapters/world_view.gd")
const EnvironmentView = preload("res://adapters/environment_view.gd")
const Assets = preload("res://adapters/mesh_assets.gd")
var output := ""

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output-dir="):
			output = arg.trim_prefix("--output-dir=")
	if output.is_empty() or DisplayServer.get_name() == "headless":
		push_error("Benchmark requires a native renderer and an isolated --output-dir.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var results: Array = []
	for workload in ["demo-day", "mesh-district-night"]:
		var result := await _sample(workload)
		if result.has("error"):
			push_error(result.error)
			quit(1)
			return
		results.append(result)
	var report := {"benchmark_version": 1, "application_version": ProjectSettings.get_setting("application/config/version"), "engine": Engine.get_version_info().string, "os": OS.get_name() + " " + OS.get_version(), "cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method(), "resolution": [1280, 720], "vsync_requested": "disabled", "fps_cap": 0, "warmup_min_frames": 90, "warmup_min_seconds": 2, "sample_min_frames": 180, "sample_min_seconds": 3, "camera_position": [95, 44, -82], "camera_target": [135, 2, -140], "cases": results}
	var file := FileAccess.open(output + "/benchmark.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t", true, true) + "\n")
	file.close()
	print("BENCHMARK_REPORT " + output + "/benchmark.json")
	quit()

func _sample(workload: String) -> Dictionary:
	var started := Time.get_ticks_usec()
	var world := Demo.create()
	var mesh_triangles := 0
	if workload == "mesh-district-night":
		world.environment.sun_hour = 20.0
		for asset_name in ["bench", "tree"]:
			var imported := Assets.import_file({"path": "res://../fixtures/meshes/" + asset_name + ".glb", "name": asset_name, "license": "CC0-1.0", "attribution": "Region Lab contributors"})
			if imported.has("error"):
				return imported
			world.assets.append(imported.asset)
			for i in range(100):
				var east := 70.0 + float(i % 10) * 12.0 + (3.0 if asset_name == "bench" else 0.0)
				var north := 68.0 + float(i / 10) * 12.0
				var item := Schema.box(asset_name, [east, north, float(imported.asset.bounds[2]) * 0.5], imported.asset.bounds, "#FFFFFF")
				item.asset_id = imported.asset.id
				world.objects.append(item)
			mesh_triangles += int(imported.triangles) * 100
	var valid := Schema.validate(world)
	if not valid.is_empty():
		return {"error": valid}
	var view = View.new(); root.add_child(view); view.rebuild(world)
	var env = EnvironmentView.new(); root.add_child(env); env.sync(world.environment); view.sync_environment(world.environment)
	var camera := Camera3D.new(); root.add_child(camera)
	camera.fov = 52; camera.far = 700; camera.current = true
	camera.position = Vector3(95, 44, -82); camera.look_at(Vector3(135, 2, -140))
	await process_frame
	await RenderingServer.frame_post_draw
	var first_frame_ms := (Time.get_ticks_usec() - started) / 1000.0
	var warmup_started := Time.get_ticks_usec()
	var warmup_frames := 0
	while warmup_frames < 90 or Time.get_ticks_usec() - warmup_started < 2000000:
		await process_frame
		await RenderingServer.frame_post_draw
		warmup_frames += 1
	var frames: Array[float] = []
	var draw_calls: Array[float] = []
	var rendered: Array[float] = []
	var memory: Array[float] = []
	var previous := Time.get_ticks_usec()
	var sampling_started := previous
	while frames.size() < 180 or Time.get_ticks_usec() - sampling_started < 3000000:
		await process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		frames.append((now - previous) / 1000.0)
		previous = now
		draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		rendered.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		memory.append(Performance.get_monitor(Performance.MEMORY_STATIC))
	var total_ms := 0.0
	for value in frames:
		total_ms += value
	var capture := root.get_texture().get_image().save_png(output + "/" + workload + ".png")
	var sorted := frames.duplicate(); sorted.sort()
	var lights: int = world.objects.filter(func(item): return Schema.kind(item.asset_id) == "lamp" and item.state.active).size()
	var result := {"workload": workload, "objects": world.objects.size(), "groups": world.groups.size(), "imported_assets": world.assets.size() - 6, "imported_triangles_including_proxies": mesh_triangles, "active_point_lights": lights, "sun_hour": world.environment.sun_hour, "scene_build_to_first_frame_ms": first_frame_ms, "warmup_frames": warmup_frames, "sample_frames": frames.size(), "frame_p50_ms": sorted[int(ceil(sorted.size() * 0.5)) - 1], "frame_p95_ms": sorted[int(ceil(sorted.size() * 0.95)) - 1], "average_fps": frames.size() * 1000.0 / total_ms, "sample_duration_ms": total_ms, "draw_calls_max": draw_calls.max(), "rendered_primitive_monitor_max": rendered.max(), "godot_static_memory_max_bytes": memory.max(), "frame_intervals_ms": frames, "screenshot_ok": capture == OK}
	camera.free(); env.free(); view.free()
	await process_frame
	return result
