extends RefCounted
const Repository = preload("res://adapters/sqlite_repository.gd")
const Wire = preload("res://network/wire.gd")

# One immutable job, one worker, no scene nodes or shared WorldService on this thread.
func commit(config: Dictionary, world: Dictionary, expected: int, receipt: Dictionary) -> Dictionary:
	var repo = Repository.new(config.storage, config.store)
	var path: String = config.storage.path_join("network-" + receipt.request_id + ".json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return {"error": "CANDIDATE_WRITE_FAILED"}
	file.store_string(Wire.canonical(world)); file.flush(); file.close()
	var request := {"operation": "save", "input": path, "expected_commit": expected, "request_id": receipt.request_id, "network_receipt": receipt}
	if config.has("test_storage_fault"): request.fault = config.test_storage_fault
	var result: Dictionary = repo._invoke(request)
	DirAccess.remove_absolute(path)
	if not result.has("error"): return result
	# A writer can commit and die before writing its response. Resolve from the
	# transactional receipt before publishing either success or definitive failure.
	var probe: Dictionary = repo._invoke({"operation": "receipts"})
	if probe.has("error"): return {"error": "STORAGE_OUTCOME_UNKNOWN", "frozen": true}
	for saved in probe.receipts:
		if saved.request_id == receipt.request_id and saved.fingerprint == receipt.fingerprint:
			var loaded: Dictionary = repo.load_world()
			if loaded.has("error") or Wire.state_digest(loaded.world) != Wire.state_digest(world): return {"error": "STORAGE_OUTCOME_UNKNOWN", "frozen": true}
			return loaded
	return result
