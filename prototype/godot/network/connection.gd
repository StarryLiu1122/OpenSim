extends Node
signal updated(world_changed: bool)
signal result_received(result: Dictionary)
signal inventory_result_received(result: Dictionary)
signal welcomed
const Wire = preload("res://network/wire.gd")
const Schema = preload("res://domain/world_schema.gd")
var local = preload("res://network/local_world_view.gd").new()
var assets = preload("res://network/asset_loader.gd").new()
var peer: WebSocketPeer
var welcome: Dictionary = {}
var pending: Dictionary = {}
var inventory_pending: Dictionary = {}
var results: Dictionary = {}
var status := "Disconnected"
var _token := ""
var _hello := false
var _started := 0
var _sequence := 0
var bytes_received := 0
var packets_received := 0
var last_packet_at := 0
var test_drop_delta := false
var test_duplicate_delta := false
var _resync_pending := false
var _bad_snapshots := 0

func _ready() -> void:
	add_child(assets)

func connect_to(url: String, token: String, base_url: String, ca: X509Certificate = null) -> void:
	disconnect_from()
	_token = token; assets.token = token; assets.base_url = base_url; assets.certificate = ca
	peer = WebSocketPeer.new(); peer.inbound_buffer_size = 8 * 1024 * 1024; peer.outbound_buffer_size = Wire.MAX_PACKET + 1024; peer.max_queued_packets = 128
	var error := peer.connect_to_url(url, TLSOptions.client(ca) if ca != null else null)
	_started = Time.get_ticks_msec(); status = "Connecting" if error == OK else "Connection failed"

func disconnect_from() -> void:
	if peer != null: peer.close(); peer = null
	for id in pending: results[id] = {"request_id": id, "ok": false, "code": "OUTCOME_UNKNOWN_QUERY_AFTER_RECONNECT"}
	for id in inventory_pending:
		inventory_result_received.emit({"request_id": id, "ok": false, "code": "CONNECTION_CLOSED", "data": {}})
	inventory_pending.clear()
	pending.clear(); local.reset(); assets.reset(); welcome.clear(); _sequence = 0; _hello = false; _token = ""; _resync_pending = false; _bad_snapshots = 0; status = "Disconnected"

func online() -> bool:
	return peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN and not welcome.is_empty() and local.has_state()

func send(packet: Dictionary) -> bool:
	return peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN and peer.send_text(Wire.canonical(packet)) == OK

func command(operation: String, payload: Dictionary) -> String:
	if not online(): return ""
	_sequence += 1
	var id := Schema.uuid()
	var packet := Wire.packet("command", {"world_id": welcome.world_id, "region_id": welcome.region_id, "world_epoch": welcome.world_epoch, "request_id": id, "trace_id": Schema.uuid(), "origin": "web" if OS.has_feature("web") else "desktop", "source_seq": _sequence, "expected_revision": local.snapshot().meta.revision, "expires_at_ms": int(Time.get_unix_time_from_system() * 1000) + 30000, "operation": operation, "payload": payload})
	if not send(packet): return ""
	pending[id] = packet
	status = "Waiting for durable commit"
	return id

func inventory(action: String, params: Dictionary = {}) -> String:
	if not online() or action not in ["list", "folder_create", "add", "remove", "move", "give"]: return ""
	var id := Schema.uuid()
	if not send(Wire.packet("inventory", {"request_id": id, "action": action, "params": params.duplicate(true)})): return ""
	inventory_pending[id] = action
	return id

func _process(_delta: float) -> void:
	if peer == null: return
	peer.poll()
	var state := peer.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		var reason := peer.get_close_reason()
		disconnect_from(); status = "Disconnected: " + reason; return
	if state != WebSocketPeer.STATE_OPEN:
		if Time.get_ticks_msec() - _started > 8000: disconnect_from(); status = "Connection timeout"
		return
	if not _hello: send(Wire.packet("hello", {"token": _token})); _hello = true
	var count := 0
	while peer != null and peer.get_available_packet_count() > 0 and count < 64:
		count += 1
		var bytes := peer.get_packet(); bytes_received += bytes.size(); packets_received += 1; last_packet_at = Time.get_ticks_msec()
		var parsed: Variant = Wire.decode(bytes)
		if not parsed is Dictionary or parsed.get("fp_version") != Wire.VERSION: disconnect_from(); status = "Invalid server packet"; return
		accept(parsed)

func accept(packet: Dictionary) -> void:
	match packet.type:
		"welcome": welcome = packet; local.reset(); welcomed.emit(); status = "Synchronizing"
		"snapshot", "delta":
			if test_drop_delta and packet.type == "delta": test_drop_delta = false; return
			var disposition: String = local.accept(packet)
			if disposition == "resync":
				if packet.type == "snapshot": _resync_pending = false; _bad_snapshots += 1
				if _bad_snapshots >= 3: disconnect_from(); status = "Snapshot integrity check failed"; return
				if not _resync_pending: send(Wire.packet("resync")); _resync_pending = true
				status = "Recovering stream gap"; return
			if disposition != "accepted": return
			send(Wire.packet("ack", {"seq": local.sequence}))
			if packet.type == "snapshot": _resync_pending = false; _bad_snapshots = 0
			if test_duplicate_delta and packet.type == "delta": test_duplicate_delta = false; local.accept(packet)
			if local.world_changed: assets.set_required(local.snapshot().assets)
			updated.emit(local.world_changed)
			if pending.is_empty(): status = "Connected"
		"result":
			pending.erase(packet.request_id); results[packet.request_id] = packet
			if results.size() > 256: results.erase(results.keys()[0])
			status = "Committed · revision " + str(packet.revision) if packet.ok else "Rejected: " + str(packet.code)
			result_received.emit(packet)
		"inventory_result":
			var id := str(packet.get("request_id", ""))
			if not inventory_pending.has(id): return
			inventory_pending.erase(id)
			inventory_result_received.emit(packet)
