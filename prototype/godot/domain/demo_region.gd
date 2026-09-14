extends RefCounted
## New-install demonstration only. Existing snapshots are never replaced by this scene.
const Groups = preload("res://domain/group_commands.gd")
const Schema = preload("res://domain/world_schema.gd")

static func create() -> Dictionary:
	var world := Schema.seed()
	world.environment.water_enabled = true
	world.objects.clear()
	for y in range(65):
		for x in range(65):
			var east := x * 4.0
			var north := y * 4.0
			# A lake east of the level building site, with a gradual shoreline.
			var lake := 5.0 * smoothstep(163.0, 188.0, east) * (1.0 - smoothstep(208.0, 240.0, north))
			world.terrain.heights[y * 65 + x] = snappedf(float(world.terrain.heights[y * 65 + x]) - lake, 0.001)
	var objects: Array = world.objects
	# Street, paved approach, courtyard and a 0.2 m accessible floor slab.
	_add(objects, "步行道路", [128, 108, 0.11], [7, 32, 0.22], "#747870", "concrete")
	_add(objects, "入口广场", [128, 125, 0.11], [28, 12, 0.22], "#B3B1A3", "concrete")
	_add(objects, "展馆地板", [128, 140, 0.11], [18, 12, 0.22], "#CCC4AB", "wood")
	_add(objects, "展馆西墙", [119.15, 140, 2.3], [0.3, 12, 4.2], "#AE8066", "brick")
	_add(objects, "展馆东墙", [136.85, 140, 2.3], [0.3, 12, 4.2], "#AE8066", "brick")
	_add(objects, "展馆北墙", [128, 145.85, 2.3], [18, 0.3, 4.2], "#B38669", "brick")
	for side in [-1, 1]:
		_add(objects, "入口墙 " + str(side), [128 + side * 5.15, 134.15, 2.3], [7.7, 0.3, 4.2], "#C5BAA2", "concrete")
	_add(objects, "入口门楣", [128, 134.15, 3.9], [2.6, 0.3, 1.0], "#C5BAA2", "concrete")
	objects.append(Schema.primitive("door", "展馆伸缩门", [128, 134.15, 1.81], [2.6, 0.3, 3.2], "#6E9898", "metal"))
	_add(objects, "展馆屋顶", [128, 140, 4.6], [19, 13, 0.4], "#626F72", "metal")
	_add(objects, "门前檐廊", [128, 132.3, 3.65], [9, 4, 0.25], "#897C66", "wood")
	for east in [123.8, 132.2]:
		objects.append(Schema.primitive("cylinder", "檐廊立柱", [east, 130.5, 1.85], [0.28, 0.28, 3.3], "#D3CCB9", "concrete"))
	_add(objects, "室内展桌", [128, 142, 0.95], [4, 1.4, 1.4], "#B39872", "wood")
	objects.append(Schema.primitive("sphere", "室内展品", [128, 142, 2.15], [1, 1, 1], "#DAB46F", "metal"))
	objects.append(Schema.primitive("lamp", "室内照明", [134.5, 143, 1.7], [0.7, 0.7, 3], "#4C5756", "metal"))
	for north in [109, 120, 131]:
		for east in [121.8, 134.2]:
			objects.append(Schema.primitive("lamp", "步道路灯", [east, north, 2.25], [0.7, 0.7, 4.2], "#485650", "metal"))
	for east in [115, 142]:
		_add(objects, "户外长凳", [east, 125, 0.62], [3.6, 1.0, 0.8], "#AF8B5C", "wood")
		_add(objects, "长凳靠背", [east, 125.5, 1.08], [3.6, 0.2, 1.0], "#AF8B5C", "wood")
	# Tree trunks participate in collision; foliage is decorative and selectable via the trunk.
	for index in range(24):
		var east := 99.0 + float(index % 4) * 18.0
		var north := 89.0 + float(index / 4) * 14.0
		if east > 110 and east < 143 and north > 102 and north < 155:
			continue
		var sample := int(round(north / 4.0)) * 65 + int(round(east / 4.0))
		var height := 6.0 + float(index % 3)
		objects.append(Schema.primitive("tree", "庭院乔木 %02d" % index, [east, north, float(world.terrain.heights[sample]) + height / 2.0], [4.4, 4.4, height], "#567746"))
	var members: Array = []
	for item in objects.slice(2, 17):
		members.append(item.id)
	Groups.apply(world, "GroupObjects", {"id": Schema.uuid(), "name": "展馆建筑", "root_id": objects[2].id, "object_ids": members}, Schema.OWNER)
	return world

static func _add(objects: Array, name: String, position: Array, size: Array, color: String, material: String) -> void:
	objects.append(Schema.primitive("box", name, position, size, color, material))
