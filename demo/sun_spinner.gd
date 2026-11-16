extends DirectionalLight3D
## Demo: press T to start or stop the sun turning (round the vertical), to watch the clouds' light
## re-bake in the background as it moves.

@export var degrees_per_second : float = 3.0
@export var spinning : bool = false


func _unhandled_input(event : InputEvent) -> void:
	if event is InputEventKey and event.pressed and !event.echo and event.physical_keycode == KEY_T:
		spinning = !spinning


func _process(delta : float) -> void:
	if spinning:
		rotate_y(deg_to_rad(degrees_per_second * delta))
