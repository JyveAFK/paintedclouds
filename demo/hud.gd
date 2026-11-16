extends Label
## Shows the gameplay cloud queries at the camera, as a game would use them: density and distance
## to the surface, sunlight, line of sight to the red beacon (behind the big tower), and moves the
## yellow marker to the hold point hold_offset metres off the nearest cloud.
## Spread over frames, as an AI should (one query group a frame, each refreshed every
## `interval` seconds), with each one's cost shown.

@export var beacon : Node3D
@export var hold_marker : Node3D
## Where the hold point sits from the cloud surface (m): positive outside, negative inside.
@export var hold_offset : float = 300.0
## Seconds between refreshes of each query.
@export var interval : float = 0.25

var _timer := 0.0
var _effect : PaintedCloudsEffect
var _next := 0
var _lines := ["", "", "", ""]


func _process(delta : float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var p := camera.global_position
	# One query group per frame, round robin, a group every interval / 4.
	_timer -= delta
	if _timer <= 0.0:
		_timer = interval / 4.0
		_run(_next, p)
		_next = (_next + 1) % 4
	var status_line := ""
	if PaintedCloudTileWorld.active:
		var status := PaintedCloudTileWorld.active.get_status()
		var cell : Vector2i = Vector2i((Vector2(p.x, p.z) / PaintedCloudTileWorld.active.cell_size).floor()) + status.offset_cells
		status_line = "\ntiles %d / %d ready, far %d / %d, horizon %d / %d, %d bakes waiting, cell %s, origin offset %s cells   (T: turn the sun)" % [
			status.ready, status.wanted, status.far_ready, status.far_wanted, status.horizon_ready, status.horizon_wanted,
			status.jobs, cell, status.offset_cells]
	if PaintedCloudsEffect.is_wisp_out():
		var in_wisp := PaintedCloudsEffect.get_wisp_density(p)
		status_line += "\nwisp out: %s" % ("INSIDE (density %.2f): boost!" % in_wisp if in_wisp > 0.3 else "fly through it for a boost")
	elif float(camera.get("boost_left") if "boost_left" in camera else 0.0) > 0.0:
		status_line += "\nwisp boost: %.1f s left" % float(camera.get("boost_left"))
	status_line += "\n" + _filters_line()
	text = "%d fps   altitude %d m   speed %d m/s\n%s%s\nRMB look, WASD move, E/Q up/down, Shift faster, wheel speed" % [
		Engine.get_frames_per_second(), p.y, camera.speed if "speed" in camera else 0.0,
		"\n".join(_lines), status_line]


# Demo keys for the paint filters: 1 Kuwahara (off / classic / anisotropic), 2 watercolour,
# 3 canvas grain, 4 ink outlines, 5 hue-shifted shadows, 6 rim bloom, 9 all of them, 0 none.
func _unhandled_input(event : InputEvent) -> void:
	if !(event is InputEventKey and event.pressed and !event.echo):
		return
	var effect := _find_effect()
	if effect == null:
		return
	match event.physical_keycode:
		KEY_1:
			effect.kuwahara = (effect.kuwahara + 1) % 3 as PaintedCloudsEffect.KuwaharaMode
		KEY_2:
			effect.watercolor_strength = 0.0 if effect.watercolor_strength > 0.0 else 0.7
		KEY_3:
			effect.grain_strength = 0.0 if effect.grain_strength > 0.0 else 0.6
		KEY_4:
			effect.ink_strength = 0.0 if effect.ink_strength > 0.0 else 0.6
		KEY_5:
			effect.hue_shift_strength = 0.0 if effect.hue_shift_strength > 0.0 else 0.7
		KEY_6:
			effect.rim_bloom_strength = 0.0 if effect.rim_bloom_strength > 0.0 else 0.8
		KEY_9:
			effect.kuwahara = PaintedCloudsEffect.KuwaharaMode.ANISOTROPIC
			effect.watercolor_strength = 0.5
			effect.grain_strength = 0.4
			effect.ink_strength = 0.35
			effect.hue_shift_strength = 0.5
			effect.rim_bloom_strength = 0.6
		KEY_0:
			effect.kuwahara = PaintedCloudsEffect.KuwaharaMode.OFF
			effect.watercolor_strength = 0.0
			effect.grain_strength = 0.0
			effect.ink_strength = 0.0
			effect.hue_shift_strength = 0.0
			effect.rim_bloom_strength = 0.0


func _find_effect() -> PaintedCloudsEffect:
	if _effect == null:
		for node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
			var compositor : Compositor = node.compositor
			if compositor:
				for e in compositor.compositor_effects:
					if e is PaintedCloudsEffect:
						_effect = e
	return _effect


func _filters_line() -> String:
	var effect := _find_effect()
	if effect == null:
		return ""
	var on := func(v : float) -> String: return "on" if v > 0.0 else "off"
	return "filters: 1 kuwahara %s, 2 watercolour %s, 3 grain %s, 4 ink %s, 5 hue shift %s, 6 rim bloom %s   (9 all, 0 none)" % [
		["off", "classic", "anisotropic"][effect.kuwahara], on.call(effect.watercolor_strength), on.call(effect.grain_strength),
		on.call(effect.ink_strength), on.call(effect.hue_shift_strength), on.call(effect.rim_bloom_strength)]


func _run(group : int, p : Vector3) -> void:
	var started := Time.get_ticks_usec()
	match group:
		0:
			var distance := PaintedCloudWorld.get_distance(p)
			var density := PaintedCloudWorld.get_density(p)
			var sunlight := PaintedCloudWorld.get_sunlight(p)
			var state := "inside cloud" if density > 0.6 else ("at the edge" if density > 0.05 else "clear air")
			_lines[0] = "cloud: %s   density %.2f   surface %s   sunlight %.2f   (%s)" % [
				state, density, "%d m" % distance if distance < 1e6 else "far", sunlight, _cost(started)]
		1:
			if beacon:
				var visibility := PaintedCloudWorld.get_visibility(p, beacon.global_position)
				_lines[1] = "beacon: visibility %.2f (%s)   (%s)" % [visibility, "HIDDEN" if visibility < 0.1 else "seen", _cost(started)]
		2:
			if hold_marker:
				var hold := PaintedCloudWorld.get_hold_point(p, hold_offset)
				hold_marker.visible = hold != p
				hold_marker.global_position = hold
				_lines[2] = "hold point %+d m off the cloud: %d m away   (%s)" % [hold_offset, p.distance_to(hold), _cost(started)]
		3:
			var to_cloud := PaintedCloudWorld.get_direction_to_cloud(p)
			_lines[3] = "cover direction %s   (%s)" % [
				"none near" if to_cloud == Vector3.ZERO else "(%.2f, %.2f, %.2f)" % [to_cloud.x, to_cloud.y, to_cloud.z], _cost(started)]


func _cost(started : int) -> String:
	return "%.2f ms" % ((Time.get_ticks_usec() - started) / 1000.0)
