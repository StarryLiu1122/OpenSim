extends CharacterBody3D
var active := false
var camera: Camera3D
var spawn := Vector3(128, 2.5, -107)
var yaw := 0.0
var pitch := 0.0

func _ready() -> void:
	collision_layer = 4
	collision_mask = 11
	floor_snap_length = 0.35
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position.y = 0.9
	add_child(collision)
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.32
	capsule.height = 1.8
	mesh.mesh = capsule
	mesh.position.y = 0.9
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("ecf3ed")
	mesh.material_override = material
	add_child(mesh)
	camera = Camera3D.new()
	camera.position.y = 1.65
	camera.fov = 72
	camera.near = 0.08
	camera.far = 650
	add_child(camera)
	position = spawn

func look(relative: Vector2) -> void:
	yaw -= relative.x * 0.003
	pitch = clampf(pitch - relative.y * 0.003, -1.3, 1.3)
	rotation.y = yaw
	camera.rotation.x = pitch

func reset_spawn(value: Vector3) -> void:
	spawn = value
	position = spawn
	velocity = Vector3.ZERO
	yaw = 0
	pitch = 0
	rotation = Vector3.ZERO
	if camera != null:
		camera.rotation = Vector3.ZERO

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= 20.0 * delta
	var move := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if active else Vector2.ZERO
	var direction := basis * Vector3(move.x, 0, move.y)
	var speed := 12.0 if active and Input.is_action_pressed("sprint") else 6.0
	velocity.x = move_toward(velocity.x, direction.x * speed, 35.0 * delta)
	velocity.z = move_toward(velocity.z, direction.z * speed, 35.0 * delta)
	if active and is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = 7.0
	move_and_slide()
	if position.y < -70:
		reset_spawn(spawn)
