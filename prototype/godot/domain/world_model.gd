extends RefCounted
const Schema = preload("res://domain/world_schema.gd")

var _world: Dictionary

func _init(initial: Dictionary = {}) -> void:
	_world = Schema.seed() if initial.is_empty() else initial.duplicate(true)

func snapshot() -> Dictionary:
	return _world.duplicate(true)

func revision() -> int:
	return int(_world.revision)

func replace(candidate: Dictionary) -> String:
	var error := Schema.validate(candidate)
	if error.is_empty():
		_world = candidate.duplicate(true)
	return error

func object(id: String) -> Dictionary:
	for item in _world.objects:
		if item.id == id:
			return item.duplicate(true)
	return {}

func mutate(operation: String, payload: Dictionary, actor: String) -> Dictionary:
	var next := snapshot()
	var object_id := ""
	match operation:
		"CreateObject":
			if not Schema.exact_keys(payload, ["object"]) or not payload.object is Dictionary:
				return {"error": "CreateObject requires an object."}
			var item: Dictionary = payload.object.duplicate(true)
			if item.get("owner_id") != actor:
				return {"error": "Cannot create an object for another owner."}
			object_id = str(item.get("id", ""))
			next.objects.append(item)
		"UpdateObject", "DeleteObject":
			var fields := ["id", "patch"] if operation == "UpdateObject" else ["id"]
			if not Schema.exact_keys(payload, fields) or not payload.id is String:
				return {"error": "Invalid object command fields."}
			object_id = payload.id
			var index := -1
			for i in range(next.objects.size()):
				if next.objects[i].id == object_id:
					index = i
					break
			if index < 0:
				return {"error": "Object does not exist."}
			if next.objects[index].owner_id != actor:
				return {"error": "Only the owner may edit this object."}
			if operation == "DeleteObject":
				next.objects.remove_at(index)
			else:
				if not payload.patch is Dictionary or payload.patch.is_empty():
					return {"error": "UpdateObject requires a nonempty patch."}
				for key in payload.patch:
					if key not in ["name", "position", "rotation", "size", "color"]:
						return {"error": "Field is not editable: " + str(key)}
					next.objects[index][key] = payload.patch[key]
		_:
			return {"error": "Unknown mutation."}
	var error := Schema.validate(next)
	if not error.is_empty():
		return {"error": error}
	next.revision = revision() + 1
	_world = next.duplicate(true)
	return {"id": object_id, "revision": revision()}
