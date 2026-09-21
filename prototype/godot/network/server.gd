extends Node3D
const Wire = preload("res://network/wire.gd")
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const Demo = preload("res://domain/demo_region.gd")
const Repository = preload("res://adapters/sqlite_repository.gd")
const View = preload("res://adapters/world_view.gd")
const Avatar = preload("res://network/network_avatar.gd")
const StorageJob = preload("res://network/storage_job.gd")
const Transforms = preload("res://domain/world_transforms.gd")
var config: Dictionary
var service = Service.new()
var store
var accounts: Dictionary = {}
var sessions: Dictionary = {}
var crypto := Crypto.new()
var view = View.new()
var listener := TCPServer.new()
var clients: Array = []
var receipts: Dictionary = {}
var failures: Dictionary = {}
var queued: Array = []
var active: Dictionary = {}
var worker: Thread
var worker_job: RefCounted
var epoch := Schema.uuid()
var commit_revision := -1
var frozen := false
var tick := 0
var accumulator := 0.0
var ready_at := 0

func _ready() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--network-config="): path = arg.trim_prefix("--network-config=")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary: _fatal("INVALID_CONFIGURATION"); return
	config = parsed
	store = Repository.new(config.storage, config.store)
	var initialized: Dictionary = store._invoke({"operation": "init"})
	if initialized.has("error"): _fatal(initialized.error); return
	if store.exists():
		var loaded: Dictionary = store.load_world()
		if loaded.has("error"): _fatal(loaded.error); return
		service.model.replace(loaded.world); commit_revision = int(loaded.commit_revision)
	else:
		service.model.replace(Demo.create())
		if config.has("seed_asset"):
			var imported: Dictionary = service.request("ImportGlb", {"path": config.seed_asset, "name": "Pioneer Log Cabin", "license": "CC0-1.0", "attribution": "Derivative of US Library of Congress HABS WIS-18 measured drawing"})
			if not imported.ok: _fatal(Wire.canonical(imported)); return
			var item := Schema.box("Network cabin", [146.0, 133.0, 1.0], [1.0, 1.0, 1.0], "#ffffff")
			item.asset_id = imported.payload.id
			for asset in service.model.snapshot().assets:
				if asset.id == item.asset_id: item.size = asset.bounds.duplicate(); item.position[2] = float(asset.bounds[2]) * 0.5 + 0.1
			var created: Dictionary = service.request("CreateObject", {"object": item})
			if not created.ok: _fatal(Wire.canonical(created)); return
		var saved: Dictionary = store.save_world(service.model.snapshot())
		if saved.has("error"): _fatal(saved.error); return
		commit_revision = int(saved.commit_revision)
	var prior: Dictionary = store._invoke({"operation": "receipts"})
	if prior.has("error"): _fatal(prior.error); return
	for receipt in prior.receipts: receipts[receipt.request_id] = receipt
	if not _identity_bootstrap(): return
	add_child(view); view.rebuild(service.model.snapshot())
	_publish_assets()
	if listener.listen(int(config.port), "127.0.0.1") != OK: _fatal("PORT_UNAVAILABLE"); return
	ready_at = Time.get_ticks_msec()
	_write(config.storage.path_join("server-ready.json"), {"ok": true, "epoch": epoch, "port": config.port, "revision": service.model.revision(), "pid": OS.get_process_id()})
	print("REGION_SERVER_READY ", epoch)

func _fatal(reason: String) -> void:
	push_error(reason); get_tree().quit(1)

func _write(path: String, value: Variant) -> void:
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(Wire.canonical(value)); file.close()
	DirAccess.rename_absolute(path + ".tmp", path)

# --- V6 identity: accounts and sessions persist in the store; the server keeps
# --- an in-memory registry that every management operation updates only after
# --- the store confirms, so memory never diverges from durable state.

func _identity_bootstrap() -> bool:
	var listed: Dictionary = store._invoke({"operation": "account_list"})
	if listed.has("error"): _fatal("IDENTITY_" + str(listed.error)); return false
	for account in listed.accounts: accounts[account.id] = account
	for session in listed.sessions: sessions[session.token_hash] = session
	var owner_exists := false
	for account in accounts.values():
		if account.role == "owner" and not account.disabled: owner_exists = true
	for i in range(config.principals.size()):
		var principal: Dictionary = config.principals[i]
		var hash: String = String(principal.token).sha256_text()
		if sessions.has(hash): continue
		var remaining: int = int(principal.expires_at_ms) - _utc()
		if remaining <= 0: continue
		var role: String = principal.role
		if i == 0 and not owner_exists:
			# The first configured principal bootstraps as the manageable root owner.
			role = "owner"; owner_exists = true
		if not accounts.has(principal.id):
			var created: Dictionary = store._invoke({"operation": "account_create", "name": principal.name, "role": role, "id": principal.id, "actor_id": principal.actor, "now_ms": _utc()})
			if created.has("error"): _fatal("IDENTITY_" + str(created.error)); return false
			accounts[principal.id] = created.account
		var ttl: int = clampi(remaining, 60000, 2592000000)
		var issued: Dictionary = store._invoke({"operation": "session_issue", "account_id": principal.id, "token_hash": hash, "ttl_ms": ttl, "now_ms": _utc()})
		if issued.has("error"): _fatal("IDENTITY_" + str(issued.error)); return false
		sessions[hash] = {"token_hash": hash, "account_id": principal.id, "issued_at_ms": issued.issued_at_ms, "expires_at_ms": issued.expires_at_ms, "revoked": false}
	return true

func _principal_for(token: String) -> Dictionary:
	var hash := token.sha256_text()
	var session: Dictionary = sessions.get(hash, {})
	if session.is_empty() or session.revoked: return {}
	var account: Dictionary = accounts.get(session.account_id, {})
	if account.is_empty() or account.disabled: return {}
	if _utc() >= int(session.expires_at_ms): return {}
	return {"id": account.id, "name": account.name, "actor": account.actor_id, "role": account.role, "expires_at_ms": int(session.expires_at_ms), "token_hash": hash}

func _session_alive(principal: Dictionary) -> bool:
	var session: Dictionary = sessions.get(principal.get("token_hash", ""), {})
	if session.is_empty() or session.revoked: return false
	var account: Dictionary = accounts.get(session.account_id, {})
	return not account.is_empty() and not account.disabled

func _new_token() -> String:
	return crypto.generate_random_bytes(32).hex_encode()

func _account(client: Dictionary, packet: Dictionary) -> void:
	if not Schema.exact_keys(packet, ["fp_version", "type", "request_id", "action", "params"]) or not Schema.is_uuid(packet.request_id) or not packet.action is String or not packet.params is Dictionary:
		_account_reply(client, "", false, "INVALID_ACCOUNT_REQUEST"); return
	var request_id: String = packet.request_id
	if client.principal.role != "owner": _account_reply(client, request_id, false, "PERMISSION_DENIED"); return
	var params: Dictionary = packet.params
	match packet.action:
		"create":
			if not Schema.exact_keys(params, ["name", "role"]) or not params.name is String or not params.role is String:
				_account_reply(client, request_id, false, "INVALID_ACCOUNT_REQUEST"); return
			var created: Dictionary = store._invoke({"operation": "account_create", "name": params.name, "role": params.role, "now_ms": _utc()})
			if created.has("error"): _account_reply(client, request_id, false, str(created.error)); return
			accounts[created.account.id] = created.account
			_account_reply(client, request_id, true, "", {"account": created.account})
		"disable", "enable":
			if not Schema.exact_keys(params, ["account_id"]) or not Schema.is_uuid(str(params.account_id)):
				_account_reply(client, request_id, false, "INVALID_ACCOUNT_REQUEST"); return
			var updated: Dictionary = store._invoke({"operation": "account_disable", "account_id": params.account_id, "disabled": packet.action == "disable", "now_ms": _utc()})
			if updated.has("error"): _account_reply(client, request_id, false, str(updated.error)); return
			accounts[params.account_id].disabled = packet.action == "disable"
			if packet.action == "disable":
				for hash in sessions:
					if sessions[hash].account_id == params.account_id: sessions[hash].revoked = true
			_account_reply(client, request_id, true, "", {"account_id": params.account_id, "disabled": packet.action == "disable"})
		"issue":
			if not Schema.exact_keys(params, ["account_id", "ttl_ms"]) or not Schema.is_uuid(str(params.account_id)) or not _integer(params.ttl_ms, 60000, 2592000000):
				_account_reply(client, request_id, false, "INVALID_ACCOUNT_REQUEST"); return
			var token := _new_token()
			var hash := token.sha256_text()
			var issued: Dictionary = store._invoke({"operation": "session_issue", "account_id": params.account_id, "token_hash": hash, "ttl_ms": int(params.ttl_ms), "now_ms": _utc()})
			if issued.has("error"): _account_reply(client, request_id, false, str(issued.error)); return
			sessions[hash] = {"token_hash": hash, "account_id": params.account_id, "issued_at_ms": issued.issued_at_ms, "expires_at_ms": issued.expires_at_ms, "revoked": false}
			_account_reply(client, request_id, true, "", {"token": token, "account_id": params.account_id, "expires_at_ms": issued.expires_at_ms})
		"revoke":
			var by_token: bool = params.has("token")
			if not Schema.exact_keys(params, ["token"]) and not Schema.exact_keys(params, ["account_id"]):
				_account_reply(client, request_id, false, "INVALID_ACCOUNT_REQUEST"); return
			var request := {"operation": "session_revoke", "now_ms": _utc()}
			if by_token:
				if not params.token is String: _account_reply(client, request_id, false, "INVALID_ACCOUNT_REQUEST"); return
				request.token_hash = String(params.token).sha256_text()
			else:
				if not Schema.is_uuid(str(params.account_id)): _account_reply(client, request_id, false, "INVALID_ACCOUNT_REQUEST"); return
				request.account_id = params.account_id
			var revoked: Dictionary = store._invoke(request)
			if revoked.has("error"): _account_reply(client, request_id, false, str(revoked.error)); return
			for hash in sessions:
				if (by_token and hash == request.token_hash) or (not by_token and sessions[hash].account_id == params.account_id): sessions[hash].revoked = true
			_account_reply(client, request_id, true, "", {"revoked": revoked.revoked})
		"list":
			_account_reply(client, request_id, true, "", {"accounts": accounts.values(), "sessions": sessions.values()})
		"audit":
			var limit := int(params.get("limit", 50))
			var rows: Dictionary = store._invoke({"operation": "audit_list", "limit": limit})
			if rows.has("error"): _account_reply(client, request_id, false, str(rows.error)); return
			_account_reply(client, request_id, true, "", {"audit": rows.audit})
		_:
			_account_reply(client, request_id, false, "UNSUPPORTED_ACCOUNT_ACTION")

func _account_reply(client: Dictionary, request_id: String, ok: bool, code: String, data: Dictionary = {}) -> void:
	_send(client, Wire.packet("account_result", {"request_id": request_id, "ok": ok, "code": code, "data": data}))

func _process(delta: float) -> void:
	if ready_at == 0: return
	if listener.is_connection_available():
		var stream := listener.take_connection()
		if clients.size() < 8:
			var peer := WebSocketPeer.new()
			peer.inbound_buffer_size = Wire.MAX_PACKET
			peer.outbound_buffer_size = 8 * 1024 * 1024
			peer.max_queued_packets = 128
			peer.accept_stream(stream)
			clients.append({"peer": peer, "opened": Time.get_ticks_msec(), "principal": {}, "avatar": null, "seq": 0, "source_seq": 0, "state": {}, "centre": [], "radius": 96.0, "messages": 0, "window": Time.get_ticks_msec()})
	for client in clients.duplicate():
		client.peer.poll()
		if client.peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_disconnect(client); continue
		if Time.get_ticks_msec() - int(client.window) >= 1000: client.messages = 0; client.window = Time.get_ticks_msec()
		if client.principal.is_empty() and Time.get_ticks_msec() - int(client.opened) > 5000: client.peer.close(1008, "AUTH_TIMEOUT")
		if not client.principal.is_empty() and (_utc() >= int(client.principal.expires_at_ms) or Time.get_ticks_msec() - int(client.opened) > 28800000): client.peer.close(1008, "SESSION_EXPIRED")
		if not client.principal.is_empty() and not _session_alive(client.principal): client.peer.close(1008, "SESSION_REVOKED")
		var count := 0
		while client.peer.get_available_packet_count() > 0 and count < 16:
			count += 1; client.messages += 1
			if client.messages > 100: client.peer.close(1008, "RATE_LIMIT"); break
			var packet: Variant = Wire.decode(client.peer.get_packet())
			if not packet is Dictionary or packet.get("fp_version") != Wire.VERSION or not packet.get("type") is String:
				client.peer.close(1008, "INVALID_PACKET"); break
			_receive(client, packet)
	if worker != null and not worker.is_alive(): _finish_commit()
	if active.is_empty() and not queued.is_empty(): _execute(queued.pop_front())
	accumulator += delta
	if accumulator >= 0.05:
		accumulator = fmod(accumulator, 0.05)
		for client in clients:
			if not client.principal.is_empty(): _sync(client)

func _physics_process(_delta: float) -> void:
	tick += 1

func _disconnect(client: Dictionary) -> void:
	if is_instance_valid(client.avatar): client.avatar.queue_free()
	clients.erase(client)

func _send(client: Dictionary, value: Dictionary) -> void:
	if client.peer.get_ready_state() != WebSocketPeer.STATE_OPEN: return
	if client.peer.get_current_outbound_buffered_amount() > 4 * 1024 * 1024: client.peer.close(1013, "SLOW_CLIENT"); return
	client.peer.send_text(Wire.canonical(value))

func _utc() -> int:
	return int(Time.get_unix_time_from_system() * 1000)

func _receive(client: Dictionary, packet: Dictionary) -> void:
	if client.principal.is_empty():
		if packet.type != "hello" or not Schema.exact_keys(packet, ["fp_version", "type", "token"]) or not packet.token is String:
			client.peer.close(1008, "AUTH_REQUIRED"); return
		client.principal = _principal_for(packet.token)
		if client.principal.is_empty(): client.peer.close(1008, "AUTH_FAILED"); return
		for other in clients:
			if other != client and other.principal.get("id") == client.principal.id: other.peer.close(1008, "SESSION_REPLACED"); _disconnect(other); break
		var avatar = Avatar.new()
		add_child(avatar)
		var spawn: Array = service.model.snapshot().region.spawn.duplicate()
		var slot := 0
		for configured in config.principals:
			if configured.id == client.principal.id: break
			slot += 1
		spawn[0] += slot * 1.0
		avatar.spawn = View.to_engine(spawn); avatar.position = avatar.spawn
		client.avatar = avatar
		_send(client, Wire.packet("welcome", {"world_id": Schema.REGION_ID, "region_id": Schema.REGION_ID, "world_epoch": epoch, "principal_id": client.principal.id, "actor_id": client.principal.actor, "role": client.principal.role, "avatar_id": client.principal.id, "send_hz": 20, "physics_hz": 60}))
		_sync(client, true); return
	match packet.type:
		"ack":
			if Schema.exact_keys(packet, ["fp_version", "type", "seq"]) and _integer(packet.seq, 0, int(client.seq)):
				client.ack = maxi(int(client.get("ack", 0)), int(packet.seq))
		"resync":
			if Schema.exact_keys(packet, ["fp_version", "type"]): _sync(client, true)
		"interest":
			if Schema.exact_keys(packet, ["fp_version", "type", "centre", "radius"]) and Schema.vector(packet.centre, 3, -64, 256) and Schema.number(packet.radius, 8, 128):
				client.centre = packet.centre; client.radius = float(packet.radius); _sync(client)
		"input":
			if not Schema.exact_keys(packet, ["fp_version", "type", "sequence", "axis", "yaw", "jump"]) or not Schema.vector(packet.axis, 2, -1, 1) or not Schema.number(packet.yaw, -100, 100) or not packet.jump is bool or not _integer(packet.sequence, 1, 1000000000): return
			if packet.sequence <= client.avatar.input_seq: return
			client.avatar.input_seq = int(packet.sequence); client.avatar.input_at = Time.get_ticks_msec()
			client.avatar.controls = Vector2(packet.axis[0], packet.axis[1]).limit_length(); client.avatar.yaw = packet.yaw; client.avatar.jumping = packet.jump
		"query_result":
			if not Schema.exact_keys(packet, ["fp_version", "type", "request_id"]) or not Schema.is_uuid(packet.request_id): return
			var receipt: Dictionary = receipts.get(packet.request_id, failures.get(packet.request_id, {}))
			if receipt.get("principal_id") == client.principal.id: _send(client, receipt.result)
			else: _reject(client, packet.request_id, "RESULT_UNKNOWN")
		"account": _account(client, packet)
		"command": _command(client, packet)
		_: _reject(client, "", "UNSUPPORTED_PACKET")

func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return Schema.number(value, minimum, maximum) and value == floor(float(value))

func _reject(client: Dictionary, id: String, code: String) -> void:
	_send(client, Wire.packet("result", {"request_id": id, "ok": false, "code": code, "revision": service.model.revision(), "world_epoch": epoch}))

func _command(client: Dictionary, command: Dictionary) -> void:
	var fields := ["fp_version", "type", "world_id", "region_id", "request_id", "trace_id", "world_epoch", "origin", "source_seq", "expected_revision", "expires_at_ms", "operation", "payload"]
	if not Schema.exact_keys(command, fields) or not Schema.is_uuid(command.request_id) or not Schema.is_uuid(command.trace_id) or not command.payload is Dictionary or command.origin not in ["desktop", "web", "test"] or not _integer(command.source_seq, 1, 1000000000) or not _integer(command.expected_revision, 0, 1000000000) or not _integer(command.expires_at_ms, 0, 9007199254740991):
		_reject(client, "", "INVALID_COMMAND"); return
	var fingerprint := Wire.digest(command)
	var previous: Dictionary = receipts.get(command.request_id, failures.get(command.request_id, {}))
	if not previous.is_empty():
		if previous.principal_id != client.principal.id or previous.fingerprint != fingerprint: _reject(client, command.request_id, "REQUEST_REUSED")
		else: _send(client, previous.result)
		return
	for job in queued + ([] if active.is_empty() else [active]):
		if job.command.request_id == command.request_id:
			if job.principal.id != client.principal.id or job.fingerprint != fingerprint: _reject(client, command.request_id, "REQUEST_REUSED")
			else: _send(client, Wire.packet("pending", {"request_id": command.request_id}))
			return
	if command.world_epoch != epoch: _reject(client, command.request_id, "EPOCH_MISMATCH"); return
	if command.world_id != Schema.REGION_ID or command.region_id != Schema.REGION_ID: _reject(client, command.request_id, "WRONG_REGION"); return
	if command.source_seq <= client.source_seq: _reject(client, command.request_id, "SOURCE_SEQUENCE"); return
	client.source_seq = command.source_seq
	if command.expires_at_ms < _utc() or command.expires_at_ms > _utc() + 60000: _reject(client, command.request_id, "EXPIRED_COMMAND"); return
	if command.operation not in Wire.MUTATIONS: _reject(client, command.request_id, "UNSUPPORTED_OPERATION"); return
	if client.principal.role == "observer" or not _authorized(client.principal, command): _reject(client, command.request_id, "PERMISSION_DENIED"); return
	if frozen or receipts.size() >= 10000 or failures.size() >= 10000: _reject(client, command.request_id, "MAINTENANCE_REQUIRED"); return
	if queued.size() >= 64: _reject(client, command.request_id, "SERVER_BUSY"); return
	queued.append({"command": command.duplicate(true), "principal": client.principal.duplicate(true), "fingerprint": fingerprint})
	_send(client, Wire.packet("pending", {"request_id": command.request_id}))

func _visible(principal: Dictionary, id: String) -> bool:
	return not config.get("private_objects", {}).has(id) or principal.id in config.private_objects[id]

func _authorized(principal: Dictionary, command: Dictionary) -> bool:
	var world: Dictionary = service.model.snapshot()
	var payload: Dictionary = command.payload
	var targets: Array = payload.get("object_ids", []).duplicate() if payload.get("object_ids", []) is Array else []
	if payload.has("root_id"): targets.append(payload.root_id)
	if payload.has("id"): targets.append(payload.id)
	for id in targets:
		if not _visible(principal, str(id)): return false
		for group in world.groups:
			if group.id == id:
				for item in world.objects:
					if item.group_id == id and not _visible(principal, item.id): return false
	if command.operation == "CreateObject" and payload.get("object") is Dictionary:
		var asset_id: String = str(payload.object.get("asset_id", ""))
		if not _asset_allowed(principal, asset_id, world): return false
	if command.operation == "UpdateObject" and payload.get("patch") is Dictionary and payload.patch.has("asset_id"):
		if not _asset_allowed(principal, str(payload.patch.asset_id), world): return false
	return true

func _execute(job: Dictionary) -> void:
	var command: Dictionary = job.command
	var candidate = Service.new()
	candidate.model.replace(service.model.snapshot()); candidate.actor = job.principal.actor
	var operation: String = command.operation
	var payload: Dictionary = command.payload.duplicate(true)
	var temporary := ""
	var outcome: Dictionary
	if command.expires_at_ms < _utc(): outcome = {"ok": false, "errors": [{"code": "EXPIRED_COMMAND"}]}
	elif operation == "UploadAsset":
		if not Schema.exact_keys(payload, ["bytes", "name", "license", "attribution"]) or not payload.bytes is String or payload.bytes.length() > 2796204:
			outcome = {"ok": false, "errors": [{"code": "INVALID_ASSET"}]}
		else:
			var bytes := Marshalls.base64_to_raw(payload.bytes)
			if bytes.size() > 2097152 or Marshalls.raw_to_base64(bytes) != payload.bytes: outcome = {"ok": false, "errors": [{"code": "INVALID_ASSET"}]}
			else:
				temporary = config.storage.path_join("upload-" + command.request_id + ".glb")
				var file := FileAccess.open(temporary, FileAccess.WRITE)
				file.store_buffer(bytes); file.close()
				payload.erase("bytes"); payload.path = temporary; operation = "ImportGlb"
	if outcome.is_empty():
		outcome = candidate.dispatch({"api_version": 1, "request_id": command.request_id, "operation": operation, "expected_revision": command.expected_revision, "payload": payload})
	if not temporary.is_empty(): DirAccess.remove_absolute(temporary)
	var result := Wire.packet("result", {"request_id": command.request_id, "trace_id": command.trace_id, "ok": outcome.ok, "code": "" if outcome.ok else outcome.errors[0].code, "revision": candidate.model.revision(), "world_epoch": epoch, "payload": outcome.get("payload", {})})
	job.receipt = {"request_id": command.request_id, "principal_id": job.principal.id, "fingerprint": job.fingerprint, "result": result}
	if not outcome.ok:
		failures[command.request_id] = job.receipt; _reply(job); return
	job.world = candidate.model.snapshot()
	active = job
	worker = Thread.new()
	worker_job = StorageJob.new()
	var error := worker.start(worker_job.commit.bind(config.duplicate(true), job.world.duplicate(true), commit_revision, job.receipt.duplicate(true)))
	if error != OK:
		worker = null; worker_job = null
		active.receipt.result.ok = false; active.receipt.result.code = "STORAGE_WORKER_UNAVAILABLE"
		failures[command.request_id] = active.receipt; _reply(active); active = {}

func _finish_commit() -> void:
	var returned: Variant = worker.wait_to_finish(); worker = null; worker_job = null
	var result: Dictionary = returned if returned is Dictionary else {"error": "STORAGE_OUTCOME_UNKNOWN", "frozen": true}
	if result.has("error"):
		frozen = result.get("frozen", false)
		active.receipt.result.ok = false; active.receipt.result.code = result.error; active.receipt.result.revision = service.model.revision()
		failures[active.command.request_id] = active.receipt
	else:
		commit_revision = int(result.commit_revision)
		service.model.replace(active.world)
		var world: Dictionary = service.model.snapshot()
		view.sync_terrain(world.terrain, world.region.size); view.sync_objects(world.objects, world.groups, world.assets)
		receipts[active.command.request_id] = active.receipt
		_publish_assets()
	_reply(active); active = {}

func _reply(job: Dictionary) -> void:
	for client in clients:
		if client.principal.get("id") == job.principal.id: _send(client, job.receipt.result)

func _asset_allowed(principal: Dictionary, asset_id: String, world: Dictionary) -> bool:
	var referenced := false
	for item in world.objects:
		if item.asset_id == asset_id:
			referenced = true
			if _visible(principal, item.id):
				if item.group_id.is_empty(): return true
				var hidden_member: bool = world.objects.any(func(member): return member.group_id == item.group_id and not _visible(principal, member.id))
				if not hidden_member: return true
	return not referenced and principal.role != "observer"

func _publish_assets() -> void:
	var catalog := {}
	var world: Dictionary = service.model.snapshot()
	for asset in world.assets:
		if asset.kind != "mesh": continue
		var allowed: Array = []
		for account in accounts.values():
			if account.disabled: continue
			if _asset_allowed({"id": account.id, "role": account.role}, asset.id, world): allowed.append(account.id)
		catalog[asset.sha256] = {"principals": allowed, "bytes": Marshalls.base64_to_raw(asset.glb).size()}
	_write(config.storage.path_join("asset-catalog.json"), catalog)

func _projection(client: Dictionary) -> Dictionary:
	var world: Dictionary = service.model.snapshot()
	var result := {"meta": {}, "objects": {}, "groups": {}, "assets": {}, "avatars": {}}
	for key in ["schema_version", "revision", "region", "terrain", "environment"]: result.meta[key] = world[key]
	var centre: Vector3 = client.avatar.position if client.centre.is_empty() else View.to_engine(client.centre)
	var visible_groups := {}
	for item in world.objects:
		if not _visible(client.principal, item.id): continue
		var resolved: Dictionary = Transforms.resolve(item, world.groups)
		var radius: float = float(client.radius) + (16.0 if client.state.get("objects", {}).has(item.id) else 0.0)
		if centre.distance_to(View.to_engine(resolved.position)) <= radius + View.to_engine(resolved.size).length() * 0.5:
			if item.group_id.is_empty(): result.objects[item.id] = item
			else: visible_groups[item.group_id] = true
	for group in world.groups:
		if not visible_groups.has(group.id): continue
		var members: Array = world.objects.filter(func(item): return item.group_id == group.id)
		if members.any(func(item): return not _visible(client.principal, item.id)): continue
		result.groups[group.id] = group
		for item in members: result.objects[item.id] = item
	var asset_ids := {}
	for item in result.objects.values(): asset_ids[item.asset_id] = true
	for asset in world.assets:
		if asset.kind == "mesh" and not asset_ids.has(asset.id): continue
		var record: Dictionary = asset.duplicate(true)
		if record.has("glb"): record.bytes = Marshalls.base64_to_raw(record.glb).size(); record.erase("glb")
		result.assets[asset.id] = record
	for other in clients:
		if other.principal.is_empty() or not is_instance_valid(other.avatar): continue
		if other == client or centre.distance_to(other.avatar.position) <= float(client.radius) + 16:
			result.avatars[other.principal.id] = other.avatar.record(other.principal.id, other.principal.name, tick)
	return result

func _sync(client: Dictionary, full: bool = false) -> void:
	# Bound unacknowledged state while the browser compiles a frame or is hidden.
	# The next update diffs against the last sent state, retaining every deletion.
	if not full and int(client.seq) - int(client.get("ack", 0)) >= 32: return
	var state := _projection(client)
	var delta := Wire.diff(client.state, state)
	if not full and not client.state.is_empty() and not Wire.changed(delta): return
	client.seq += 1
	client.hashes = Wire.projection_hashes(state, client.get("hashes", {}), delta)
	var data := {"world_epoch": epoch, "seq": client.seq, "tick": tick, "revision": service.model.revision(), "state_hash": Wire.digest(client.hashes)}
	if full or client.state.is_empty(): data.state = state; _send(client, Wire.packet("snapshot", data))
	else: data.delta = delta; _send(client, Wire.packet("delta", data))
	client.state = state

func _exit_tree() -> void:
	listener.stop()
	if worker != null: worker.wait_to_finish()
