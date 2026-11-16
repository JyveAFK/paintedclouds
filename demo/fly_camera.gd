extends Camera3D
## Fly camera: hold the right mouse button to look, WASD to move, E/Q up/down, Shift to go
## faster, mouse wheel to change speed.

@export var speed : float = 600.0
@export var boost : float = 6.0
@export var look_sensitivity : float = 0.003
## Demo of a gameplay hook: flying through the wisp (PaintedCloudsEffect.get_wisp_density) gives
## this speed multiplier for wisp_boost_seconds.
@export var wisp_boost : float = 2.5
@export var wisp_boost_seconds : float = 3.0

var boost_left := 0.0

var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event : InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed *= 1.25
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed /= 1.25
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta : float) -> void:
	var input := Vector3(
		Input.get_axis("fly_left", "fly_right"),
		Input.get_axis("fly_down", "fly_up"),
		Input.get_axis("fly_forward", "fly_back"))
	var velocity := global_transform.basis * Vector3(input.x, 0.0, input.z) + Vector3.UP * input.y
	var multiplier := boost if Input.is_key_pressed(KEY_SHIFT) else 1.0
	if PaintedCloudsEffect.get_wisp_density(global_position) > 0.3:
		boost_left = wisp_boost_seconds
	if boost_left > 0.0:
		boost_left -= delta
		multiplier *= wisp_boost
	global_position += velocity * speed * multiplier * delta
