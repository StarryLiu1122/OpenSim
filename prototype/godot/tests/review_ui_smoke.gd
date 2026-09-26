extends SceneTree
## Instantiate the real network client and exercise the expert review controls.
const Schema = preload("res://domain/world_schema.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var app = load("res://network/client.tscn").instantiate()
	root.add_child(app)
	await process_frame
	if app.ui.review_tab_index < 0 or app.ui.review_list == null or app.ui.review_save_button == null:
		push_error("Expert review controls did not build."); quit(1); return
	var marker := Schema.box("预测点 · quay-east · 2.40 m", [140.0, 145.0, 5.0], [1.0, 1.0, 8.0], "#31a6d8")
	app.connection.local._state = {"objects": {marker.id: marker}}
	app._refresh_reviews({"objects": {marker.id: marker}})
	if app.ui.review_list.item_count != 1 or app.review_ids[0] != marker.id:
		push_error("Prediction marker is absent from review list."); quit(1); return
	app._review_select(0)
	if app.review_selected_id != marker.id or not app.ui.review_info.text.contains("quay-east"):
		push_error("Prediction selection did not expose location."); quit(1); return
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("runtime/review-save-smoke-" + str(Time.get_ticks_usec()))
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		push_error("Could not create isolated review test directory."); quit(1); return
	app.test_directory = directory
	app.review_store_error = ""
	app.review_records = [{"id": "first"}]
	if not app._persist_reviews():
		push_error("First review store write failed."); quit(1); return
	app.review_records.append({"id": "second"})
	if not app._persist_reviews():
		push_error("Second review store write failed."); quit(1); return
	var path := directory.path_join("expert-reviews.json")
	if not FileAccess.file_exists(path + ".bak"):
		push_error("Previous complete review store was not retained."); quit(1); return
	if DirAccess.rename_absolute(path, path + ".bak") != OK:
		push_error("Could not simulate interrupted review save."); quit(1); return
	app.review_records.clear()
	app._load_reviews()
	if app.review_records.size() != 2 or not FileAccess.file_exists(path):
		push_error("Interrupted review save did not recover both records."); quit(1); return
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(directory)
	print("REVIEW_UI_SMOKE_OK")
	app.queue_free()
	await process_frame
	quit(0)
