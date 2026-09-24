extends CharacterBody3D
const View = preload("res://adapters/world_view.gd")
var controls := Vector2.ZERO
var jumping := false
var sprinting := false
var yaw := 0.0
var input_seq := 0
var input_at := 0
var enabled := true
var spawn := Vector3.ZERO

func _ready() -> void:
	collision_layer = 4
	collision_mask = 15
	floor_snap_length = 0.35
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = 0.9
	add_child(collider)
	var body := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.32
	mesh.height = 1.8
	body.mesh = mesh
	body.position.y = 0.9
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("72b5a6")
	body.material_override = material
	add_child(body)

func _physics_process(delta: float) -> void:
	if not enabled: return
	if Time.get_ticks_msec() - input_at > 250: controls = Vector2.ZERO; jumping = false; sprinting = false
	if not is_on_floor(): velocity.y -= 20.0 * delta
	var speed := 9.0 if sprinting and is_on_floor() else 6.0
	velocity.x = move_toward(velocity.x, controls.x * speed, 35.0 * delta)
	velocity.z = move_toward(velocity.z, -controls.y * speed, 35.0 * delta)
	if jumping and is_on_floor(): velocity.y = 7.0
	jumping = false
	move_and_slide()
	rotation.y = yaw
	if position.y < -70: position = spawn; velocity = Vector3.ZERO

func record(id: String, label: String, tick: int) -> Dictionary:
	return {"id": id, "name": label, "position": View.to_world(position), "velocity": View.to_world(velocity), "yaw": yaw, "input_seq": input_seq, "tick": tick}
