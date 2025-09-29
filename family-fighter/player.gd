extends CharacterBody3D

@export var speed = 5.0
@export var jump_velocity = 4.5

# This path MUST match your scene tree exactly.
@onready var model = $Model
@onready var animation_player = $Model/AnimationPlayer

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _ready():
	_rename_animations()

func _rename_animations():
	if animation_player:
		var library_names = animation_player.get_animation_library_list()
		for lib_name in library_names:
			var animation_library = animation_player.get_animation_library(lib_name)
			if animation_library:
				var animation_names = animation_library.get_animation_list()
				for anim_name in animation_names:
					if anim_name == "mixamo_com":
						animation_library.rename_animation(anim_name, lib_name)
func _physics_process(delta):
	# Add gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle Jump.
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	# Handle Punch Action.
	if Input.is_action_just_pressed("punch") and is_on_floor():
		animation_player.play("punch") # <-- Corrected to lowercase

	# Handle Movement.
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		model.look_at(position + direction)
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	# Update animations based on the state.
	update_animation(direction)

	move_and_slide()

func update_animation(direction):
	# Only change animations if we are not in the middle of an attack.
	if animation_player.current_animation != "punch": # <-- Corrected to lowercase
		if not is_on_floor():
			animation_player.play("jump") # <-- Corrected to lowercase
		else:
			if direction != Vector3.ZERO:
				animation_player.play("walk") # <-- Corrected to lowercase
			else:
				animation_player.play("idle") # <-- Corrected to lowercase
