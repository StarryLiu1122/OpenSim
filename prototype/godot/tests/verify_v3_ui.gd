extends RefCounted
const Schema = preload("res://domain/world_schema.gd")

func run(suite: SceneTree) -> void:
	var app = suite.app
	var ui = app.ui
	# Select the third tab through actual mouse events, rather than setting tab state.
	var bar: TabBar = ui.inspector_tabs.get_tab_bar()
	await suite._click_point(bar.global_position + bar.get_tab_rect(2).get_center())
	suite.check(ui.inspector_tabs.current_tab == 2, "environment tab opens through native UI event")
	var panel = ui.environment_panel
	panel.fields.sun_hour.value = 20
	panel.fields.water_height.value = -1.5
	panel.fields.fog_density.value = 0.002
	await suite._click(panel.apply_button)
	suite.check(app.service.model.snapshot().environment.sun_hour == 20 and app.environment_view.sun.light_energy == 0, "environment panel changes persistent time and rendered sunlight")
	suite.check(app.environment_view.water.position.y == -1.5, "environment panel changes actual water elevation")
	await suite._click(ui.buttons.undo)
	suite.check(app.service.model.snapshot().environment.sun_hour == 15.5, "environment edit can be undone through the toolbar")
	await suite._click(ui.buttons.redo)
	suite.check(app.service.model.snapshot().environment.sun_hour == 20, "environment edit can be redone through the toolbar")
	await suite._click(ui.buttons.save)
	await suite._capture("night.png")
	await suite._click(ui.buttons.load)
	suite.check(not app.service.dirty and app.service.model.snapshot().environment.sun_hour == 20, "environment settings restore from the saved scene")
	panel.fields.sun_hour.value = 15.5
	await suite._click(panel.apply_button)
	var door: Dictionary = {}
	for item in app.service.model.snapshot().objects:
		if Schema.kind(item.asset_id) == "door":
			door = item
			break
	app._select(door.id)
	await suite._click(ui.buttons.interact)
	suite.check(app.service.model.object(door.id).state.active, "selected door opens through the object action button")
	await suite._click(ui.buttons.undo)
	suite.check(not app.service.model.object(door.id).state.active, "undo restores the closed door state")
	await suite._click(ui.buttons.redo)
	await suite._click(ui.buttons.save)
	await suite._click(ui.buttons.load)
	suite.check(app.service.model.object(door.id).state.active, "opened door state survives native UI save and reload")
	# Face the jamb (which remains selectable when the door is open), then press E.
	app.avatar.reset_spawn(Vector3(126.83, 0.25, -132))
	await suite._click(ui.buttons.walk)
	for i in range(4):
		await suite.physics_frame
	var event := InputEventKey.new()
	event.keycode = KEY_E
	event.pressed = true
	suite.root.push_input(event, true)
	await suite.process_frame
	suite.check(not app.service.model.object(door.id).state.active, "walking E key closes the targeted door within interaction range")
	suite.root.push_input(event, true)
	await suite.process_frame
	suite.check(app.service.model.object(door.id).state.active, "walking E key opens the same door")
	# Walk through the actual demonstration doorway to its interior, using native input.
	app.avatar.reset_spawn(Vector3(128, 0.25, -132))
	Input.action_press("move_forward")
	for i in range(65):
		await suite.physics_frame
	Input.action_release("move_forward")
	suite.check(app.avatar.position.z < -136 and app.avatar.position.y < 0.5, "avatar walks from courtyard into the demonstration building")
	await suite._capture("interior.png")
	app._set_walk(false)
	for frame in range(3):
		await suite.process_frame
	# Create a different primitive via the selector and inspect its saved material.
	ui.asset_picker.select(1)
	await suite._click(ui.buttons.create)
	var id: String = app.selected_id
	suite.check(Schema.kind(app.service.model.object(id).asset_id) == "cylinder", "asset selector creates a cylinder through the command gateway")
	ui.material_picker.select(3)
	await suite._click(ui.buttons.apply)
	suite.check(app.service.model.object(id).material == "wood", "material selector writes the portable surface identifier")
	await suite._click(ui.buttons.save)
	await suite._click(ui.buttons.load)
	suite.check(app.service.model.object(id).material == "wood", "primitive surface material survives save and reload")
	ui.asset_picker.select(0)
	# A distant target must not respond; interaction rays also include terrain occlusion.
	app.avatar.reset_spawn(Vector3(128, 0.25, -120))
	app._set_walk(true)
	var before: int = app.service.model.revision()
	suite.root.push_input(event, true)
	await suite.process_frame
	suite.check(app.service.model.revision() == before, "walking interaction beyond four metres makes no mutation")
	app._set_walk(false)
	for frame in range(3):
		await suite.process_frame
