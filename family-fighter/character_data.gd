extends Resource

class_name CharacterData

@export var model_scene: PackedScene
@export var max_health: float = 100.0
@export var speed: float = 5.0
@export var jump_velocity: float = 4.5

# Maps generic attack names like "punch", "kick" to AttackDefinition resources
@export var attacks: Dictionary = {}

# Maps generic animation names like "idle", "walk" to Animation resources
@export var animations: Dictionary = {}
