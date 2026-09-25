extends Node
signal changed
const Assets = preload("res://adapters/mesh_assets.gd")
const Schema = preload("res://domain/world_schema.gd")
var required: Dictionary = {}
var cache: Dictionary = {}
var attempts: Dictionary = {}
var error := ""
var base_url := ""
var token := ""
var certificate: X509Certificate
var request: HTTPRequest
var current: Dictionary = {}
var retry_at := 0
var received_bytes := 0

func reset() -> void:
	if request != null: request.cancel_request(); request.queue_free(); request = null
	required.clear(); cache.clear(); attempts.clear(); current.clear(); token = ""; error = ""

func set_required(records: Dictionary) -> void:
	required = records.duplicate(true)
	# Retain only the current interest set; the world catalog is capped at 64 imports.
	for id in cache.keys():
		if not required.has(id): cache.erase(id)
	for id in attempts.keys():
		if not required.has(id): attempts.erase(id)

func ready() -> bool:
	for asset in required.values():
		if asset.kind == "mesh" and not cache.has(asset.id): return false
	return true

func records() -> Array:
	var result: Array = []
	for kind in Schema.KINDS:
		var id := Schema.asset_id(kind)
		if required.has(id): result.append(required[id].duplicate(true))
	for asset in required.values():
		if asset.kind == "mesh":
			if cache.has(asset.id): result.append(cache[asset.id].duplicate(true))
	return result

func retry() -> void:
	attempts.clear(); error = ""; retry_at = 0

func _process(_delta: float) -> void:
	if token.is_empty() or request != null or Time.get_ticks_msec() < retry_at: return
	for asset in required.values():
		if asset.kind != "mesh" or cache.has(asset.id) or attempts.get(asset.id, 0) >= 3: continue
		current = asset.duplicate(true)
		attempts[asset.id] = attempts.get(asset.id, 0) + 1
		request = HTTPRequest.new(); request.timeout = 8; request.body_size_limit = 2097152
		add_child(request)
		if certificate != null and not OS.has_feature("web"): request.set_tls_options(TLSOptions.client(certificate))
		request.request_completed.connect(_completed)
		var code := request.request(base_url + "/assets/" + asset.sha256 + ".glb", PackedStringArray(["Authorization: Bearer " + token]))
		if code != OK: _completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
		return

func _completed(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	request.queue_free(); request = null
	var record: Dictionary = current.duplicate(true)
	var valid: bool = result == HTTPRequest.RESULT_SUCCESS and status == 200 and body.size() == int(record.bytes) and Assets.sha256(body) == record.sha256
	if valid:
		record.erase("bytes"); record.glb = Marshalls.raw_to_base64(body)
		var checked := Assets.read(record)
		valid = not checked.has("error")
	if valid and required.has(record.id): cache[record.id] = record; received_bytes += body.size(); error = ""
	elif not valid: error = "Asset unavailable or invalid: " + str(status) + " (" + str(attempts.get(record.id, 0)) + "/3)"; retry_at = Time.get_ticks_msec() + int(attempts.get(record.id, 1)) * 500
	current.clear()
	changed.emit()
