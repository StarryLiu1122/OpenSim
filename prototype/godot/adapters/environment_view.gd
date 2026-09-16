extends Node3D
## Environment settings are projected from persistent data; no simulation clock.
var settings := Environment.new()
var sky_material := ProceduralSkyMaterial.new()
var sun := DirectionalLight3D.new()
var water := MeshInstance3D.new()
var _last: Dictionary = {}

func _ready() -> void:
	var environment := WorldEnvironment.new()
	var sky := Sky.new()
	sky.sky_material = sky_material
	settings.sky = sky
	settings.background_mode = Environment.BG_SKY
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.environment = settings
	add_child(environment)
	sun.shadow_enabled = not OS.has_feature("web")
	sun.directional_shadow_max_distance = 240
	add_child(sun)
	var plane := PlaneMesh.new()
	plane.size = Vector2(256, 256)
	water.mesh = plane
	water.position = Vector3(128, -1, -128)
	var surface := ShaderMaterial.new()
	surface.shader = preload("res://adapters/water.gdshader")
	water.material_override = surface
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)

func sync(data: Dictionary) -> void:
	if _last == data:
		return
	_last = data.duplicate(true)
	var elevation := sin((float(data.sun_hour) - 6.0) * TAU / 24.0)
	var daylight := smoothstep(-0.12, 0.35, elevation)
	var sunset := 1.0 - smoothstep(0.0, 0.45, absf(elevation))
	sun.rotation_degrees = Vector3(-elevation * 75.0, -35.0 + (data.sun_hour - 12.0) * 12.0, 0)
	sun.light_energy = maxf(0.0, elevation) * 0.65
	sun.light_color = Color("fff1d4").lerp(Color("ffa567"), sunset)
	sky_material.sky_top_color = Color("081126").lerp(Color("4685b1"), daylight)
	sky_material.sky_horizon_color = Color("18283c").lerp(Color("c6d9d9").lerp(Color("e7b38b"), sunset), daylight)
	sky_material.ground_horizon_color = sky_material.sky_horizon_color
	sky_material.ground_bottom_color = Color("192d29")
	settings.ambient_light_color = Color("91b5d7").lerp(Color("e3edf4"), daylight)
	settings.ambient_light_energy = lerpf(0.10, 0.22, daylight)
	settings.fog_enabled = data.fog_density > 0
	settings.fog_density = data.fog_density
	settings.fog_light_color = sky_material.sky_horizon_color
	water.visible = data.water_enabled
	water.position.y = data.water_height
