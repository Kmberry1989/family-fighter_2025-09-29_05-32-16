extends CharacterBody3D

class AttackDefinition:
	var id: StringName
	var animation: StringName
	var damage: float
	var attack_range: float
	var cooldown: float
	var force_restart: bool

	func _init(attack_id: StringName, animation_name: StringName, damage_amount: float, range_value: float, cooldown_time: float, should_force_restart: bool = false):
		self.id = attack_id
		self.animation = animation_name
		self.damage = damage_amount
		self.attack_range = range_value
		self.cooldown = cooldown_time
		self.force_restart = should_force_restart

enum AiBehavior {
	ADVANCE,
	HESITATE,
	CIRCLE,
	RETREAT
}

const ATTACK_ANIMATION_NAMES = [
	StringName("punch"),
	StringName("punch_combo"),
	StringName("kick"),
	StringName("kick_combo"),
	StringName("fireball"),
	StringName("hurricane kick"),
	StringName("Reaction"),
	StringName("Standing Death Backward 01")
]

@export var speed = 5.0
@export var jump_velocity = 4.5
@export var movement_speed_multiplier = 0.5
@export var max_health = 100
@export var combo_input_window = 0.35
@export var punch_damage = 10
@export var punch_range = 1.6
@export var punch_cooldown = 0.8
@export var punch_combo_damage = 18
@export var punch_combo_range = 1.9
@export var punch_combo_cooldown = 1.15
@export var kick_damage = 14
@export var kick_range = 2.2
@export var kick_cooldown = 0.9
@export var kick_combo_damage = 26
@export var kick_combo_range = 2.5
@export var kick_combo_cooldown = 1.35
@export var is_cpu = false
@export var target_path: NodePath
@export var ai_stop_distance = 1.2
@export var ai_attack_distance = 1.6
@export var cpu_combo_bias = 0.4
@export var personal_space_distance = 1.0
@export var ai_spacing_padding = 0.45
@export var ai_min_behavior_time = 0.9
@export var ai_max_behavior_time = 2.2
@export var ai_hesitation_chance = 0.35
@export var ai_circle_chance = 0.4
@export var ai_retreat_chance = 0.25
@export var ai_retreat_distance = 3.0
@export var ai_circle_speed = 0.75
signal health_changed(current: float, maximum: float)
signal died

# This path MUST match your scene tree exactly.
@onready var model = $Model
@onready var animation_player = $Model/AnimationPlayer

var skeleton: Skeleton3D
var _animation_tracks_fixed: bool = false

var animation_aliases: Dictionary = {}
var missing_animation_warnings: Dictionary = {}
var attack_definitions: Dictionary = {}
var ai_behavior_state: int = AiBehavior.ADVANCE
var ai_behavior_timer: float = 0.0
var ai_circle_direction: float = 1.0

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var attack_cooldown_timer: float = 0.0
var health: float = 0.0
var attack_target: Node3D
var current_attack: AttackDefinition
var punch_combo_timer: float = 0.0
var kick_combo_timer: float = 0.0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready():
	rng.randomize()
	ai_behavior_timer = rng.randf_range(ai_min_behavior_time, ai_max_behavior_time)
	health = max_health
	_emit_health_changed()
	_build_attack_definitions()
	_prepare_animation_tracks()
	_build_animation_aliases()
	add_to_group("fighters")
	if target_path != NodePath():
		attack_target = get_node_or_null(target_path)

func _build_attack_definitions():
	attack_definitions.clear()
	attack_definitions[StringName("punch")] = AttackDefinition.new(StringName("punch"), StringName("punch"), punch_damage, punch_range, punch_cooldown)
	attack_definitions[StringName("punch_combo")] = AttackDefinition.new(StringName("punch_combo"), StringName("punch_combo"), punch_combo_damage, punch_combo_range, punch_combo_cooldown, true)
	attack_definitions[StringName("kick")] = AttackDefinition.new(StringName("kick"), StringName("kick"), kick_damage, kick_range, kick_cooldown)
	attack_definitions[StringName("kick_combo")] = AttackDefinition.new(StringName("kick_combo"), StringName("kick_combo"), kick_combo_damage, kick_combo_range, kick_combo_cooldown, true)
	ai_attack_distance = max(ai_attack_distance, attack_definitions[StringName("kick_combo")].attack_range)

# Align imported animation tracks with the skeleton name used in the scene.
func _prepare_animation_tracks() -> void:
	if _animation_tracks_fixed:
		return
	if animation_player == null or model == null:
		return
	var detected_skeleton: Skeleton3D = _find_first_skeleton(model)
	if detected_skeleton == null:
		return
	skeleton = detected_skeleton
	if animation_player.root_node != NodePath(".."):
		animation_player.root_node = NodePath("..")
	var skeleton_name: StringName = skeleton.name
	for library_name in animation_player.get_animation_library_list():
		var animation_library: AnimationLibrary = animation_player.get_animation_library(library_name)
		if animation_library == null:
			continue
		for animation_name in animation_library.get_animation_list():
			var animation: Animation = animation_library.get_animation(animation_name)
			if animation == null:
				continue
			_retarget_skeleton_tracks(animation, skeleton_name)
	_animation_tracks_fixed = true

func _retarget_skeleton_tracks(animation: Animation, skeleton_name: StringName) -> void:
	var root = animation_player.get_node(animation_player.root_node)
	if not root:
		return

	for track_index in range(animation.get_track_count()):
		var track_path: NodePath = animation.track_get_path(track_index)
		if track_path.get_name_count() == 0:
			continue

		var first_node_name = track_path.get_name(0)
		var node = root.get_node_or_null(first_node_name)

		if node is Skeleton3D:
			var updated_path: NodePath = _with_retargeted_skeleton_name(track_path, skeleton_name)
			if updated_path != track_path:
				animation.track_set_path(track_index, updated_path)

func _with_retargeted_skeleton_name(path: NodePath, skeleton_name: StringName) -> NodePath:
	var names: Array = []
	for index in range(path.get_name_count()):
		var name_component: StringName = path.get_name(index)
		if index == 0:
			names.append(skeleton_name)
		else:
			names.append(name_component)
	var subnames: Array = []
	for sub_index in range(path.get_subname_count()):
		subnames.append(path.get_subname(sub_index))
	var path_string := ""
	if path.is_absolute():
		path_string = "/"
	if names.size() > 0:
		path_string += String(names[0])
		for index in range(1, names.size()):
			path_string += "/" + String(names[index])
	elif path_string == "":
		path_string = "."
	if subnames.size() > 0:
		path_string += ":" + String(subnames[0])
		for index in range(1, subnames.size()):
			path_string += ":" + String(subnames[index])
	return NodePath(path_string)

func _find_first_skeleton(root: Node) -> Skeleton3D:
	if root == null:
		return null
	if root is Skeleton3D:
		return root
	for child in root.get_children():
		var skeleton_child: Skeleton3D = _find_first_skeleton(child)
		if skeleton_child != null:
			return skeleton_child
	return null

func _build_animation_aliases():
	animation_aliases.clear()
	missing_animation_warnings.clear()
	if animation_player == null:
		return

	for animation_name in animation_player.get_animation_list():
		var key: StringName = StringName(animation_name)
		animation_aliases[key] = key

	for library_name in animation_player.get_animation_library_list():
		var animation_library = animation_player.get_animation_library(library_name)
		if animation_library == null:
			continue

		var library_key: StringName = StringName(library_name)
		for animation_name in animation_library.get_animation_list():
			var animation_key: StringName = StringName(animation_name)
			var full_name: StringName
			if library_name == "":
				full_name = animation_key
			else:
				full_name = StringName("%s/%s" % [library_name, animation_name])

			animation_aliases[full_name] = full_name
			animation_aliases[animation_key] = full_name
			if library_name != "":
				animation_aliases[library_key] = full_name

	_configure_animation_overrides()

func _configure_animation_overrides() -> void:
	_alias_animation_from_substrings(StringName("punch_combo"), [
		"combo",
		"flurry",
		"punch"
	], StringName("punch"))
	_alias_animation_from_substrings(StringName("kick"), [
		"kick",
		"roundhouse"
	], StringName("punch"))
	_alias_animation_from_substrings(StringName("kick_combo"), [
		"combo",
		"hurricane",
		"roundhouse",
		"spin",
		"kick"
	], StringName("kick"))
	_prefer_animation(StringName("punch"), [
		"punch1",
		"punch"
	], StringName("punch"))
	_prefer_animation(StringName("punch_combo"), [
		"punch2",
		"punch1",
		"punch_combo",
		"punch"
	], StringName("punch"))
	_prefer_animation(StringName("kick"), [
		"kick1",
		"kick"
	], StringName("kick"))
	_prefer_animation(StringName("kick_combo"), [
		"kick2",
		"hurricane kick",
		"kick1",
		"kick_combo",
		"kick"
	], StringName("kick"))
	_prefer_animation(StringName("fireball"), [
		"fireball"
	], StringName("punch"))
	_prefer_animation(StringName("hurricane kick"), [
		"hurricane kick",
		"kick2"
	], StringName("kick"))
	_prefer_animation(StringName("idle"), [
		"idle",
		"DonaldIdle",
		"margoidle",
		"idle (2)"
	], StringName("idle"))
	_prefer_animation(StringName("walk"), [
		"walk",
		"DonaldWalk"
	], StringName("idle"))
	_prefer_animation(StringName("Reaction"), [
		"Reaction",
		"reaction"
	], StringName("idle"))
	_prefer_animation(StringName("Standing Death Backward 01"), [
		"Standing Death Backward 01",
		"standing death backward 01"
	], StringName("Reaction"))
func _lookup_animation(animation_name: StringName) -> StringName:
	return _resolve_animation_name(animation_name)

func _alias_animation(alias_name: StringName, existing_animation: StringName) -> void:
	if animation_player != null and animation_player.has_animation(alias_name):
		return
	if _lookup_animation(alias_name) != StringName():
		return
	var resolved: StringName = _lookup_animation(existing_animation)
	if resolved != StringName():
		animation_aliases[alias_name] = resolved

func _get_or_create_target_library() -> AnimationLibrary:
	if animation_player == null:
		return null
	var default_library_name: StringName = StringName("")
	var library: AnimationLibrary = animation_player.get_animation_library(default_library_name)
	if library == null:
		var library_names: PackedStringArray = animation_player.get_animation_library_list()
		for name_value in library_names:
			var candidate_library: AnimationLibrary = animation_player.get_animation_library(StringName(name_value))
			if candidate_library != null:
				return candidate_library
		library = AnimationLibrary.new()
		animation_player.add_animation_library(default_library_name, library)
	return library

func _alias_animation_from_substrings(alias_name: StringName, substrings: Array, fallback_animation: StringName) -> void:
	if animation_player == null:
		return
	if animation_player.has_animation(alias_name):
		return
	if _lookup_animation(alias_name) != StringName():
		return
	var animation_names: PackedStringArray = animation_player.get_animation_list()
	for name_value in animation_names:
		var name_string: String = String(name_value)
		var lower_name: String = name_string.to_lower()
		for substring_value in substrings:
			var lower_substring: String = String(substring_value).to_lower()
			if lower_substring == "":
				continue
			if lower_name.find(lower_substring) != -1:
				var candidate_name: StringName = StringName(name_string)
				var resolved: StringName = _lookup_animation(candidate_name)
				if resolved != StringName():
					animation_aliases[alias_name] = resolved
					return
	_alias_animation(alias_name, fallback_animation)

func _prefer_animation(alias_name: StringName, candidate_names: Array, fallback_animation: StringName = StringName()) -> void:
	if animation_player == null:
		return
	for candidate_value in candidate_names:
		var candidate_name: StringName = StringName(candidate_value)
		var resolved: StringName = _lookup_animation(candidate_name)
		if resolved != StringName():
			animation_aliases[alias_name] = resolved
			return
	if fallback_animation != StringName():
		_alias_animation(alias_name, fallback_animation)

func _ensure_animation_loaded(target_name: StringName, source_paths: Array) -> bool:
	if animation_player == null:
		return false
	if animation_player.has_animation(target_name):
		return true
	for source_path_value in source_paths:
		var source_path: String = String(source_path_value)
		if not ResourceLoader.exists(source_path):
			continue
		var packed_scene: Resource = ResourceLoader.load(source_path)
		if packed_scene is PackedScene:
			var instance: Node = (packed_scene as PackedScene).instantiate()
			if instance == null:
				continue
			var source_player: AnimationPlayer = instance.find_child("AnimationPlayer", true, false) as AnimationPlayer
			if source_player == null:
				instance.free()
				continue
			var source_names: PackedStringArray = source_player.get_animation_list()
			for source_name_value in source_names:
				var source_animation: Animation = source_player.get_animation(source_name_value)
				if source_animation == null:
					continue
				var duplicate_animation: Animation = source_animation.duplicate(true)
				var target_library: AnimationLibrary = _get_or_create_target_library()
				if target_library == null:
					instance.free()
					continue
				if target_library.has_animation(target_name):
					instance.free()
					return true
				target_library.add_animation(target_name, duplicate_animation)
				animation_aliases[target_name] = target_name
				instance.free()
				return true
			instance.free()
	return false

func _warn_missing_animation(animation_name: StringName) -> void:
	if missing_animation_warnings.has(animation_name):
		return
	missing_animation_warnings[animation_name] = true
	push_warning('Animation not found: "%s"' % animation_name)

func _resolve_animation_name(animation_name: StringName) -> StringName:
	if animation_player == null:
		return StringName()
	var visited: Dictionary = {}
	var pending: Array = [animation_name]
	while pending.size() > 0:
		var current: StringName = pending.pop_front()
		if visited.has(current):
			continue
		visited[current] = true
		if animation_aliases.has(current):
			var alias: StringName = animation_aliases[current]
			if animation_player.has_animation(alias):
				return alias
			if alias != current and not visited.has(alias):
				pending.push_front(alias)
		if animation_player.has_animation(current):
			return current
	return StringName()

func play_animation(animation_name: StringName, force_restart: bool = false) -> void:
	if animation_player == null:
		return

	var target: StringName = _resolve_animation_name(animation_name)
	if target == StringName():
		_warn_missing_animation(animation_name)
		return

	if animation_player.current_animation == target and not force_restart:
		return

	animation_player.play(target)

func _is_current_animation(animation_name: StringName) -> bool:
	var target: StringName = _resolve_animation_name(animation_name)
	if target == StringName():
		return false
	return animation_player != null and animation_player.current_animation == target

func _physics_process(delta):
	if not is_alive():
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		move_and_slide()
		_keep_model_grounded()
		return

	if current_attack != null and not _is_current_animation(current_attack.animation):
		current_attack = null

	if is_cpu:
		_update_ai_behavior(delta)

	if not is_on_floor():
		velocity.y -= gravity * delta
	elif not is_cpu and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	attack_cooldown_timer = max(attack_cooldown_timer - delta, 0.0)
	punch_combo_timer = max(punch_combo_timer - delta, 0.0)
	kick_combo_timer = max(kick_combo_timer - delta, 0.0)

	var move_input: Vector2 = _get_move_input()
	var desired_motion: Vector3 = transform.basis * Vector3(move_input.x, 0, move_input.y)
	var direction: Vector3 = Vector3.ZERO
	if desired_motion.length_squared() > 0.0:
		direction = desired_motion.normalized()

	if _is_current_animation(StringName("Reaction")):
		direction = Vector3.ZERO

	direction = _constrain_direction_for_personal_space(direction)

	var move_speed: float = max(speed * movement_speed_multiplier, 0.0)

	if direction != Vector3.ZERO:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
		_face_direction(direction)
	else:
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)
		_face_target_if_available()

	_process_attack_inputs()
	update_animation(direction)
	move_and_slide()
	#_keep_model_grounded()

func update_animation(direction):
	for attack_name in ATTACK_ANIMATION_NAMES:
		if _is_current_animation(attack_name):
			return

	if not is_on_floor():
		play_animation(StringName("jump"))
	else:
		if direction != Vector3.ZERO:
			play_animation(StringName("walk"))
		else:
			play_animation(StringName("idle"))

func _get_move_input() -> Vector2:
	if is_cpu:
		return _get_ai_move_input()
	return Input.get_vector("move_left", "move_right", "move_forward", "move_backward")

func _process_attack_inputs() -> void:
	if is_cpu:
		var ai_attack: StringName = _get_ai_attack_request()
		if ai_attack != StringName():
			_start_attack(ai_attack)
		return

	if Input.is_action_just_pressed("punch"):
		var use_combo: bool = punch_combo_timer > 0.0
		var attack_id: StringName = StringName("punch_combo") if use_combo else StringName("punch")
		if _start_attack(attack_id):
			punch_combo_timer = 0.0 if use_combo else combo_input_window
		elif not use_combo:
			punch_combo_timer = combo_input_window

	if Input.is_action_just_pressed("kick"):
		var use_combo: bool = kick_combo_timer > 0.0
		var attack_id: StringName = StringName("kick_combo") if use_combo else StringName("kick")
		if _start_attack(attack_id):
			kick_combo_timer = 0.0 if use_combo else combo_input_window
		elif not use_combo:
			kick_combo_timer = combo_input_window

func _update_ai_behavior(delta: float) -> void:
	if not is_cpu:
		return
	ai_behavior_timer -= delta
	if ai_behavior_timer > 0.0:
		return
	ai_behavior_timer = rng.randf_range(ai_min_behavior_time, ai_max_behavior_time)
	var distance: float = _distance_to_target()
	if distance == INF:
		ai_behavior_state = AiBehavior.ADVANCE
		return
	if distance > ai_retreat_distance:
		ai_behavior_state = AiBehavior.ADVANCE
		return
	var roll: float = rng.randf()
	if distance < ai_stop_distance - ai_spacing_padding and roll < ai_retreat_chance:
		ai_behavior_state = AiBehavior.RETREAT
		return
	if roll < ai_hesitation_chance:
		ai_behavior_state = AiBehavior.HESITATE
	elif roll < ai_hesitation_chance + ai_circle_chance:
		ai_behavior_state = AiBehavior.CIRCLE
		if rng.randf() < 0.5:
			ai_circle_direction *= -1.0
	elif roll < ai_hesitation_chance + ai_circle_chance + ai_retreat_chance:
		ai_behavior_state = AiBehavior.RETREAT
	else:
		ai_behavior_state = AiBehavior.ADVANCE

func _distance_to_target() -> float:
	var target: Node3D = _select_attack_target()
	if target == null:
		return INF
	var delta: Vector3 = target.global_transform.origin - global_transform.origin
	delta.y = 0.0
	return Vector2(delta.x, delta.z).length()

func _constrain_direction_for_personal_space(direction: Vector3) -> Vector3:
	if not is_cpu:
		return direction
	if direction.length_squared() == 0.0:
		return direction
	if _is_current_animation(StringName("Standing Death Backward 01")):
		return Vector3.ZERO
	var target: Node3D = _select_attack_target()
	if target == null:
		return direction
	if target.has_method("is_in_hit_reaction") and target.is_in_hit_reaction():
		return direction
	var to_target: Vector3 = target.global_transform.origin - global_transform.origin
	to_target.y = 0.0
	if to_target.length_squared() == 0.0:
		return direction
	var min_distance: float = personal_space_distance
	if is_cpu:
		min_distance = max(ai_stop_distance, personal_space_distance)
	var distance: float = Vector2(to_target.x, to_target.z).length()
	if distance > min_distance + ai_spacing_padding:
		return direction
	var forward: Vector3 = to_target.normalized()
	var toward_amount: float = direction.dot(forward)
	if toward_amount <= 0.0:
		return direction
	var adjusted: Vector3 = direction - forward * toward_amount
	if adjusted.length_squared() <= 0.0001:
		return Vector3.ZERO
	return adjusted.normalized()

func _world_to_local(direction: Vector3) -> Vector3:
	return global_transform.basis.inverse() * direction

func _keep_model_grounded() -> void:
	if model == null:
		return
	var local_transform: Transform3D = model.transform
	local_transform.origin = Vector3.ZERO
	model.transform = local_transform

func _get_ai_move_input() -> Vector2:
	var target: Node3D = _select_attack_target()
	if target == null:
		return Vector2.ZERO
	var to_target: Vector3 = target.global_transform.origin - global_transform.origin
	to_target.y = 0.0
	var distance: float = Vector2(to_target.x, to_target.z).length()
	if distance == 0.0:
		return Vector2.ZERO

	var forward: Vector3 = to_target.normalized()
	var local_forward: Vector3 = _world_to_local(forward)
	var desired: Vector2 = Vector2.ZERO

	match ai_behavior_state:
		AiBehavior.HESITATE:
			desired = Vector2.ZERO
		AiBehavior.CIRCLE:
			var tangent: Vector3 = forward.cross(Vector3.UP)
			if tangent.length_squared() > 0.0:
				tangent = tangent.normalized() * ai_circle_direction
				var local_tangent: Vector3 = _world_to_local(tangent)
				var tangential: Vector2 = Vector2(local_tangent.x, local_tangent.z) * ai_circle_speed
				var radial_error: float = clamp(distance - (ai_stop_distance + ai_spacing_padding), -1.0, 1.0)
				var radial_correction: Vector3 = -local_forward * radial_error
				desired = tangential + Vector2(radial_correction.x, radial_correction.z) * 0.5
		AiBehavior.RETREAT:
			if distance < ai_retreat_distance:
				var local_back: Vector3 = -local_forward
				desired = Vector2(local_back.x, local_back.z)
		AiBehavior.ADVANCE:
			if distance > ai_stop_distance + ai_spacing_padding:
				desired = Vector2(local_forward.x, local_forward.z)

	if desired.length_squared() == 0.0:
		if distance > ai_attack_distance:
			desired = Vector2(local_forward.x, local_forward.z)
		elif distance < ai_stop_distance:
			desired = Vector2.ZERO

	if desired.length_squared() > 0.0:
		desired = desired.normalized()

	return desired

func _get_ai_attack_request() -> StringName:
	var target: Node3D = _select_attack_target()
	if target == null:
		return StringName()
	if attack_cooldown_timer > 0.0:
		return StringName()
	var to_target: Vector3 = target.global_transform.origin - global_transform.origin
	var distance: float = Vector2(to_target.x, to_target.z).length()
	var punch_combo_range_value: float = attack_definitions[StringName("punch_combo")].attack_range
	var punch_range_value: float = attack_definitions[StringName("punch")].attack_range
	var kick_combo_range_value: float = attack_definitions[StringName("kick_combo")].attack_range
	var kick_range_value: float = attack_definitions[StringName("kick")].attack_range
	if distance <= min(punch_combo_range_value, punch_range_value):
		if rng.randf() < cpu_combo_bias:
			return StringName("punch_combo")
		return StringName("punch")
	if distance <= kick_range_value:
		if distance <= kick_combo_range_value and rng.randf() < cpu_combo_bias:
			return StringName("kick_combo")
		return StringName("kick")
	return StringName()

func _start_attack(attack_id: StringName) -> bool:
	var attack_def: AttackDefinition = attack_definitions.get(attack_id, null)
	if attack_def == null:
		_warn_missing_animation(attack_id)
		return false
	if attack_cooldown_timer > 0.0 or not is_alive():
		return false
	attack_cooldown_timer = attack_def.cooldown
	current_attack = attack_def
	play_animation(attack_def.animation, attack_def.force_restart)
	_apply_attack_hit(attack_def)
	return true

func _face_direction(direction: Vector3) -> void:
	if model == null:
		return
	if direction.length_squared() == 0.0:
		return
	direction = direction.normalized()
	var model_origin: Vector3 = model.global_transform.origin
	var look_target: Vector3 = model_origin - direction
	look_target.y = model_origin.y
	model.look_at(look_target, Vector3.UP)

func _face_target_if_available() -> void:
	var target: Node3D = _select_attack_target()
	if target == null:
		return
	var to_target: Vector3 = target.global_transform.origin - global_transform.origin
	to_target.y = 0.0
	if to_target.length_squared() == 0.0:
		return
	_face_direction(to_target.normalized())

func _apply_attack_hit(attack_def: AttackDefinition) -> void:
	var target: Node3D = _select_attack_target()
	if target == null:
		return
	if not target.has_method("is_alive") or not target.is_alive():
		return
	var to_target: Vector3 = target.global_transform.origin - global_transform.origin
	var distance: float = Vector2(to_target.x, to_target.z).length()
	if distance > attack_def.attack_range:
		return
	target.take_damage(attack_def.damage)

func _select_attack_target() -> Node3D:
	if attack_target != null and attack_target.is_inside_tree() and attack_target.has_method("is_alive") and attack_target.is_alive():
		return attack_target
	attack_target = null
	var best: Node3D
	var best_distance: float = INF
	for node in get_tree().get_nodes_in_group("fighters"):
		if node == self:
			continue
		if not node.has_method("is_alive"):
			continue
		if not node.is_alive():
			continue
		var node3d: Node3D = node as Node3D
		if node3d == null:
			continue
		var distance: float = global_transform.origin.distance_squared_to(node3d.global_transform.origin)
		if distance < best_distance:
			best_distance = distance
			best = node3d
	attack_target = best
	return attack_target

func take_damage(amount: float) -> void:
	if not is_alive():
		return
	if amount <= 0.0:
		return
	health = max(health - amount, 0.0)
	_emit_health_changed()
	current_attack = null
	if is_alive():
		play_animation(StringName("Reaction"), true)
	else:
		play_animation(StringName("Standing Death Backward 01"), true)
		emit_signal("died")

func is_alive() -> bool:
	return health > 0.0

func is_in_hit_reaction() -> bool:
	if not is_alive():
		return true
	return _is_current_animation(StringName("Reaction"))

func set_attack_target(target: Node3D) -> void:
	attack_target = target
	if attack_target:
		target_path = attack_target.get_path()

func _emit_health_changed() -> void:
	emit_signal("health_changed", health, max_health)
