extends RefCounted
const Schema = preload("res://domain/world_schema.gd")
const T = preload("res://domain/world_transforms.gd")

static func apply(world: Dictionary, operation: String, payload: Dictionary, actor: String) -> Dictionary:
	if operation == "GroupObjects":
		if not Schema.exact_keys(payload, ["id", "name", "root_id", "object_ids"]) or not Schema.is_uuid(payload.id) or not payload.object_ids is Array or payload.object_ids.size() < 2 or payload.object_ids.size() > 100 or payload.root_id not in payload.object_ids:
			return {"error": "A group requires an ID, name, root and 2–100 ungrouped objects."}
		var selected: Array = []
		var seen: Dictionary = {}
		var root: Dictionary = {}
		for id in payload.object_ids:
			if not Schema.is_uuid(id) or seen.has(id):
				return {"error": "Group member IDs must be unique UUIDs."}
			seen[id] = true
			for item in world.objects:
				if item.id == id and item.owner_id == actor and item.group_id.is_empty():
					selected.append(item)
					if id == payload.root_id:
						root = item.duplicate(true)
		if selected.size() != payload.object_ids.size() or root.is_empty():
			return {"error": "Members must exist, be ungrouped and share the current owner."}
		var frame := {"id": payload.id, "name": payload.name, "root_id": payload.root_id, "owner_id": actor, "position": root.position.duplicate(), "rotation": root.rotation.duplicate(), "scale": 1.0}
		for item in selected:
			item.merge(T.localize(item, frame), true)
		world.groups.append(frame)
		return {"id": frame.id, "root_id": frame.root_id}
	var required := ["id", "patch"] if operation == "UpdateGroup" else (["id", "offset"] if operation == "DuplicateGroup" else ["id"])
	if not Schema.exact_keys(payload, required) or not payload.id is String:
		return {"error": "Invalid group command fields."}
	var frame: Dictionary = T.group(world, payload.id)
	if frame.is_empty() or frame.owner_id != actor:
		return {"error": "Group does not exist or is owned by another actor."}
	match operation:
		"UpdateGroup":
			if not payload.patch is Dictionary or payload.patch.is_empty():
				return {"error": "Group patch must be nonempty."}
			for key in payload.patch:
				if key not in ["name", "position", "rotation", "scale"]:
					return {"error": "Group field is not editable: " + str(key)}
				frame[key] = payload.patch[key]
		"UngroupObjects":
			for item in world.objects:
				if item.group_id == frame.id:
					item.merge(T.resolve(item, world.groups), true)
					item.group_id = ""
			world.groups.erase(frame)
		"DeleteGroup":
			for index in range(world.objects.size() - 1, -1, -1):
				if world.objects[index].group_id == frame.id:
					world.objects.remove_at(index)
			world.groups.erase(frame)
		"DuplicateGroup":
			if not Schema.vector(payload.offset, 3, -256, 256):
				return {"error": "Group copy offset must be a finite three-component vector."}
			var copy: Dictionary = frame.duplicate(true)
			copy.id = Schema.uuid()
			copy.name = frame.name.left(75) + " copy"
			copy.position = T.arr(T.vec(frame.position) + T.vec(payload.offset))
			var members: Array = []
			for item in world.objects:
				if item.group_id == frame.id:
					var part: Dictionary = item.duplicate(true)
					part.id = Schema.uuid()
					part.group_id = copy.id
					if item.id == frame.root_id:
						copy.root_id = part.id
					members.append(part)
			world.groups.append(copy)
			world.objects.append_array(members)
			return {"id": copy.id, "root_id": copy.root_id}
		_:
			return {"error": "Unknown group command."}
	return {"id": payload.id, "root_id": frame.root_id}
