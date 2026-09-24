extends RefCounted
const Schema = preload("res://domain/world_schema.gd")
const Service = preload("res://domain/world_service.gd")
const T = preload("res://domain/world_transforms.gd")
const Reader = preload("res://adapters/glb_reader.gd")
const Assets = preload("res://adapters/mesh_assets.gd")
const MeshView = preload("res://adapters/mesh_view.gd")
const View = preload("res://adapters/world_view.gd")
const Avatar = preload("res://client/avatar.gd")

static func import_payload(name: String) -> Dictionary:
	return {"path": "res://../fixtures/meshes/" + name + ".glb", "name": name, "license": "CC0-1.0", "attribution": "Region Lab contributors"}

func run(suite: SceneTree) -> void:
	var service = Service.new(suite.output_dir + "/v31-world.json")
	var original: Dictionary = service.model.snapshot()
	var root: Dictionary = original.objects[1]
	var child: Dictionary = original.objects[2]
	var id := Schema.uuid()
	var command := {"id": id, "name": "Test assembly", "root_id": root.id, "object_ids": [root.id, child.id]}
	suite.check(service.request("GroupObjects", command).ok, "group command links two existing objects")
	suite.check(T.vec(service.model.object(child.id).position).distance_to(T.vec(child.position)) < 0.00001 and service.model.snapshot().objects[1].position == [0.0, 0.0, 0.0], "link preserves world transform and places root at local origin")
	var before: Dictionary = service.model.snapshot()
	for request in [["GroupObjects", command], ["DeleteObject", {"id": root.id}], ["UpdateObject", {"id": root.id, "patch": {"position": [5, 5, 5]}}], ["UpdateGroup", {"id": id, "patch": {"scale": 0}}], ["UpdateGroup", {"id": id, "patch": {"position": [0, 0, 0]}}], ["UpdateGroup", {"id": id, "patch": {"rotation": [0, 0, 0, 0]}}]]:
		suite.check(not service.request(request[0], request[1]).ok and service.model.snapshot() == before, "invalid group mutation is atomic: " + request[0] + str(request[1].get("patch", "")))
	service.actor = Schema.uuid()
	suite.check(not service.request("DeleteGroup", {"id": id}).ok, "group mutation enforces ownership")
	service.actor = Schema.OWNER
	var q := Quaternion(Vector3(0, 0, 1), PI / 2)
	suite.check(service.request("UpdateGroup", {"id": id, "patch": {"position": [100, 100, 8], "rotation": T.rotation(q), "scale": 1.5}}).ok, "group accepts translation rotation and uniform scale")
	var expected := Vector3(100, 100, 8) + q * (T.vec(child.position) - T.vec(root.position)) * 1.5
	suite.check(T.vec(service.model.object(child.id).position).distance_to(expected) < 0.00002, "child world transform composes group frame in portable axes")
	var moved: Dictionary = service.model.snapshot()
	suite.check(service.request("Undo").ok and service.request("Redo").ok and suite._same_data(service.model.snapshot().groups, moved.groups), "group transform participates in undo and redo")
	var changed: Dictionary = service.model.object(child.id)
	changed.position[2] += 1.0
	suite.check(service.request("UpdateObject", {"id": child.id, "patch": {"position": changed.position}}).ok and T.vec(service.model.object(child.id).position).distance_to(T.vec(changed.position)) < 0.00002, "child editor uses world coordinates while storing local coordinates")
	var copy: Dictionary = service.request("DuplicateGroup", {"id": id, "offset": [25, 0, 0]})
	suite.check(copy.ok and copy.payload.root_id != root.id and service.model.snapshot().objects.size() == 10, "duplicate group creates independent group and member identities")
	var resolved: Dictionary = service.model.object(child.id)
	suite.check(service.request("UngroupObjects", {"id": id}).ok and service.model.object(child.id).group_id == "" and T.vec(service.model.object(child.id).position).distance_to(T.vec(resolved.position)) < 0.00002, "ungroup preserves member world pose")
	suite.check(service.request("DeleteGroup", {"id": copy.payload.id}).ok and service.model.snapshot().objects.size() == 8, "delete group removes exactly its members")
	var duplicate := command.duplicate(true)
	duplicate.object_ids = [root.id, root.id]
	suite.check(not service.request("GroupObjects", duplicate).ok, "duplicate member IDs are rejected")
	var bad: Dictionary = service.model.snapshot()
	bad.objects[0].group_id = Schema.uuid()
	suite.check(not Schema.validate(bad).is_empty(), "missing group references are rejected")
	for name in ["pavilion", "bench", "tree"]:
		var result: Dictionary = service.request("ImportGlb", import_payload(name))
		suite.check(result.ok, "original static GLB imports: " + name + str(result.errors))
		if not result.ok:
			return
	var asset: Dictionary = service.model.snapshot().assets[6]
	var geometry := Assets.read(asset)
	suite.check(geometry.collision_mode == "proxy" and geometry.surfaces.size() == 8 and geometry.collision.size() == 8, "pavilion uses separate visible and doorway-preserving collision surfaces")
	var bench := Assets.read(service.model.snapshot().assets[7])
	suite.check(bench.surfaces[0].material.albedo.mime == "image/png", "bench imports embedded PNG base color texture")
	before = service.model.snapshot()
	suite.check(service.request("ImportGlb", import_payload("pavilion")).payload.reused and service.model.snapshot() == before, "identical GLB content reuses the immutable asset without revision change")
	bad = asset.duplicate(true)
	bad.glb = "AAAA"
	suite.check(Assets.read(bad).has("error"), "embedded file checksum detects altered asset bytes")
	bad = asset.duplicate(true)
	bad.bounds[0] += 1
	suite.check(Assets.read(bad).has("error"), "stored asset bounds must agree with parsed content")
	bad = asset.duplicate(true)
	bad.uri = "C:/outside.glb"
	suite.check(Assets.read(bad).has("error"), "snapshot mesh assets cannot substitute external paths")
	var item := Schema.box("Imported building", [80, 80, 1.9], asset.bounds, "#FFFFFF")
	item.asset_id = asset.id
	suite.check(service.request("CreateObject", {"object": item}).ok, "registered mesh asset creates a normal persistent scene object")
	suite.check(not service.request("RemoveAsset", {"id": asset.id}).ok, "in-use mesh asset cannot be removed")
	suite.check(service.request("GroupObjects", command).ok, "restored world poses can be linked again")
	suite.check(service.request("SaveRegion").ok, "group-capable world with embedded meshes saves")
	var moved_path: String = suite.output_dir + "/relocated/portable.json"
	DirAccess.make_dir_recursive_absolute(moved_path.get_base_dir())
	DirAccess.copy_absolute(service.repository.path, moved_path)
	Assets._cache.clear()
	var reader = Service.new(moved_path)
	suite.check(reader.request("LoadRegion").ok and suite._same_data(reader.model.snapshot().assets, service.model.snapshot().assets) and reader.model.object(item.id).asset_id == asset.id and reader.model.snapshot().groups.size() == 1, "relocated snapshot restores geometry from embedded bytes with empty cache")
	suite.check(service.request("RemoveAsset", {"id": service.model.snapshot().assets[8].id}).ok and service.request("Undo").ok, "unused asset removal can be undone")
	_invalid_glb(suite)
	_realistic_glb(suite)
	_gltf_source(suite)
	_obj_source(suite)
	await _physics(suite, item, asset)
	await _group_physics(suite)
	var legacy: Variant = JSON.parse_string(JSON.parse_string(FileAccess.get_file_as_string("res://../fixtures/v3-region.snapshot.json")).world_json)
	var upgraded := Schema.upgrade(legacy)
	suite.check(not upgraded.has("error") and upgraded.migrated and upgraded.world.groups.is_empty() and upgraded.world.objects[0].group_id == "" and suite._same_data(upgraded.world.environment, legacy.environment), "V3 format-2 snapshot migrates without changing environment or identities")

func _invalid_glb(suite: SceneTree) -> void:
	var bytes := FileAccess.get_file_as_bytes("res://../fixtures/meshes/bench.glb")
	var length := int(bytes.decode_u32(12))
	var doc: Dictionary = JSON.parse_string(bytes.slice(20, 20 + length).get_string_from_utf8())
	var bin := bytes.slice(28 + length)
	var variants: Array = []
	var bad := doc.duplicate(true); bad.buffers[0].uri = "outside.bin"; variants.append(bad)
	bad = doc.duplicate(true); bad.nodes[0].children = [0]; variants.append(bad)
	bad = doc.duplicate(true); bad.accessors[0].count = 60001; variants.append(bad)
	bad = doc.duplicate(true); bad.bufferViews[1].byteOffset = 999999; variants.append(bad)
	bad = doc.duplicate(true); bad.extensionsUsed = ["KHR_draco_mesh_compression"]; variants.append(bad)
	bad = doc.duplicate(true); bad.animations = [{}]; variants.append(bad)
	bad = doc.duplicate(true); bad.nodes[0].scale = [-1, 1, 1]; variants.append(bad)
	bad = doc.duplicate(true); bad.materials[0].alphaMode = "BLEND"; variants.append(bad)
	# Every material used by this bench is either metal (1) or wood (3).
	bad.materials[1].alphaMode = "BLEND"
	bad = doc.duplicate(true); bad.images[0].uri = "texture.png"; variants.append(bad)
	bad = doc.duplicate(true); bad.images[0].mimeType = 5; variants.append(bad)
	bad = doc.duplicate(true); bad.meshes[0].primitives[0].attributes.JOINTS_0 = 0; variants.append(bad)
	for i in range(variants.size()):
		suite.check(Reader.new().parse(_glb(variants[i], bin)).has("error"), "unsupported or malformed GLB rejected " + str(i))
	var invalid := bytes.duplicate(); invalid.encode_u32(8, 20)
	suite.check(Reader.new().parse(invalid).has("error"), "GLB declared length must match file")
	var nan_bin := bin.duplicate()
	nan_bin.encode_float(int(doc.bufferViews[int(doc.accessors[0].bufferView)].byteOffset), NAN)
	suite.check(Reader.new().parse(_glb(doc, nan_bin)).has("error"), "GLB non-finite vertex data rejected")

func _realistic_glb(suite: SceneTree) -> void:
	var source := "res://../fixtures/meshes/polyhaven-marble-bust-01.glb"
	var result := Assets.import_file({"path": source, "name": "Marble Bust 01", "license": "CC0-1.0", "attribution": "Rico Cilliers / Poly Haven; three.ws 1K GLB conversion"})
	suite.check(not result.has("error"), "CC0 realistic asset imports with JPEG PBR textures and degenerate triangles")
	if result.has("error"): return
	var record: Dictionary = result.asset
	var geometry := Assets.read(record)
	suite.check(not geometry.has("error") and geometry.triangles > 0 and geometry.triangles < 20000, "real asset survives content-addressed reread inside scene budget")
	if geometry.has("error"): return
	var material: Dictionary = geometry.surfaces[0].material
	suite.check(material.albedo.mime == "image/jpeg" and material.normal.mime == "image/jpeg" and material.metallic_roughness.mime == "image/jpeg", "JPEG base color, normal and packed roughness channels are retained")
	var item := Schema.box("Marble Bust 01", [80, 80, 2], record.bounds, "#FFFFFF")
	item.asset_id = record.id
	var body := StaticBody3D.new()
	var renderer := MeshView.new()
	renderer.cache[record.id] = geometry
	renderer.build(body, item)
	var visual: MeshInstance3D = body.get_child(0)
	var shader: StandardMaterial3D = visual.material_override
	suite.check(shader.albedo_texture != null and shader.normal_texture != null and shader.roughness_texture != null and shader.metallic_texture != null and body.get_child_count() > 1, "real asset builds textured visual and collision shapes")
	body.free()

func _gltf_source(suite: SceneTree) -> void:
	var bytes := FileAccess.get_file_as_bytes("res://../fixtures/meshes/bench.glb")
	var length := int(bytes.decode_u32(12))
	var doc: Dictionary = JSON.parse_string(bytes.slice(20, 20 + length).get_string_from_utf8())
	var binary := bytes.slice(28 + length)
	var image: Dictionary = doc.images[0]
	var view: Dictionary = doc.bufferViews[image.bufferView]
	var texture := binary.slice(int(view.get("byteOffset", 0)), int(view.get("byteOffset", 0)) + int(view.byteLength))
	var directory: String = suite.output_dir + "/gltf-source"
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(directory + "/model.bin", FileAccess.WRITE); file.store_buffer(binary); file.close()
	file = FileAccess.open(directory + "/albedo.png", FileAccess.WRITE); file.store_buffer(texture); file.close()
	doc.buffers[0].uri = "model.bin"
	image.erase("bufferView"); image.erase("mimeType"); image.uri = "albedo.png"
	file = FileAccess.open(directory + "/model.gltf", FileAccess.WRITE); file.store_string(JSON.stringify(doc)); file.close()
	var result := Assets.import_file({"path": directory + "/model.gltf", "name": "glTF bench", "license": "CC0-1.0", "attribution": "Region Lab contributors"})
	suite.check(not result.has("error") and result.asset.glb.begins_with("Z2xURg"), "external-buffer glTF and PNG pack into a portable GLB asset")
	doc.buffers[0].uri = "data:application/octet-stream;base64," + Marshalls.raw_to_base64(binary)
	image.uri = "data:image/png;base64," + Marshalls.raw_to_base64(texture)
	file = FileAccess.open(directory + "/inline.gltf", FileAccess.WRITE); file.store_string(JSON.stringify(doc)); file.close()
	suite.check(not Assets.import_file({"path": directory + "/inline.gltf", "name": "inline bench", "license": "CC0-1.0", "attribution": "Region Lab contributors"}).has("error"), "base64 data URI glTF packs without filesystem dependencies")
	doc.buffers[0].uri = "../outside.bin"
	file = FileAccess.open(directory + "/unsafe.gltf", FileAccess.WRITE); file.store_string(JSON.stringify(doc)); file.close()
	suite.check(Assets.import_file({"path": directory + "/unsafe.gltf", "name": "unsafe", "license": "CC0-1.0", "attribution": "Region Lab contributors"}).has("error"), "glTF dependencies cannot escape the selected directory")

func _obj_source(suite: SceneTree) -> void:
	var directory: String = suite.output_dir + "/obj-source"
	DirAccess.make_dir_recursive_absolute(directory)
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color("749dc1"))
	image.save_png(directory + "/wall.png")
	var file := FileAccess.open(directory + "/model.mtl", FileAccess.WRITE)
	file.store_string("newmtl wall\nKd 1 1 1\nmap_Kd wall.png\n"); file.close()
	file = FileAccess.open(directory + "/model.obj", FileAccess.WRITE)
	file.store_string("mtllib model.mtl\nusemtl wall\nv -1 0 -1\nv 1 0 -1\nv 1 0 1\nv -1 0 1\nv -1 2 -1\nv 1 2 -1\nv 1 2 1\nv -1 2 1\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\nf 1/1 2/2 3/3 4/4\nf 5/1 8/2 7/3 6/4\nf 1/1 5/2 6/3 2/4\nf 2/1 6/2 7/3 3/4\nf 3/1 7/2 8/3 4/4\nf 4/1 8/2 5/3 1/4\n"); file.close()
	var result := Assets.import_file({"path": directory + "/model.obj", "name": "Textured OBJ", "license": "CC0-1.0", "attribution": "Region Lab contributors"})
	suite.check(not result.has("error") and result.get("triangles", 0) == 12, "OBJ quadrilaterals and same-directory MTL texture convert to validated GLB: " + str(result.get("error", "")))
	if not result.has("error"):
		var geometry := Assets.read(result.asset)
		suite.check(not geometry.has("error") and geometry.surfaces[0].material.albedo.mime in ["image/png", "image/jpeg"], "OBJ texture survives embedded asset round trip")
	file = FileAccess.open(directory + "/unsafe.mtl", FileAccess.WRITE)
	file.store_string("newmtl wall\nmap_Kd ../outside.png\n"); file.close()
	file = FileAccess.open(directory + "/unsafe.obj", FileAccess.WRITE)
	file.store_string("mtllib unsafe.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"); file.close()
	suite.check(Assets.import_file({"path": directory + "/unsafe.obj", "name": "Unsafe OBJ", "license": "CC0-1.0", "attribution": "Region Lab contributors"}).has("error"), "OBJ material dependencies cannot escape selected directory")

func _glb(doc: Dictionary, bin: PackedByteArray) -> PackedByteArray:
	var json := JSON.stringify(doc).to_utf8_buffer()
	while json.size() % 4 != 0:
		json.append(32)
	var result := PackedByteArray()
	result.resize(20)
	result.encode_u32(0, 0x46546c67); result.encode_u32(4, 2); result.encode_u32(8, 28 + json.size() + bin.size())
	result.encode_u32(12, json.size()); result.encode_u32(16, 0x4e4f534a)
	result.append_array(json)
	var header := PackedByteArray(); header.resize(8); header.encode_u32(0, bin.size()); header.encode_u32(4, 0x004e4942)
	result.append_array(header); result.append_array(bin)
	return result

func _physics(suite: SceneTree, item: Dictionary, asset: Dictionary) -> void:
	var world := Schema.seed()
	world.terrain.heights.fill(0.0)
	world.objects = [item]
	world.assets.append(asset)
	var view = View.new()
	suite.root.add_child(view)
	view.rebuild(world)
	for i in range(4):
		await suite.physics_frame
	var space: PhysicsDirectSpaceState3D = view.get_world_3d().direct_space_state
	var entry := PhysicsRayQueryParameters3D.create(Vector3(80, 1.5, -74), Vector3(80, 1.5, -81), 2)
	suite.check(space.intersect_ray(entry).is_empty(), "imported collision proxies preserve an open building entrance")
	var wall := PhysicsRayQueryParameters3D.create(Vector3(77, 1.5, -74), Vector3(77, 1.5, -81), 2)
	suite.check(not space.intersect_ray(wall).is_empty(), "imported building walls block native Jolt rays")
	var player = Avatar.new(); suite.root.add_child(player)
	player.reset_spawn(Vector3(80, 0.3, -77))
	player.active = true
	Input.action_press("move_forward")
	for i in range(55):
		await suite.physics_frame
	Input.action_release("move_forward")
	suite.check(player.position.z < -80 and player.position.y >= 0.15, "actual avatar enters GLB interior and stands on imported floor")
	player.free(); view.free()
	await suite.process_frame

func _group_physics(suite: SceneTree) -> void:
	var service = Service.new(suite.output_dir + "/group-physics.json")
	var world := Schema.seed()
	world.terrain.heights.fill(0.0)
	var root := Schema.box("root", [50, 50, 1], [2, 2, 2], "#CCCCCC")
	var door := Schema.primitive("door", "linked door", [54, 50, 1.8], [2.6, 0.3, 3.2], "#668888")
	world.objects = [root, door]
	service.model.replace(world)
	var id := Schema.uuid()
	service.request("GroupObjects", {"id": id, "name": "Door assembly", "root_id": root.id, "object_ids": [root.id, door.id]})
	service.request("UpdateGroup", {"id": id, "patch": {"rotation": T.rotation(Quaternion(Vector3(0, 0, 1), PI / 2)), "scale": 1.25}})
	var view = View.new(); suite.root.add_child(view); view.rebuild(service.model.snapshot())
	for i in range(4):
		await suite.physics_frame
	var ray := PhysicsRayQueryParameters3D.create(Vector3(46, 1.8, -55), Vector3(54, 1.8, -55), 2)
	var hit: Dictionary = view.get_world_3d().direct_space_state.intersect_ray(ray)
	suite.check(not hit.is_empty() and hit.collider == view.bodies[door.id], "rotated and scaled group projects the closed door collider at its composed pose")
	service.request("SetObjectState", {"id": door.id, "active": true})
	world = service.model.snapshot(); view.sync_objects(world.objects, world.groups, world.assets)
	for i in range(4):
		await suite.physics_frame
	suite.check(view.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(), "grouped door retains independent behavior and opens transformed collision passage")
	var copy: Dictionary = service.request("DuplicateGroup", {"id": id, "offset": [15, 0, 0]})
	var copied_door: Dictionary = {}
	for member in service.model.snapshot().objects:
		if member.group_id == copy.payload.id and Schema.kind(member.asset_id) == "door":
			copied_door = member
	suite.check(not copied_door.is_empty() and copied_door.state.active and copied_door.id != door.id, "group duplicate preserves independent door state with a new member ID")
	view.free()
	await suite.process_frame
