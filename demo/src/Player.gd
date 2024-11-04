# Player.gd
extends CharacterBody3D

# Physics and Movement Parameters
@export var MOVE_SPEED: float = 10.0
@export var GRAVITY: float = 9.8
@export var JUMP_FORCE: float = 4.5
@export var MAX_SLOPE_ANGLE: float = 45.0
@export var ACCELERATION: float = 5.0
@export var AIR_CONTROL: float = 0.3
@export var FRICTION: float = 0.1

# Terrain Analysis Parameters
@export var CLIFF_HEIGHT_THRESHOLD: float = 2.0
@export var STEEP_SLOPE_THRESHOLD: float = 60.0
@export var GROUND_CHECK_DISTANCE: float = 0.1
@export var TERRAIN_SCAN_DISTANCE: float = 5.0
@export var SCAN_RESOLUTION: int = 8
@export var TERRAIN_UPDATE_INTERVAL: float = 0.1

# API Rate Limiting
@export var MIN_API_COOLDOWN: float = 1.0
@export var MAX_API_COOLDOWN: float = 30.0
@export var BACKOFF_MULTIPLIER: float = 2.0

# Node references
@onready var camera_manager = $CameraManager
@onready var camera_arm = $CameraManager/Arm
@onready var camera = $CameraManager/Arm/Camera3D
@onready var ground_check = $GroundCheck
@onready var collision_shape = $CollisionShape3D
@onready var character_body = $Body
@onready var timer = $Timer

# Movement and Physics State
var current_movement: Vector3 = Vector3.ZERO
var is_on_ground: bool = false
var was_on_ground: bool = false
var ground_normal: Vector3 = Vector3.UP
var current_slope_angle: float = 0.0
var snap_vector: Vector3 = Vector3.DOWN
var last_safe_position: Vector3
var stuck_time: float = 0.0

# Environment scanning
var ray_casts: Array[RayCast3D] = []
var detected_objects: Array = []
var current_path: Array = []
var terrain_update_timer: float = 0.0

# Terrain Analysis
var terrain_data: Dictionary = {
	"ground_height": 0.0,
	"slopes": [],
	"cliffs": [],
	"safe_paths": [],
	"hazards": []
}

# API Configuration
const USE_LOCAL_SERVER = false
const LOCAL_API_URL = "http://localhost:5000/ai/think"
const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions"
const API_KEY = "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"
const MODEL = "mixtral-8x7b-32768"

# API State Management
var http_request: HTTPRequest
var is_requesting: bool = false
var last_api_call_time: float = 0.0
var current_api_cooldown: float = MIN_API_COOLDOWN
var consecutive_errors: int = 0
var retry_after_time: float = 0.0
var request_queue: Array = []
var max_queue_size: int = 5
var using_local_server: bool = USE_LOCAL_SERVER

# Debug information
var debug_info: Dictionary = {
	"api_requests": 0,
	"api_responses": 0,
	"api_errors": 0,
	"last_movement": Vector3.ZERO,
	"last_api_call": "",
	"last_response": "",
	"last_error": "",
	"current_cooldown": MIN_API_COOLDOWN,
	"using_local": USE_LOCAL_SERVER,
	"queue_size": 0
}

# Terrain Feature Classes
class TerrainFeature:
	var position: Vector3
	var normal: Vector3
	var height: float
	var type: String
	var severity: float
	
	func _init(pos: Vector3, norm: Vector3, h: float, t: String, sev: float):
		position = pos
		normal = norm
		height = h
		type = t
		severity = sev

class SafePath:
	var start: Vector3
	var end: Vector3
	var width: float
	var slope: float
	
	func _init(s: Vector3, e: Vector3, w: float, sl: float):
		start = s
		end = e
		width = w
		slope = sl


func _ready() -> void:
	setup_systems()
	setup_ground_check()
	setup_terrain_scanner()
	last_safe_position = global_position
	print("AI Explorer initialized with terrain analysis")

func setup_systems() -> void:
	# HTTP Request setup
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.use_threads = true
	http_request.timeout = 10.0
	http_request.request_completed.connect(_on_api_response)
	
	# Timer setup
	if timer:
		timer.wait_time = 0.1
		timer.timeout.connect(_on_thinking_tick)
		timer.start()
	
	# Create data directory
	if not DirAccess.dir_exists_absolute("user://data"):
		DirAccess.make_dir_absolute("user://data")
	
	print("Systems initialized")
	_test_api_connection()

func setup_ground_check() -> void:
	if not ground_check:
		ground_check = RayCast3D.new()
		add_child(ground_check)
	
	# Basic setup
	ground_check.position = Vector3.ZERO
	ground_check.enabled = true
	ground_check.target_position = Vector3.DOWN * GROUND_CHECK_DISTANCE
	ground_check.collision_mask = 1  # Make sure this matches your terrain layer
	ground_check.collide_with_areas = false
	ground_check.collide_with_bodies = true
	
	# Add to exceptions instead of using exclude parent
	ground_check.add_exception(self)
	
	print("Ground check setup completed")
	
	
func setup_terrain_scanner() -> void:
	# Initialize scanner node
	var scan_angles = range(0, 360, 360/SCAN_RESOLUTION)
	
	# Clear existing raycasts if any
	for ray in ray_casts:
		ray.queue_free()
	ray_casts.clear()
	
	# Create horizontal ring of raycasts
	for angle in scan_angles:
		var ray = RayCast3D.new()
		add_child(ray)
		
		var direction = Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(angle))
		ray.enabled = true
		ray.target_position = direction * TERRAIN_SCAN_DISTANCE
		ray.collision_mask = 1  # Terrain layer
		ray.collide_with_areas = false
		ray.collide_with_bodies = true
		ray.add_exception(self)  # Add exception instead of exclude parent
		
		ray_casts.append(ray)
	
	# Add angled raycasts for better terrain detection
	var elevation_angles = [-45, -30, 30, 45]  # Angles in degrees
	for angle_h in scan_angles:
		for angle_v in elevation_angles:
			var ray = RayCast3D.new()
			add_child(ray)
			
			var direction = Vector3.FORWARD
			direction = direction.rotated(Vector3.UP, deg_to_rad(angle_h))
			direction = direction.rotated(Vector3.RIGHT, deg_to_rad(angle_v))
			
			ray.enabled = true
			ray.target_position = direction * (TERRAIN_SCAN_DISTANCE * 0.7)
			ray.collision_mask = 1
			ray.collide_with_areas = false
			ray.collide_with_bodies = true
			ray.add_exception(self)  # Add exception instead of exclude parent
			
			ray_casts.append(ray)
	
	print("Terrain scanner setup completed with ", ray_casts.size(), " raycasts")
	
	
#func setup_ground_check() -> void:
	#if not ground_check:
		#ground_check = RayCast3D.new()
		#add_child(ground_check)
	#
	#ground_check.position = Vector3.ZERO
	#ground_check.enabled = true
	#ground_check.target_position = Vector3.DOWN * GROUND_CHECK_DISTANCE
	#ground_check.collision_mask = 1  # Make sure this matches your terrain layer
	#ground_check.collision_exclude_parent = true  # Corrected property name
	#ground_check.collide_with_areas = false
	#ground_check.collide_with_bodies = true
	
	print("Ground check setup completed")

#func setup_terrain_scanner() -> void:
	## Initialize scanner node
	#var scan_angles = range(0, 360, 360/SCAN_RESOLUTION)
	#
	## Clear existing raycasts if any
	#for ray in ray_casts:
		#ray.queue_free()
	#ray_casts.clear()
	#
	## Create horizontal ring of raycasts
	#for angle in scan_angles:
		#var ray = RayCast3D.new()
		#add_child(ray)
		#
		#var direction = Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(angle))
		#ray.enabled = true
		#ray.target_position = direction * TERRAIN_SCAN_DISTANCE
		#ray.collision_mask = 1  # Terrain layer
		#ray.exclude_raycast_parent = true
		#ray.collide_with_areas = false
		#ray.collide_with_bodies = true
		#
		#ray_casts.append(ray)
	#
	## Add angled raycasts for better terrain detection
	#var elevation_angles = [-45, -30, 30, 45]  # Angles in degrees
	#for angle_h in scan_angles:
		#for angle_v in elevation_angles:
			#var ray = RayCast3D.new()
			#add_child(ray)
			#
			#var direction = Vector3.FORWARD
			#direction = direction.rotated(Vector3.UP, deg_to_rad(angle_h))
			#direction = direction.rotated(Vector3.RIGHT, deg_to_rad(angle_v))
			#
			#ray.enabled = true
			#ray.target_position = direction * (TERRAIN_SCAN_DISTANCE * 0.7)
			#ray.collision_mask = 1
			#ray.exclude_raycast_parent = true
			#ray.collide_with_areas = false
			#ray.collide_with_bodies = true
			#
			#ray_casts.append(ray)

func _test_api_connection() -> void:
	if using_local_server:
		var test_request = HTTPRequest.new()
		add_child(test_request)
		test_request.timeout = 5.0
		test_request.request_completed.connect(_on_test_response)
		
		var error = test_request.request(LOCAL_API_URL, [], HTTPClient.METHOD_GET)
		if error != OK:
			print("Local server test failed, switching to Groq API")
			using_local_server = false
			debug_info.using_local = false

func _on_test_response(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		print("Local server unavailable, switching to Groq API")
		using_local_server = false
		debug_info.using_local = false

func _physics_process(delta: float) -> void:
	update_terrain_data(delta)
	apply_physics(delta)
	handle_movement(delta)
	update_safe_position()
	
	move_and_slide()
	post_movement_checks()
	
	
func apply_physics(delta: float) -> void:
	was_on_ground = is_on_ground
	is_on_ground = is_on_floor()
	
	if is_on_ground:
		ground_normal = get_floor_normal()
		current_slope_angle = rad_to_deg(acos(ground_normal.dot(Vector3.UP)))
		snap_vector = -ground_normal * GROUND_CHECK_DISTANCE
	else:
		ground_normal = Vector3.UP
		current_slope_angle = 0.0
		snap_vector = Vector3.DOWN * GROUND_CHECK_DISTANCE
		
		# Apply gravity
		velocity.y -= GRAVITY * delta
	
	# Apply friction when on ground
	if is_on_ground:
		var friction_force = -velocity * FRICTION
		velocity += friction_force * delta

func handle_movement(delta: float) -> void:
	if current_movement.length() < 0.1:
		return
	
	var target_velocity = current_movement * MOVE_SPEED
	
	# Apply acceleration differently based on ground contact
	if is_on_ground:
		velocity = velocity.move_toward(target_velocity, ACCELERATION * delta)
	else:
		# Reduced air control
		velocity = velocity.move_toward(target_velocity, AIR_CONTROL * delta)
	
	# Handle slope movement
	if is_on_ground and current_slope_angle <= MAX_SLOPE_ANGLE:
		var slope_movement = current_movement.slide(ground_normal).normalized()
		velocity = slope_movement * MOVE_SPEED
	
	# Check for hazards in movement path
	if is_movement_unsafe():
		avoid_hazards()

func post_movement_checks() -> void:
	# Check for remaining velocity
	if velocity.length() < 0.01:
		velocity = Vector3.ZERO
	
	# Update ground state
	was_on_ground = is_on_ground
	is_on_ground = is_on_floor()
	
	# Check if stuck
	if velocity.length() < 0.1 and current_movement.length() > 0.1:
		stuck_time += get_physics_process_delta_time()
		if stuck_time > 0.5:
			find_alternative_path()
			stuck_time = 0.0
	else:
		stuck_time = 0.0
	
	# Update path tracking
	if global_position.distance_to(last_safe_position) > 0.5:
		current_path.append(global_position)
		last_safe_position = global_position
		
		if current_path.size() > 50:
			current_path.pop_front()
	
	# Update debug information
	debug_info.last_movement = current_movement

func update_safe_position() -> void:
	if is_on_ground and not is_movement_unsafe():
		last_safe_position = global_position

func find_alternative_path() -> void:
	var open_directions = []
	
	for ray in ray_casts:
		if not ray.is_colliding():
			open_directions.append(ray.target_position.normalized())
	
	if not open_directions.is_empty():
		var best_dir = open_directions[0]
		var best_dot = -1
		
		for dir in open_directions:
			var dot = dir.dot(current_movement)
			if dot > best_dot:
				best_dot = dot
				best_dir = dir
		
		current_movement = best_dir
	else:
		current_movement = -current_movement

func avoid_hazards() -> void:
	var safe_direction = Vector3.ZERO
	
	# Find the nearest safe path
	var nearest_path = find_nearest_safe_path()
	if nearest_path:
		var path_center = (nearest_path.start + nearest_path.end) / 2.0
		safe_direction = (path_center - global_position).normalized()
	else:
		# If no safe path found, move away from hazards
		for cliff in terrain_data.cliffs:
			safe_direction -= (cliff.position - global_position).normalized()
		for slope in terrain_data.slopes:
			if slope.severity > 0.8:
				safe_direction -= (slope.position - global_position).normalized()
	
	if safe_direction != Vector3.ZERO:
		current_movement = safe_direction.normalized()
	else:
		# If no safe direction found, try to return to last safe position
		current_movement = (last_safe_position - global_position).normalized()
		
		
func update_terrain_data(delta: float) -> void:
	terrain_update_timer += delta
	if terrain_update_timer >= TERRAIN_UPDATE_INTERVAL:
		terrain_update_timer = 0.0
		scan_terrain()
		update_navigation_mesh()

func scan_terrain() -> void:
	terrain_data.clear()
	terrain_data = {
		"ground_height": get_ground_height(),
		"slopes": [],
		"cliffs": [],
		"safe_paths": [],
		"hazards": []
	}
	
	# Scan with existing raycasts
	for ray in ray_casts:
		if ray.is_colliding():
			var hit_point = ray.get_collision_point()
			var hit_normal = ray.get_collision_normal()
			analyze_terrain_feature(hit_point, hit_normal)
	
	# Also scan external terrain
	scan_external_terrain()
	
	
func update_navigation_mesh() -> void:
	# Convert safe paths to navigation points
	var nav_points = []
	
	for path in terrain_data.safe_paths:
		nav_points.append({
			"position": path.start,
			"connected_to": [],
			"cost": 0.0
		})
	
	# Connect navigation points
	for i in range(nav_points.size()):
		for j in range(i + 1, nav_points.size()):
			var start = nav_points[i].position
			var end = nav_points[j].position
			
			if can_connect_points(start, end):
				var cost = calculate_path_cost(start, end)
				nav_points[i].connected_to.append({"index": j, "cost": cost})
				nav_points[j].connected_to.append({"index": i, "cost": cost})
				


func find_safe_alternative_movement(original_movement: Vector3) -> void:
	var test_angles = [0, 45, -45, 90, -90, 135, -135, 180]
	var best_movement = Vector3.ZERO
	var best_score = -INF
	
	for angle in test_angles:
		var rotated_movement = original_movement.rotated(Vector3.UP, deg_to_rad(angle))
		var score = evaluate_movement_safety(rotated_movement)
		
		if score > best_score:
			best_score = score
			best_movement = rotated_movement
	
	if best_score > 0:
		current_movement = best_movement
	else:
		current_movement = Vector3.ZERO


func can_connect_points(start: Vector3, end: Vector3) -> bool:
	# Cast ray to check for obstacles
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(start, end)
	query.collision_mask = 1  # Terrain layer
	var result = space_state.intersect_ray(query)
	
	if result:
		# Check if the intersection is too far from the line
		var hit_point = result.position
		var line_direction = (end - start).normalized()
		var hit_projection = start + line_direction * start.distance_to(hit_point)
		var deviation = hit_point.distance_to(hit_projection)
		
		if deviation > 0.5:  # Maximum allowed deviation
			return false
		
		# Check slope at intersection
		var hit_normal = result.normal
		var slope_angle = rad_to_deg(acos(hit_normal.dot(Vector3.UP)))
		return slope_angle <= MAX_SLOPE_ANGLE
	
	return true

func calculate_path_cost(start: Vector3, end: Vector3) -> float:
	var distance = start.distance_to(end)
	var height_diff = abs(end.y - start.y)
	
	# Base cost is the distance
	var cost = distance
	
	# Add height difference penalty
	cost += height_diff * 2.0
	
	# Add hazard proximity penalty
	for cliff in terrain_data.cliffs:
		var cliff_distance = min(
			start.distance_to(cliff.position),
			end.distance_to(cliff.position)
		)
		if cliff_distance < CLIFF_HEIGHT_THRESHOLD * 2:
			cost += (CLIFF_HEIGHT_THRESHOLD * 2 - cliff_distance) * 5.0
	
	for slope in terrain_data.slopes:
		if slope.severity > 0.8:
			var slope_distance = min(
				start.distance_to(slope.position),
				end.distance_to(slope.position)
			)
			if slope_distance < 3.0:
				cost += (3.0 - slope_distance) * slope.severity * 3.0
	
	return cost

func is_safe_movement(movement: Vector3) -> bool:
	var future_position = global_position + movement * MOVE_SPEED * 0.5
	
	# Check for cliffs
	for cliff in terrain_data.cliffs:
		if future_position.distance_to(cliff.position) < CLIFF_HEIGHT_THRESHOLD * 1.5:
			return false
	
	# Check for steep slopes
	for slope in terrain_data.slopes:
		if slope.severity > 0.8 and future_position.distance_to(slope.position) < 2.0:
			return false
	
	# Check ground continuity
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		future_position + Vector3.UP,
		future_position + Vector3.DOWN * (GROUND_CHECK_DISTANCE * 2),
		1  # Terrain layer
	)
	var result = space_state.intersect_ray(query)
	
	if not result:
		return false  # No ground found
	
	# Check slope at destination
	var dest_normal = result.normal
	var dest_slope_angle = rad_to_deg(acos(dest_normal.dot(Vector3.UP)))
	return dest_slope_angle <= MAX_SLOPE_ANGLE

func update_navigation_strategy(analysis: Dictionary) -> void:
	if not analysis.has("path_options"):
		return
	
	if not terrain_data.safe_paths.is_empty():
		var nearest_path = find_nearest_safe_path()
		if nearest_path:
			# Update current path if needed
			if current_path.is_empty() or current_path.back().distance_to(global_position) > 5.0:
				current_path = [global_position]
			
			# Add path waypoints
			var path_center = (nearest_path.start + nearest_path.end) / 2.0
			current_path.append(path_center)
			
			if current_path.size() > 50:
				current_path.pop_front()

func execute_movement_plan(plan: Dictionary) -> void:
	if not plan.has("immediate_action"):
		return
	
	match plan.immediate_action:
		"stop":
			current_movement = Vector3.ZERO
		"retreat":
			current_movement = (last_safe_position - global_position).normalized()
		"follow_path":
			if not current_path.is_empty():
				var next_point = current_path.back()
				current_movement = (next_point - global_position).normalized()
		_:
			# Default to continuing current movement
			pass


func evaluate_movement_safety(movement: Vector3) -> float:
	var future_position = global_position + movement * TERRAIN_SCAN_DISTANCE
	var safety_score = 10.0
	
	# Penalize proximity to hazards
	for cliff in terrain_data.cliffs:
		var distance = future_position.distance_to(cliff.position)
		if distance < CLIFF_HEIGHT_THRESHOLD * 2:
			safety_score -= (CLIFF_HEIGHT_THRESHOLD * 2 - distance) * 5.0
	
	for slope in terrain_data.slopes:
		if slope.severity > 0.8:
			var distance = future_position.distance_to(slope.position)
			if distance < 3.0:
				safety_score -= (3.0 - distance) * slope.severity * 3.0
	
	# Bonus for following safe paths
	for path in terrain_data.safe_paths:
		var path_center = (path.start + path.end) / 2.0
		var distance = future_position.distance_to(path_center)
		if distance < path.width:
			safety_score += (path.width - distance) * 2.0
	
	return safety_score

#func update_navigation_strategy(analysis: Dictionary) -> void:
	#if not analysis.has("path_options"):
		#return
		#
	#if not terrain_data.safe_paths.is_empty():
		#var nearest_path = find_nearest_safe_path()
		#if nearest_path:
			## Update current path if needed
			#if current_path.is_empty() or current_path.back().distance_to(global_position) > 5.0:
				#current_path = [global_position]
			#
			## Add path waypoints
			#var path_center = (nearest_path.start + nearest_path.end) / 2.0
			#current_path.append(path_center)
			#
			#if current_path.size() > 50:
				#current_path.pop_front()

#func execute_movement_plan(plan: Dictionary) -> void:
	#if not plan.has("immediate_action"):
		#return
		#
	#match plan.immediate_action:
		#"stop":
			#current_movement = Vector3.ZERO
		#"retreat":
			#current_movement = (last_safe_position - global_position).normalized()
		#"follow_path":
			#if not current_path.is_empty():
				#var next_point = current_path.back()
				#current_movement = (next_point - global_position).normalized()
		#_:
			## Default to continuing current movement
			#pass

func scan_external_terrain() -> void:
	var space_state = get_world_3d().direct_space_state
	var scan_directions = [
		Vector3.FORWARD,
		Vector3.BACK,
		Vector3.LEFT,
		Vector3.RIGHT,
		Vector3.FORWARD + Vector3.LEFT,
		Vector3.FORWARD + Vector3.RIGHT,
		Vector3.BACK + Vector3.LEFT,
		Vector3.BACK + Vector3.RIGHT
	]
	
	for direction in scan_directions:
		var normalized_dir = direction.normalized()
		var query = PhysicsRayQueryParameters3D.create(
			global_position,
			global_position + normalized_dir * TERRAIN_SCAN_DISTANCE,
			1  # Collision mask for terrain
		)
		
		var result = space_state.intersect_ray(query)
		if result:
			analyze_terrain_feature(result.position, result.normal)

func analyze_terrain_feature(point: Vector3, normal: Vector3) -> void:
	var height_diff = point.y - global_position.y
	var slope_angle = rad_to_deg(acos(normal.dot(Vector3.UP)))
	
	if slope_angle > STEEP_SLOPE_THRESHOLD:
		# Detected steep slope or cliff
		var feature = TerrainFeature.new(
			point,
			normal,
			height_diff,
			"cliff" if height_diff > CLIFF_HEIGHT_THRESHOLD else "steep_slope",
			min(1.0, slope_angle / 90.0)
		)
		if height_diff > CLIFF_HEIGHT_THRESHOLD:
			terrain_data.cliffs.append(feature)
		else:
			terrain_data.slopes.append(feature)
	else:
		# Potentially safe path
		find_safe_path(point, normal, slope_angle)

func find_safe_path(point: Vector3, normal: Vector3, slope_angle: float) -> void:
	var path_width = 0.0
	var path_start = point
	var path_end = point
	
	# Check for continuous walkable surface
	for ray in ray_casts:
		if ray.is_colliding():
			var test_point = ray.get_collision_point()
			var test_normal = ray.get_collision_normal()
			var test_slope = rad_to_deg(acos(test_normal.dot(Vector3.UP)))
			
			if test_slope <= MAX_SLOPE_ANGLE and abs(test_point.y - point.y) < 0.5:
				path_width += 0.5  # Approximate width calculation
				path_end = test_point
	
	if path_width > 1.0:  # Minimum width for a safe path
		var safe_path = SafePath.new(path_start, path_end, path_width, slope_angle)
		terrain_data.safe_paths.append(safe_path)

func get_ground_height() -> float:
	if ground_check.is_colliding():
		return ground_check.get_collision_point().y
	return global_position.y

func is_movement_unsafe() -> bool:
	var future_position = global_position + velocity.normalized() * TERRAIN_SCAN_DISTANCE
	
	# Check for cliffs
	for cliff in terrain_data.cliffs:
		if future_position.distance_to(cliff.position) < CLIFF_HEIGHT_THRESHOLD * 1.5:
			return true
	
	# Check for steep slopes
	for slope in terrain_data.slopes:
		if future_position.distance_to(slope.position) < 2.0 and slope.severity > 0.8:
			return true
	
	# Check ground continuity
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		future_position + Vector3.UP,
		future_position + Vector3.DOWN * (GROUND_CHECK_DISTANCE * 2),
		1
	)
	var result = space_state.intersect_ray(query)
	
	if not result:
		return true  # No ground found
	
	# Check slope at destination
	var dest_normal = result.normal
	var dest_slope_angle = rad_to_deg(acos(dest_normal.dot(Vector3.UP)))
	
	return dest_slope_angle > MAX_SLOPE_ANGLE

func find_nearest_safe_path() -> SafePath:
	var nearest_path: SafePath = null
	var min_distance: float = INF
	
	for path in terrain_data.safe_paths:
		var path_center = (path.start + path.end) / 2.0
		var distance = global_position.distance_to(path_center)
		
		if distance < min_distance and is_path_safe(path):
			min_distance = distance
			nearest_path = path
	
	return nearest_path

func is_path_safe(path: SafePath) -> bool:
	# Check slope angle
	if path.slope > MAX_SLOPE_ANGLE:
		return false
	
	# Check minimum width
	if path.width < 1.0:
		return false
	
	# Check for hazards
	var path_center = (path.start + path.end) / 2.0
	
	for cliff in terrain_data.cliffs:
		if path_center.distance_to(cliff.position) < CLIFF_HEIGHT_THRESHOLD * 1.5:
			return false
	
	for slope in terrain_data.slopes:
		if slope.severity > 0.8 and path_center.distance_to(slope.position) < 2.0:
			return false
	
	# Verify ground continuity
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(path.start, path.end, 1)
	var result = space_state.intersect_ray(query)
	
	if result:
		var hit_normal = result.normal
		var slope_angle = rad_to_deg(acos(hit_normal.dot(Vector3.UP)))
		return slope_angle <= MAX_SLOPE_ANGLE
	
	return false
	
func _on_thinking_tick() -> void:
	if not is_requesting and can_make_api_call():
		if not request_queue.is_empty():
			process_next_request()
		else:
			request_ai_decision()

func can_make_api_call() -> bool:
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_last_call = current_time - last_api_call_time
	
	if retry_after_time > 0 and current_time < retry_after_time:
		return false
	
	return time_since_last_call >= current_api_cooldown

func update_api_cooldown(success: bool) -> void:
	if success:
		consecutive_errors = 0
		current_api_cooldown = max(MIN_API_COOLDOWN, current_api_cooldown / BACKOFF_MULTIPLIER)
	else:
		consecutive_errors += 1
		current_api_cooldown = min(MAX_API_COOLDOWN, 
			current_api_cooldown * pow(BACKOFF_MULTIPLIER, consecutive_errors))
	
	debug_info.current_cooldown = current_api_cooldown

func process_next_request() -> void:
	if request_queue.is_empty():
		return
	
	var next_request = request_queue.pop_front()
	debug_info.queue_size = request_queue.size()
	make_api_request(next_request)

func request_ai_decision() -> void:
	if is_requesting:
		if request_queue.size() < max_queue_size:
			request_queue.append(prepare_request_data())
			debug_info.queue_size = request_queue.size()
		return
	
	is_requesting = true
	debug_info.api_requests += 1
	make_api_request(prepare_request_data())

func prepare_request_data() -> Dictionary:
	var terrain_analysis = {
		"current_height": global_position.y,
		"ground_height": terrain_data.ground_height,
		"slope_angle": current_slope_angle,
		"is_on_ground": is_on_ground,
		"nearby_features": prepare_terrain_features(),
		"safe_paths": prepare_safe_paths(),
		"hazards": prepare_hazards()
	}
	
	var movement_state = {
		"position": {
			"x": global_position.x,
			"y": global_position.y,
			"z": global_position.z
		},
		"velocity": {
			"x": velocity.x,
			"y": velocity.y,
			"z": velocity.z
		},
		"is_moving": current_movement.length() > 0.1,
		"is_stuck": stuck_time > 0.0,
		"last_safe_position": {
			"x": last_safe_position.x,
			"y": last_safe_position.y,
			"z": last_safe_position.z
		}
	}
	
	return {
		"terrain": terrain_analysis,
		"movement": movement_state,
		"navigation": {
			"available_paths": terrain_data.safe_paths.size(),
			"current_path": current_path,
			"detected_objects": detected_objects
		}
	}

func prepare_terrain_features() -> Array:
	var features = []
	for slope in terrain_data.slopes:
		features.append({
			"type": "slope",
			"position": {
				"x": slope.position.x,
				"y": slope.position.y,
				"z": slope.position.z
			},
			"severity": slope.severity,
			"angle": rad_to_deg(acos(slope.normal.dot(Vector3.UP)))
		})
	return features

func prepare_safe_paths() -> Array:
	var paths = []
	for path in terrain_data.safe_paths:
		paths.append({
			"start": {
				"x": path.start.x,
				"y": path.start.y,
				"z": path.start.z
			},
			"end": {
				"x": path.end.x,
				"y": path.end.y,
				"z": path.end.z
			},
			"width": path.width,
			"slope": path.slope
		})
	return paths

func prepare_hazards() -> Array:
	var hazards = []
	for cliff in terrain_data.cliffs:
		hazards.append({
			"type": "cliff",
			"position": {
				"x": cliff.position.x,
				"y": cliff.position.y,
				"z": cliff.position.z
			},
			"height": cliff.height,
			"severity": cliff.severity
		})
	return hazards
	
	
func make_api_request(environment_data: Dictionary) -> void:
	var url = LOCAL_API_URL if using_local_server else GROQ_API_URL
	var headers = _get_headers()
	
	var system_prompt = """
	You are an AI exploring a 3D environment with terrain awareness.
	You can move freely but must avoid hazards like cliffs and steep slopes.
	Analyze the environment and navigate safely along available paths, also finding a cave is high prority, it 
	is around 360, 80 , 270.
	
	Respond only with JSON:
	{
		"movement": {
			"x": -1 to 1,
			"y": -1 to 1,
			"z": -1 to 1
		},
		"analysis": {
			"terrain_assessment": "description of current terrain",
			"hazard_proximity": "description of nearby hazards",
			"path_options": "available safe paths"
		},
		"plan": {
			"immediate_action": "next movement action",
			"navigation_strategy": "overall movement strategy",
			"safety_considerations": "identified risks and mitigations"
		}
	}
	"""
	
	var body = {
		"model": MODEL,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": JSON.stringify(environment_data)}
		],
		"temperature": 0.7,
		"response_format": {"type": "json_object"}
	}
	
	print("\nSending API request to: ", url)
	debug_info.last_api_call = Time.get_datetime_string_from_system()
	
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		handle_request_error("Request failed: " + str(error))
	else:
		print("Request sent at: ", debug_info.last_api_call)
		last_api_call_time = Time.get_ticks_msec() / 1000.0

func _get_headers() -> PackedStringArray:
	if using_local_server:
		return PackedStringArray([
			"Content-Type: application/json"
		])
	else:
		return PackedStringArray([
			"Content-Type: application/json",
			"Authorization: Bearer " + API_KEY
		])

func _on_api_response(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	is_requesting = false
	
	# Handle rate limiting headers
	for header in headers:
		if header.begins_with("Retry-After: "):
			var retry_seconds = float(header.split(": ")[1])
			retry_after_time = Time.get_ticks_msec() / 1000.0 + retry_seconds
			print("Rate limited. Retry after: ", retry_seconds, " seconds")
	
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		match response_code:
			429:  # Too Many Requests
				handle_rate_limit_error()
			500, 502, 503, 504:  # Server errors
				handle_server_error()
			_:  # Other errors
				handle_request_error("Response failed: " + str(response_code))
		return
	
	# Success case
	update_api_cooldown(true)
	retry_after_time = 0.0
	
	debug_info.api_responses += 1
	debug_info.last_response = Time.get_datetime_string_from_system()
	
	process_successful_response(body)

func handle_rate_limit_error() -> void:
	print("Rate limit hit, backing off...")
	update_api_cooldown(false)
	debug_info.api_errors += 1
	debug_info.last_error = "Rate limit exceeded"
	
	if retry_after_time <= 0:
		retry_after_time = Time.get_ticks_msec() / 1000.0 + current_api_cooldown

func handle_server_error() -> void:
	print("Server error, implementing exponential backoff...")
	update_api_cooldown(false)
	debug_info.api_errors += 1
	debug_info.last_error = "Server error"

func handle_request_error(error_msg: String) -> void:
	is_requesting = false
	debug_info.api_errors += 1
	debug_info.last_error = error_msg
	print("API ERROR: ", error_msg)
	
	if using_local_server:
		print("Local server error, switching to Groq API")
		using_local_server = false
		debug_info.using_local = false
		request_ai_decision()

func process_successful_response(body: PackedByteArray) -> void:
	var response_text = body.get_string_from_utf8()
	print("Received response: ", response_text)
	
	var json = JSON.new()
	var parse_result = json.parse(response_text)
	
	if parse_result != OK:
		print("Failed to parse response: ", json.get_error_message())
		return
	
	var response = json.get_data()
	if not response or not response.has("choices") or response.choices.is_empty():
		print("Invalid response format")
		return
	
	var content = response.choices[0].message.content
	var ai_json = JSON.new()
	var ai_parse_result = ai_json.parse(content)
	
	if ai_parse_result != OK:
		print("Failed to parse AI response")
		return
	
	var decision = ai_json.get_data()
	process_ai_decision(decision)

func process_ai_decision(decision: Dictionary) -> void:
	if decision.has("movement"):
		var proposed_movement = Vector3(
			_safe_float(decision.movement.get("x", 0.0)),
			_safe_float(decision.movement.get("y", 0.0)),
			_safe_float(decision.movement.get("z", 0.0))
		)
		
		if is_safe_movement(proposed_movement):
			current_movement = proposed_movement
			debug_info.last_movement = current_movement
			print("New safe movement: ", current_movement)
		else:
			print("Unsafe movement proposed, finding alternative...")
			find_safe_alternative_movement(proposed_movement)
	
	if decision.has("analysis"):
		update_navigation_strategy(decision.analysis)
		print("Terrain Analysis: ", decision.analysis)
	
	if decision.has("plan"):
		execute_movement_plan(decision.plan)
		print("Movement Plan: ", decision.plan)
	
	save_debug_info()

func save_debug_info() -> void:
	var debug_text = """
	AI Explorer Debug Info:
	Position: %s
	Movement: %s
	Velocity: %s
	
	Terrain Analysis:
	- Ground Height: %.2f
	- Current Slope: %.2f°
	- Nearby Cliffs: %d
	- Safe Paths: %d
	- Is On Ground: %s
	
	API Stats:
	- Using Local: %s
	- Requests: %d
	- Responses: %d
	- Errors: %d
	- Last Call: %s
	- Last Response: %s
	- Last Error: %s
	- Current Cooldown: %.2f
	- Queue Size: %d
	""" % [
		str(global_position),
		str(debug_info.last_movement),
		str(velocity),
		terrain_data.ground_height,
		current_slope_angle,
		terrain_data.cliffs.size(),
		terrain_data.safe_paths.size(),
		str(is_on_ground),
		str(debug_info.using_local),
		debug_info.api_requests,
		debug_info.api_responses,
		debug_info.api_errors,
		debug_info.last_api_call,
		debug_info.last_response,
		debug_info.last_error,
		debug_info.current_cooldown,
		debug_info.queue_size
	]
	
	print("\n", debug_text)
	
	var file = FileAccess.open("user://data/debug_log.txt", FileAccess.WRITE)
	if file:
		file.store_string(debug_text)
		file.close()

func _safe_float(value) -> float:
	if value is float or value is int:
		return float(value)
	return 0.0

# Optional: Debug visualization
#func _draw_debug() -> void:
	#if not Engine.is_editor_hint():
		#return
		#
	#for ray in ray_casts:
		#var end_point = ray.to_global(ray.target_position)
		#DebugDraw3D.draw_line(ray.global_position, end_point, Color.YELLOW)
		#
		#if ray.is_colliding():
			#var collision_point = ray.get_collision_point()
			#var collision_normal = ray.get_collision_normal()
			#DebugDraw3D.draw_sphere(collision_point, 0.1, Color.RED)
			#DebugDraw3D.draw_ray(collision_point, collision_normal, 0.5, Color.GREEN)
	#
	## Draw safe paths
	#for path in terrain_data.safe_paths:
		#DebugDraw3D.draw_line(path.start, path.end, Color.GREEN)
		#DebugDraw3D.draw_sphere((path.start + path.end) / 2.0, 0.2, Color.BLUE)
