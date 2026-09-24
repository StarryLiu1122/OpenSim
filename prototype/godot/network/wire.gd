extends RefCounted
const Schema = preload("res://domain/world_schema.gd")
const VERSION := "0.3"
const MAX_PACKET := 3 * 1024 * 1024
const MUTATIONS := ["CreateObject", "UpdateObject", "DeleteObject", "SculptTerrain", "UpdateEnvironment", "SetRegionSize", "SetObjectState", "GroupObjects", "UpdateGroup", "DuplicateGroup", "UngroupObjects", "DeleteGroup", "RemoveAsset", "UploadAsset", "PlaceInventoryItem"]

static func canonical(value: Variant) -> String:
	return JSON.stringify(_numbers(value), "", true, true)

static func _numbers(value: Variant) -> Variant:
	# JSON.parse_string turns integral JSON values into doubles. Canonical hashes
	# must survive that round trip instead of distinguishing 1 from 1.0.
	if value is float and is_finite(value) and value == floor(value) and absf(value) <= 9007199254740991: return int(value)
	if value is Dictionary:
		var result := {}
		for key in value: result[key] = _numbers(value[key])
		return result
	if value is Array:
		var result: Array = []
		for entry in value: result.append(_numbers(entry))
		return result
	return value

static func digest(value: Variant) -> String:
	return canonical(value).sha256_text()

static func state_digest(value: Variant) -> String:
	return _state_text(value).sha256_text()

static func projection_hashes(state: Dictionary, previous: Dictionary = {}, delta: Dictionary = {}) -> Dictionary:
	var result: Dictionary = previous.duplicate()
	for category in ["meta", "objects", "groups", "assets", "avatars"]:
		var changed_category: bool = previous.is_empty() or delta.is_empty()
		if category == "meta": changed_category = changed_category or delta.has("meta")
		elif not delta.is_empty(): changed_category = changed_category or not delta.upserts[category].is_empty() or not delta.deletes[category].is_empty()
		if changed_category: result[category] = state_digest(state[category])
	return result

static func _state_text(value: Variant) -> String:
	# Godot's decimal parser can differ by one double ULP after a round trip.
	# Projection checksums use five decimal places (10 micrometres for positions).
	# This is NOT the command fingerprint or the binary asset integrity hash.
	if value is int or value is float: return "n" + ("%.5f" % (0.0 if absf(float(value)) < 0.000005 else float(value)))
	if value is String: return "s" + JSON.stringify(value)
	if value is Array:
		var parts := PackedStringArray()
		for item in value: parts.append(_state_text(item))
		return "[" + ",".join(parts) + "]"
	if value is Dictionary:
		var keys: Array = value.keys(); keys.sort_custom(func(a, b): return str(a) < str(b))
		var parts := PackedStringArray()
		for key in keys: parts.append(JSON.stringify(key) + ":" + _state_text(value[key]))
		return "{" + ",".join(parts) + "}"
	return JSON.stringify(value)

static func decode(bytes: PackedByteArray) -> Variant:
	if bytes.size() > MAX_PACKET: return null
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes: return null
	# Reject duplicate keys before JSON.parse_string can collapse them.
	var stack: Array = []
	var i := 0
	while i < text.length():
		var ch := text[i]
		if ch == "{" or ch == "[":
			stack.append({"object": ch == "{", "keys": {}})
			if stack.size() > 24: return null
		elif ch == "}" or ch == "]":
			if stack.is_empty(): return null
			stack.pop_back()
		elif ch == '"':
			var begin := i
			i += 1
			while i < text.length():
				if text[i] == "\\": i += 2; continue
				if text[i] == '"': break
				i += 1
			if i >= text.length(): return null
			var next := i + 1
			while next < text.length() and text[next] in [" ", "\t", "\r", "\n"]: next += 1
			if next < text.length() and text[next] == ":":
				if stack.is_empty() or not stack[-1].object: return null
				var key: Variant = JSON.parse_string(text.substr(begin, i - begin + 1))
				if not key is String or stack[-1].keys.has(key): return null
				stack[-1].keys[key] = true
		i += 1
	if not stack.is_empty(): return null
	return JSON.parse_string(text)

static func packet(type: String, payload: Dictionary = {}) -> Dictionary:
	var result := {"fp_version": VERSION, "type": type}
	result.merge(payload)
	return result

static func diff(before: Dictionary, after: Dictionary) -> Dictionary:
	var result := {"upserts": {}, "deletes": {}}
	for category in ["objects", "groups", "assets", "avatars"]:
		var upserts: Dictionary = {}
		var removed: Array = []
		var old: Dictionary = before.get(category, {})
		for id in after[category]:
			if not old.has(id) or old[id] != after[category][id]: upserts[id] = after[category][id]
		for id in old:
			if not after[category].has(id): removed.append(id)
		result.upserts[category] = upserts
		result.deletes[category] = removed
	if before.get("meta", {}) != after.meta: result.meta = after.meta
	return result

static func changed(delta: Dictionary) -> bool:
	if delta.has("meta"): return true
	for category in delta.upserts:
		if not delta.upserts[category].is_empty() or not delta.deletes[category].is_empty(): return true
	return false

static func apply_delta(state: Dictionary, delta: Dictionary) -> Dictionary:
	var result := state.duplicate(true)
	if delta.has("meta"): result.meta = delta.meta.duplicate(true)
	for category in ["objects", "groups", "assets", "avatars"]:
		for id in delta.deletes[category]: result[category].erase(id)
		for id in delta.upserts[category]: result[category][id] = delta.upserts[category][id].duplicate(true)
	return result
