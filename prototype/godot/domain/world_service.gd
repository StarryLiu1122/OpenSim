extends RefCounted
## UI and automated callers use the same versioned command gateway.
const Schema = preload("res://domain/world_schema.gd")
const Model = preload("res://domain/world_model.gd")
const Repository = preload("res://adapters/snapshot_repository.gd")

var model = Model.new()
var repository
var actor := Schema.OWNER
var dirty := true
var _requests: Dictionary = {}
var _history: Array[Dictionary] = []

func _init(file_path: String = "user://worlds/default.json") -> void:
	repository = Repository.new(file_path)

func request(operation: String, payload: Dictionary = {}) -> Dictionary:
	return dispatch({"api_version": 1, "request_id": Schema.uuid(), "operation": operation, "expected_revision": model.revision(), "payload": payload})

func dispatch(command: Variant) -> Dictionary:
	if not command is Dictionary or not Schema.exact_keys(command, ["api_version", "request_id", "operation", "expected_revision", "payload"]):
		return _result("", "", false, {}, "INVALID_COMMAND", "Invalid command fields.")
	if command.api_version != 1 or not Schema.is_uuid(command.request_id) or not command.operation is String or not command.payload is Dictionary or not Schema.number(command.expected_revision, 0, 1000000000) or command.expected_revision != floor(float(command.expected_revision)):
		return _result("", "", false, {}, "INVALID_COMMAND", "Invalid command version or types.")
	var operation: String = command.operation
	var id: String = command.request_id
	var fingerprint := JSON.stringify(command, "", true, true).sha256_text()
	if _requests.has(id):
		if _requests[id].fingerprint != fingerprint:
			return _result(operation, id, false, {}, "REQUEST_REUSED", "Request ID reused with different content.")
		return _requests[id].result.duplicate(true)
	var outcome: Dictionary
	if command.expected_revision != model.revision():
		outcome = _result(operation, id, false, {}, "REVISION_CONFLICT", "World changed; query the current revision and retry.")
	else:
		outcome = _execute(operation, id, command.payload)
	_requests[id] = {"fingerprint": fingerprint, "result": outcome.duplicate(true)}
	if _requests.size() > 256:
		_requests.erase(_requests.keys()[0])
	return outcome

func _execute(operation: String, id: String, payload: Dictionary) -> Dictionary:
	if operation in ["GetRegionSnapshot", "SaveRegion", "LoadRegion", "Undo"] and not payload.is_empty():
		return _result(operation, id, false, {}, "INVALID_PAYLOAD", "This operation takes no payload fields.")
	match operation:
		"GetRegionSnapshot":
			return _result(operation, id, true, {"world": model.snapshot()})
		"SaveRegion":
			var saved: Dictionary = repository.save_world(model.snapshot())
			if saved.has("error"):
				return _result(operation, id, false, {}, "SAVE_FAILED", saved.error)
			dirty = false
			return _result(operation, id, true, saved)
		"LoadRegion":
			var loaded: Dictionary = repository.load_world()
			if loaded.has("error"):
				return _result(operation, id, false, {}, "LOAD_FAILED", loaded.error)
			model.replace(loaded.world)
			_history.clear()
			_requests.clear()
			dirty = loaded.recovered
			var result := _result(operation, id, true, {"recovered": loaded.recovered, "path": repository.path})
			if loaded.has("warning"):
				result.warnings.append(loaded.warning)
			return result
		"Undo":
			if _history.is_empty():
				return _result(operation, id, false, {}, "NOTHING_TO_UNDO", "Nothing to undo.")
			var previous: Dictionary = _history.pop_back()
			previous.revision = model.revision() + 1
			model.replace(previous)
			dirty = true
			return _result(operation, id, true, {})
		"CreateObject", "UpdateObject", "DeleteObject":
			var previous: Dictionary = model.snapshot()
			var mutation: Dictionary = model.mutate(operation, payload, actor)
			if mutation.has("error"):
				return _result(operation, id, false, {}, "MUTATION_REJECTED", mutation.error)
			_history.append(previous)
			if _history.size() > 30:
				_history.pop_front()
			dirty = true
			return _result(operation, id, true, mutation)
	return _result(operation, id, false, {}, "UNKNOWN_OPERATION", "Unsupported operation.")

func _result(operation: String, request_id: String, ok: bool, payload: Dictionary, code: String = "", message: String = "") -> Dictionary:
	return {"api_version": 1, "ok": ok, "operation": operation, "request_id": request_id, "revision": model.revision(), "payload": payload, "warnings": [], "errors": [] if ok else [{"code": code, "message": message}]}
