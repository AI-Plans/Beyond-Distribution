# DebugUI.gd
extends Control

var player: Node
var visible_mode: int = 1
var draw_debug: bool = true

func _init() -> void:
	RenderingServer.set_debug_generate_wireframes(true)

func _process(_delta) -> void:
	queue_redraw()  # Force redraw for debug visualization
	update_debug_text()

func update_debug_text() -> void:
	$Label.text = "FPS: %s\n" % str(Engine.get_frames_per_second())
	if visible_mode == 1 and player:
		$Label.text += "Move Speed: %.1f\n" % player.MOVE_SPEED
		$Label.text += "Position: %s\n" % str(player.global_position)
		
		# Add AI exploration information
		if "exploration_memory" in player:
			$Label.text += "\nExploration Memory:\n"
			for memory in player.exploration_memory:
				$Label.text += "- %s\n" % str(memory)
		
		# Add detected objects information
		if "detected_objects" in player:
			$Label.text += "\nDetected Objects:\n"
			for obj in player.detected_objects:
				$Label.text += "- Distance: %.2f\n" % obj.distance
		
		$Label.text += """
		Debug Controls:
		Quit: F8
		UI toggle: F9
		Render mode: F10
		Full screen: F11
		Mouse toggle: Escape
		"""

func _draw() -> void:
	if not draw_debug or not player or not "detected_objects" in player:
		return
		
	var viewport = get_viewport()
	if not viewport or not viewport.get_camera_3d():
		return
		
	var camera = viewport.get_camera_3d()
	
	# Draw debug lines for detected objects
	for obj in player.detected_objects:
		var start_pos = player.global_position
		var end_pos = start_pos + obj.direction * obj.distance
		
		# Convert 3D positions to 2D screen positions
		var start_2d = camera.unproject_position(start_pos)
		var end_2d = camera.unproject_position(end_pos)
		
		# Draw line
		draw_line(start_2d, end_2d, Color.RED, 2.0)
		
		# Draw point at collision
		draw_circle(end_2d, 5, Color.YELLOW)
		
		# Draw distance text
		var mid_point = (start_2d + end_2d) / 2
		draw_string(get_theme_default_font(), mid_point, "%.1fm" % obj.distance)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F8:
				get_tree().quit()
			KEY_F9:
				visible_mode = (visible_mode + 1) % 3
				$Label/Panel.visible = (visible_mode == 1)
				visible = visible_mode > 0
			KEY_F10:
				var vp = get_viewport()
				vp.debug_draw = (vp.debug_draw + 1) % 6
				draw_debug = !draw_debug
				get_viewport().set_input_as_handled()
			KEY_F11:
				toggle_fullscreen()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				if Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				else:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				get_viewport().set_input_as_handled()

func toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN or \
		DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2(1280, 720))
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
