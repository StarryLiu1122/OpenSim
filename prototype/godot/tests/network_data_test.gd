extends SceneTree
const Wire = preload("res://network/wire.gd")
const Demo = preload("res://domain/demo_region.gd")
const Local = preload("res://network/local_world_view.gd")
const Schema = preload("res://domain/world_schema.gd")
var checks: Array = []
func check(value: bool, label: String) -> void:
	checks.append({"passed": value, "name": label})
	print("PASS " if value else "FAIL ", label)
func _initialize() -> void:
	var world := Demo.create()
	var state := {"meta": {}, "objects": {}, "groups": {}, "assets": {}, "avatars": {}}
	for key in ["schema_version", "revision", "region", "terrain", "environment"]: state.meta[key] = world[key]
	for category in ["objects", "groups", "assets"]:
		for record in world[category]: state[category][record.id] = record
	# Mixed key types, negative zero and float32 transforms from real processes.
	state.assets.values()[0].bytes = 42
	state.avatars[Schema.OWNER] = {"position": [-0.0, 7.6999998092651367, -0.00000001], "tick": 42}
	check(Wire.state_digest(state) == Wire.state_digest(JSON.parse_string(Wire.canonical(state))), "projection checksum survives JSON numeric and key-type round trip")
	var wire_epoch := Schema.uuid()
	var snapshot := Wire.packet("snapshot", {"world_epoch": wire_epoch, "seq": 1, "state": state, "state_hash": Wire.digest(Wire.projection_hashes(state))})
	var local = Local.new()
	check(local.accept(JSON.parse_string(Wire.canonical(snapshot))) == "accepted", "read-only projection accepts a real serialized snapshot")
	var isolated: Dictionary = local.snapshot(); isolated.objects.clear()
	check(not local.snapshot().objects.is_empty(), "snapshot reference cannot mutate the projection")
	var next: Dictionary = state.duplicate(true)
	var removed: String = next.objects.keys()[0]; next.objects.erase(removed); next.meta.revision += 1
	var change := Wire.packet("delta", {"world_epoch": wire_epoch, "seq": 2, "delta": Wire.diff(state, next), "state_hash": Wire.digest(Wire.projection_hashes(next))})
	check(local.accept(change) == "accepted" and not local.snapshot().objects.has(removed), "delta deletion and revision publish together")
	check(local.accept(change) == "duplicate" and local.sequence == 2, "duplicate delta cannot replay changes")
	change.seq = 4
	check(local.accept(change) == "resync" and local.sequence == 2, "missing sequence refuses partial publication")
	change.seq = 3; change.world_epoch = Schema.uuid()
	check(local.accept(change) == "resync", "cross-epoch delta requires a fresh snapshot")
	snapshot.seq = 5; snapshot.world_epoch = change.world_epoch
	check(local.accept(snapshot) == "accepted" and local.sequence == 5, "new epoch snapshot establishes a sequence boundary")
	snapshot.seq = 6; snapshot.state_hash = "0".repeat(64)
	check(local.accept(snapshot) == "resync" and local.sequence == 5, "corrupted checksum cannot replace visible state")
	check(Wire.decode('{"type":"hello","token":"a","token":"b"}'.to_utf8_buffer()) == null, "duplicate JSON keys rejected")
	check(Wire.decode('{"nested":{"a":1,"a":2}}'.to_utf8_buffer()) == null, "nested duplicate keys rejected")
	check(Wire.decode('{"token":"a","to\\u006ben":"b"}'.to_utf8_buffer()) == null, "escaped duplicate keys rejected")
	check(Wire.decode(('['.repeat(25) + '0' + ']'.repeat(25)).to_utf8_buffer()) == null, "excessive nesting rejected")
	check(Wire.decode(PackedByteArray([255, 254])) == null, "invalid UTF-8 rejected")
	check(Wire.decode('"'.repeat(Wire.MAX_PACKET + 1).to_utf8_buffer()) == null, "oversized packet rejected")
	check(Wire.decode('{"quote":"a\\\"b","array":[1,{"ok":true}]}'.to_utf8_buffer()) is Dictionary, "valid escaped strings and nested arrays accepted")
	var passed: bool = checks.all(func(item): return item.passed)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			var file := FileAccess.open(arg.trim_prefix("--output="), FileAccess.WRITE); file.store_string(JSON.stringify({"suite": "network-data-contract", "passed": passed, "checks": checks}, "\t")); file.close()
	quit(0 if passed else 1)
