extends CharacterBody3D

@export var speed = 5.0
@export var jump_velocity = 4.5
@export var movement_speed_multiplier = 0.5
@export var max_health = 100
@export var punch_damage = 10
@export var punch_range = 1.6
@export var punch_cooldown = 0.8
@export var is_cpu = false
@export var target_path: NodePath
@export var ai_stop_distance = 1.2
@export var ai_attack_distance = 1.6

signal health_changed(current: float, maximum: float)
signal died

# This path MUST match your scene tree exactly.
@onready var model = $Model
@onready var animation_player = $Model/AnimationPlayer

var animation_aliases: Dictionary = {}
var missing_animation_warnings: Dictionary = {}

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var attack_cooldown_timer := 0.0
var health := 0.0
var attack_target: Node3D

func _ready():
	health = max_health
	_emit_health_changed()
	_build_animation_aliases()
	add_to_group("fighters")
	if target_path != NodePath():
		attack_target = get_node_or_null(target_path)

func _build_animation_aliases():
	animation_aliases.clear()
	missing_animation_warnings.clear()
	if animation_player == null:
		return

	for animation_name in animation_player.get_animation_list():
		var key := StringName(animation_name)
		animation_aliases[key] = key

	for library_name in animation_player.get_animation_library_list():
		var animation_library = animation_player.get_animation_library(library_name)
		if animation_library == null:
			continue

		var library_key := StringName(library_name)
		for animation_name in animation_library.get_animation_list():
			var animation_key := StringName(animation_name)
			var full_name: StringName
			if library_name == "":
				full_name = animation_key
			else:
				full_name = StringName("%s/%s" % [library_name, animation_name])

			animation_aliases[full_name] = full_name
			animation_aliases[animation_key] = full_name
			if library_name != "":
				animation_aliases[library_key] = full_name

func _warn_missing_animation(name: StringName) -> void:
	if missing_animation_warnings.has(name):
		return
	missing_animation_warnings[name] = true
	push_warning("Animation not found: "%s"" % name)

func _resolve_animation_name(name: StringName) -> StringName:
	if animation_player == null:
		return StringName()
	if animation_player.has_animation(name):
		return name
	if animation_aliases.has(name):
		var alias: StringName = animation_aliases[name]
		if animation_player.has_animation(alias):
			return alias
	return StringName()

func play_animation(name: StringName) -> void:
	if animation_player == null:
		return

	var target := _resolve_animation_name(name)
	if target == StringName():
		_warn_missing_animation(name)
		return

	if animation_player.current_animation == target:
		return

	animation_player.play(target)

func _is_current_animation(name: StringName) -> bool:
	var target := _resolve_animation_name(name)
	if target == StringName():
		return false
	return animation_player != null and animation_player.current_animation == target

func _physics_process(delta):
	if not is_alive():
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		update_animation(Vector3.ZERO)
		move_and_slide()
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	if not is_cpu and Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	attack_cooldown_timer = max(attack_cooldown_timer - delta, 0.0)

	var move_input := _get_move_input()
	var direction := (transform.basis * Vector3(move_input.x, 0, move_input.y)).normalized()
	var move_speed := max(speed * movement_speed_multiplier, 0.0)

	if direction != Vector3.ZERO:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
		_face_direction(direction)
	else:
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)
		_face_target_if_available()

	if _get_attack_request():
		_start_attack()

	update_animation(direction)
	move_and_slide()

func update_animation(direction):
	# Only change animations if we are not in the middle of an attack.
	if not _is_current_animation("punch"):
		if not is_on_floor():
			play_animation("jump")
		else:
			if direction != Vector3.ZERO:
				play_animation("walk")
			else:
				play_animation("idle")

func _get_move_input() -> Vector2:
	if is_cpu:
		return _get_ai_move_input()
	return Input.get_vector("move_left", "move_right", "move_forward", "move_backward")

func _get_attack_request() -> bool:
	if is_cpu:
		return _get_ai_attack_request()
	return Input.is_action_just_pressed("punch")

func _get_ai_move_input() -> Vector2:
	var target := _select_attack_target()
	if target == null:
		return Vector2.ZERO
	var to_target := target.global_transform.origin - global_transform.origin
	to_target.y = 0.0
	var distance := Vector2(to_target.x, to_target.z).length()
	if distance <= ai_stop_distance:
		return Vector2.ZERO
	if distance == 0.0:
		return Vector2.ZERO
	return Vector2(to_target.x, to_target.z).normalized()

func _get_ai_attack_request() -> bool:
	var target := _select_attack_target()
	if target == null:
		return false
	var to_target := target.global_transform.origin - global_transform.origin
	var distance := Vector2(to_target.x, to_target.z).length()
	return distance <= ai_attack_distance and attack_cooldown_timer <= 0.0

func _face_direction(direction: Vector3) -> void:
	if model == null:
		return
	if direction.length_squared() == 0.0:
		return
	direction = direction.normalized()
	var model_origin := model.global_transform.origin
	var look_target := model_origin - direction
	look_target.y = model_origin.y
	model.look_at(look_target, Vector3.UP)

func _face_target_if_available() -> void:
	var target := _select_attack_target()
	if target == null:
		return
	var to_target := target.global_transform.origin - global_transform.origin
	to_target.y = 0.0
	if to_target.length_squared() == 0.0:
		return
	_face_direction(to_target.normalized())

func _start_attack() -> void:
	if attack_cooldown_timer > 0.0 or not is_alive():
		return
	attack_cooldown_timer = punch_cooldown
	play_animation("punch")
	_apply_attack_hit()

func _apply_attack_hit() -> void:
	var target := _select_attack_target()
	if target == null:
		return
	if not target.has_method("is_alive") or not target.is_alive():
		return
	var to_target := target.global_transform.origin - global_transform.origin
	var distance := Vector2(to_target.x, to_target.z).length()
	if distance > punch_range:
		return
	target.take_damage(punch_damage)

func _select_attack_target() -> Node3D:
	if attack_target != null and attack_target.is_inside_tree() and attack_target.has_method("is_alive") and attack_target.is_alive():
		return attack_target
	attack_target = null
	var best: Node3D
	var best_distance := INF
	for node in get_tree().get_nodes_in_group("fighters"):
		if node == self:
			continue
		if not node.has_method("is_alive"):
			continue
		if not node.is_alive():
			continue
		var node3d := node as Node3D
		if node3d == null:
			continue
		var distance := global_transform.origin.distance_squared_to(node3d.global_transform.origin)
		if distance < best_distance:
			best_distance = distance
			best = node3d
	attack_target = best
	return attack_target

func take_damage(amount: float) -> void:
	if not is_alive():
		return
	health = max(health - amount, 0.0)
	_emit_health_changed()
	if not is_alive():
		emit_signal("died")

func is_alive() -> bool:
	return health > 0.0

func set_attack_target(target: Node3D) -> void:
	attack_target = target
	if attack_target:
		target_path = attack_target.get_path()

func _emit_health_changed() -> void:
	emit_signal("health_changed", health, max_health)
