extends RefCounted
const Schema = preload("res://domain/world_schema.gd")
const T = preload("res://domain/world_transforms.gd")
const Groups = preload("res://domain/group_commands.gd")
const TerrainBrush = preload("res://domain/terrain_brush.gd")

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
			return T.resolve(item, _world.groups)
	return {}

func mutate(operation: String, payload: Dictionary, actor: String) -> Dictionary:
	var next := snapshot()
	var object_id := ""
	var changed_samples := 0
	var extra: Dictionary = {}
	match operation:
		"RenameRegion":
			if actor != next.region.owner_id or not Schema.exact_keys(payload, ["name"]) or not payload.name is String or payload.name.strip_edges().is_empty() or payload.name.length() > 80:
				return {"error": "Only the region owner may set a 1–80 character region name."}
			next.region.name = payload.name
		"SetRegionSpawn":
			if actor != next.region.owner_id or not Schema.exact_keys(payload, ["position"]) or not Schema.vector(payload.position, 3, -100, 600):
				return {"error": "Only the region owner may set a valid spawn position."}
			next.region.spawn = payload.position.duplicate()
		"SetRegionSize":
			if actor != next.region.owner_id or not Schema.exact_keys(payload, ["size"]) or not Schema.number(payload.size, 256, 512) or float(payload.size) not in [256.0, 512.0]:
				return {"error": "Only the region owner may choose a 256 or 512 metre square region."}
			var old: Dictionary = next.terrain
			var columns := int(payload.size / old.spacing) + 1
			if columns > 129:
				return {"error": "Terrain sampling would exceed 129 columns."}
			var heights: Array = []
			for north in range(columns):
				for east in range(columns):
					var source_x := mini(east, int(old.columns) - 1)
					var source_y := mini(north, int(old.rows) - 1)
					heights.append(old.heights[source_y * int(old.columns) + source_x])
			next.region.size = [float(payload.size), float(payload.size)]
			next.terrain = {"columns": columns, "rows": columns, "spacing": old.spacing, "heights": heights}
		"GroupObjects", "UpdateGroup", "DuplicateGroup", "UngroupObjects", "DeleteGroup":
			extra = Groups.apply(next, operation, payload, actor)
			if extra.has("error"):
				return extra
			object_id = extra.id
		"RegisterAsset":
			if actor != next.region.owner_id or not Schema.exact_keys(payload, ["asset"]):
				return {"error": "Only the region owner may register an asset."}
			var checked := Schema.MeshAssets.read(payload.asset)
			if checked.has("error"):
				return checked
			object_id = payload.asset.id
			for asset in next.assets:
				if asset.id == object_id:
					if asset.get("sha256") != payload.asset.sha256:
						return {"error": "Asset ID prefix collision; existing content was preserved."}
					return {"id": object_id, "changed": false, "revision": revision(), "reused": true}
			next.assets.append(payload.asset.duplicate(true))
		"RemoveAsset":
			if actor != next.region.owner_id or not Schema.exact_keys(payload, ["id"]) or payload.id not in Schema.mesh_ids(next):
				return {"error": "Only the region owner may remove an imported asset."}
			for item in next.objects:
				if item.asset_id == payload.id:
					return {"error": "Asset is still referenced by a world object."}
			for asset in next.assets:
				if asset.id == payload.id:
					next.assets.erase(asset)
					break
			object_id = payload.id
		"UpdateEnvironment":
			if actor != next.region.owner_id:
				return {"error": "Only the region owner may edit the environment."}
			if not Schema.exact_keys(payload, ["patch"]) or not payload.patch is Dictionary or payload.patch.is_empty():
				return {"error": "UpdateEnvironment requires a nonempty patch."}
			for key in payload.patch:
				if not next.environment.has(key):
					return {"error": "Unknown environment field."}
				next.environment[key] = payload.patch[key]
		"SculptTerrain":
			if next.region.owner_id != actor:
				return {"error": "Only the region owner may edit terrain."}
			var sculpted := TerrainBrush.apply(next.terrain, payload)
			if sculpted.has("error"):
				return sculpted
			changed_samples = sculpted.changed_samples
			if changed_samples == 0:
				return {"changed": false, "changed_samples": 0, "revision": revision()}
			next.terrain = sculpted.terrain
		"CreateObject":
			if not Schema.exact_keys(payload, ["object"]) or not payload.object is Dictionary:
				return {"error": "CreateObject requires an object."}
			var item: Dictionary = payload.object.duplicate(true)
			if item.get("owner_id") != actor or item.get("group_id", "") != "":
				return {"error": "Cannot create an object for another owner."}
			object_id = str(item.get("id", ""))
			next.objects.append(item)
		"UpdateObject", "DeleteObject", "SetObjectState":
			var fields := ["id", "patch"] if operation == "UpdateObject" else (["id", "active"] if operation == "SetObjectState" else ["id"])
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
				if not next.objects[index].group_id.is_empty():
					return {"error": "Ungroup the object or delete the whole group first."}
				next.objects.remove_at(index)
			elif operation == "SetObjectState":
				if Schema.kind(next.objects[index].asset_id) not in ["door", "lamp"] or not payload.active is bool:
					return {"error": "Only doors and lamps accept a boolean active state."}
				next.objects[index].state.active = payload.active
			else:
				if not payload.patch is Dictionary or payload.patch.is_empty():
					return {"error": "UpdateObject requires a nonempty patch."}
				var updated := T.resolve(next.objects[index], next.groups)
				for key in payload.patch:
					if key not in ["name", "position", "rotation", "size", "color", "material"]:
						return {"error": "Field is not editable: " + str(key)}
					updated[key] = payload.patch[key]
				var edit_error := Schema.validate_object(updated, next.region, Schema.mesh_ids(next))
				if not edit_error.is_empty():
					return {"error": edit_error}
				next.objects[index] = updated if updated.group_id.is_empty() else T.localize(updated, T.group(next, updated.group_id))
		_:
			return {"error": "Unknown mutation."}
	var candidate_error := Schema.validate(next)
	if not candidate_error.is_empty():
		return {"error": candidate_error}
	if next == _world:
		return {"changed": false, "changed_samples": 0, "revision": revision()}
	next.revision = revision() + 1
	var error := Schema.validate(next)
	if not error.is_empty():
		return {"error": error}
	_world = next.duplicate(true)
	var result := {"id": object_id, "revision": revision(), "changed": true, "changed_samples": changed_samples}
	result.merge(extra, true)
	return result
