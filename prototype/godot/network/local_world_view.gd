extends RefCounted
## Read-only network projection. No WorldService, repository or mutation API.
const Wire = preload("res://network/wire.gd")
var _state: Dictionary = {}
var epoch := ""
var sequence := 0
var resyncs := 0
var duplicates := 0
var world_changed := false
var _hashes: Dictionary = {}

func reset() -> void:
	_state.clear(); _hashes.clear(); epoch = ""; sequence = 0; world_changed = false

func has_state() -> bool:
	return not _state.is_empty()

func snapshot() -> Dictionary:
	return _state.duplicate(true)

func accept(packet: Dictionary) -> String:
	world_changed = false
	if packet.type not in ["snapshot", "delta"] or not packet.get("world_epoch") is String or not packet.get("seq") is float and not packet.get("seq") is int: return "invalid"
	if packet.world_epoch == epoch and packet.seq <= sequence: duplicates += 1; return "duplicate"
	if packet.type == "delta" and (packet.world_epoch != epoch or packet.seq != sequence + 1 or _state.is_empty()): resyncs += 1; return "resync"
	var next: Dictionary = packet.state.duplicate(true) if packet.type == "snapshot" else Wire.apply_delta(_state, packet.delta)
	var hashes := Wire.projection_hashes(next, {} if packet.type == "snapshot" else _hashes, packet.get("delta", {}))
	if Wire.digest(hashes) != packet.state_hash: resyncs += 1; return "resync"
	if packet.type == "snapshot": world_changed = true
	else:
		world_changed = packet.delta.has("meta")
		for category in ["objects", "groups", "assets"]:
			world_changed = world_changed or not packet.delta.upserts[category].is_empty() or not packet.delta.deletes[category].is_empty()
	_state = next; _hashes = hashes; epoch = packet.world_epoch; sequence = int(packet.seq)
	return "accepted"
