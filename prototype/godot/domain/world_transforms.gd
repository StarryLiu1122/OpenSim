extends RefCounted
## Portable coordinates only. Group scale is uniform to avoid shear ambiguity.
static func vec(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

static func arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

static func quat(a: Array) -> Quaternion:
	return Quaternion(a[0], a[1], a[2], a[3])

static func rotation(q: Quaternion) -> Array:
	q = q.normalized()
	return [q.x, q.y, q.z, q.w]

static func group(world: Dictionary, id: String) -> Dictionary:
	for entry in world.groups:
		if entry.id == id:
			return entry
	return {}

static func resolve(item: Dictionary, groups: Array) -> Dictionary:
	var result := item.duplicate(true)
	if item.get("group_id", "").is_empty():
		return result
	for frame in groups:
		if frame.id == item.group_id:
			var q := quat(frame.rotation)
			result.position = arr(vec(frame.position) + q * vec(item.position) * float(frame.scale))
			result.rotation = rotation(q * quat(item.rotation))
			result.size = arr(vec(item.size) * float(frame.scale))
			return result
	return result

static func localize(item: Dictionary, frame: Dictionary) -> Dictionary:
	var result := item.duplicate(true)
	var inverse := quat(frame.rotation).inverse()
	result.position = arr(inverse * (vec(item.position) - vec(frame.position)) / float(frame.scale))
	result.rotation = rotation(inverse * quat(item.rotation))
	result.size = arr(vec(item.size) / float(frame.scale))
	result.group_id = frame.id
	return result

static func objects(world: Dictionary) -> Array:
	var result: Array = []
	for item in world.objects:
		result.append(resolve(item, world.groups))
	return result
