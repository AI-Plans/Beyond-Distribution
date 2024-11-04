# Player.gd
extends CharacterBody3D

@export var MOVE_SPEED: float = 10.0

# Node references
@onready var camera_manager = $CameraManager
@onready var camera_arm = $CameraManager/Arm
@onready var camera = $CameraManager/Arm/Camera3D
@onready var collision_body = $CollisionShapeBody
@onready var collision_ray = $CollisionShapeRay
@onready var body = $Body

# Environment Detection
var ray_casts: Array[RayCast3D] = []
var detected_objects: Array = []
var exploration_memory: Array = []
const MAX_MEMORY = 50

# AI State
var http_request: HTTPRequest
var is_requesting: bool = false
var last_api_call_time: float = 0.0
var api_cooldown: float = 2.0
var current_movement: Vector3 = Vector3.ZERO
var stuck_time: float = 0.0

# API Configuration
const USE_LOCAL_SERVER = true
const LOCAL_API_URL = "http://localhost:5000/ai/think"
const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions"
const API_KEY = "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"
const MODEL = "mixtral-8x7b-32768"

func _ready() -> void:
	_setup_systems()
	_setup_raycasts()

func _setup_systems() -> void:
	# HTTP Request setup
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_api_response)
	
	# Timer setup
	if $Timer:
		$Timer.wait_time = 0.1
		$Timer.timeout.connect(_on_thinking_tick)
		$Timer.start()
	
	# Create data directory
	if not DirAccess.dir_exists_absolute("user://data"):
		DirAccess.make_dir_absolute("user://data")

func _setup_raycasts() -> void:
	var directions = [
		Vector3(1, 0, 0), Vector3(-1, 0, 0),    # Right, Left
		Vector3(0, 0, 1), Vector3(0, 0, -1),    # Forward, Back
		Vector3(0, 1, 0), Vector3(0, -1, 0),    # Up, Down
		Vector3(1, 0, 1).normalized(),          # Diagonal directions
		Vector3(-1, 0, 1).normalized(),
		Vector3(1, 0, -1).normalized(),
		Vector3(-1, 0, -1).normalized(),
	]
	
	for dir in directions:
		var ray = RayCast3D.new()
		add_child(ray)
		ray.target_position = dir * 5.0
		ray.collision_mask = 1
		ray_casts.append(ray)

func _physics_process(delta: float) -> void:
	_scan_environment()
	_apply_movement(delta)
	_check_stuck_state(delta)
	move_and_slide()

func _apply_movement(delta: float) -> void:
	if current_movement.length() < 0.1:
		return
	
	# Apply movement directly without restricting Y
	var target_velocity = current_movement * MOVE_SPEED
	velocity = velocity.move_toward(target_velocity, MOVE_SPEED * delta * 10)
	
	# Handle collisions by trying to slide along walls
	if get_slide_collision_count() > 0:
		for i in range(get_slide_collision_count()):
			var collision = get_slide_collision(i)
			if collision:
				var normal = collision.get_normal()
				var slide_direction = current_movement.slide(normal)
				velocity = slide_direction * MOVE_SPEED

func _scan_environment() -> void:
	detected_objects.clear()
	
	for ray in ray_casts:
		if ray.is_colliding():
			var collision_point = ray.get_collision_point()
			var collision_normal = ray.get_collision_normal()
			var distance = global_position.distance_to(collision_point)
			
			var observation = {
				"distance": distance,
				"direction": ray.target_position.normalized(),
				"normal": {
					"x": collision_normal.x,
					"y": collision_normal.y,
					"z": collision_normal.z
				},
				"position": {
					"x": collision_point.x,
					"y": collision_point.y,
					"z": collision_point.z
				},
				"is_close": distance < 2.0
			}
			
			detected_objects.append(observation)
			
			# Store in memory if it's an interesting observation
			if _is_interesting_observation(observation):
				_add_to_memory(observation)

func _is_interesting_observation(observation: Dictionary) -> bool:
	# Consider something interesting if:
	# - It's very close
	# - It has an unusual normal (potential cave wall)
	# - It's at a significantly different height
	var normal = Vector3(observation.normal.x, observation.normal.y, observation.normal.z)
	return (
		observation.is_close or
		abs(normal.dot(Vector3.UP)) < 0.3 or  # More vertical surface
		abs(observation.position.y - global_position.y) > 2.0
	)

func _add_to_memory(observation: Dictionary) -> void:
	observation["time"] = Time.get_unix_time_from_system()
	exploration_memory.append(observation)
	
	if exploration_memory.size() > MAX_MEMORY:
		exploration_memory.pop_front()

func _check_stuck_state(delta: float) -> void:
	if velocity.length() < 0.1 and current_movement.length() > 0.1:
		stuck_time += delta
		if stuck_time > 0.5:  # Quick reaction to being stuck
			_handle_stuck_state()
			stuck_time = 0.0
	else:
		stuck_time = 0.0

func _handle_stuck_state() -> void:
	# Find open directions
	var open_directions: Array = []
	for ray in ray_casts:
		if not ray.is_colliding():
			open_directions.append(ray.target_position.normalized())
	
	if not open_directions.is_empty():
		# Choose random open direction
		var new_direction = open_directions[randi() % open_directions.size()]
		current_movement = new_direction
	else:
		# If no open directions, try moving backwards
		current_movement = -current_movement

func _on_thinking_tick() -> void:
	if not is_requesting:
		_request_ai_decision()

func _request_ai_decision() -> void:
	if is_requesting:
		return
		
	is_requesting = true
	var current_time = Time.get_ticks_msec() / 1000.0
	
	if current_time - last_api_call_time < api_cooldown:
		is_requesting = false
		return
	
	var environment_data = {
		"position": {
			"x": global_position.x,
			"y": global_position.y,
			"z": global_position.z
		},
		"surroundings": detected_objects,
		"current_velocity": {
			"x": velocity.x,
			"y": velocity.y,
			"z": velocity.z
		},
		"memory": exploration_memory.slice(-5),  # Last 5 memories
		"is_stuck": stuck_time > 0.0
	}
	
	var url = LOCAL_API_URL if USE_LOCAL_SERVER else GROQ_API_URL
	var headers = _get_headers()
	
	var body = {
		"model": MODEL,
		"messages": [
			{
				"role": "system",
				"content": """
				You are an AI exploring a 3D environment to find caves.
				You can move in any direction including up/down if the path is clear.
				When encountering obstacles, try to find alternate paths.
				Response format:
				{
					"movement": {"x": -1.0 to 1.0, "y": -1.0 to 1.0, "z": -1.0 to 1.0},
					"analysis": "what you observe",
					"next_action": "planned movement"
				}
				"""
			},
			{
				"role": "user",
				"content": JSON.stringify(environment_data)
			}
		],
		"temperature": 0.7,
		"response_format": {"type": "json_object"}
	}
	
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		is_requesting = false
	else:
		last_api_call_time = current_time

func _get_headers() -> PackedStringArray:
	if USE_LOCAL_SERVER:
		return PackedStringArray([
			"Content-Type: application/json"
		])
	else:
		return PackedStringArray([
			"Content-Type: application/json",
			"Authorization: Bearer " + API_KEY
		])

func _on_api_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	is_requesting = false
	
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		print("API request failed: ", response_code)
		return
	
	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	
	if parse_result != OK:
		return
		
	var response = json.get_data()
	if not response or not response.has("choices") or response.choices.is_empty():
		return
	
	var ai_response = JSON.new()
	var content = response.choices[0].message.content
	parse_result = ai_response.parse(content)
	
	if parse_result != OK:
		return
		
	var decision = ai_response.get_data()
	_process_ai_decision(decision)

func _process_ai_decision(decision: Dictionary) -> void:
	if decision.has("movement"):
		current_movement = Vector3(
			_safe_float(decision.movement.get("x", 0.0)),
			_safe_float(decision.movement.get("y", 0.0)),  # Allow Y movement
			_safe_float(decision.movement.get("z", 0.0))
		).normalized()

func _safe_float(value) -> float:
	if value is float or value is int:
		return float(value)
	return 0.0
