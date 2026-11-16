@tool
extends RefCounted
class_name PaintedCloudWorld
## Gameplay queries about the clouds, answered on the CPU from the registered bakes (PaintedCloudVolumes
## and a PaintedCloudTileWorld's near and far tiles). All positions are world space (m).
##
##   PaintedCloudWorld.get_density(pos)                 0 clear .. 1 inside
##   PaintedCloudWorld.get_distance(pos)                signed metres to the nearest cloud surface
##   PaintedCloudWorld.get_sunlight(pos)                0 shaded .. 1 full sun through the clouds
##   PaintedCloudWorld.get_visibility(from, to)         1 clear line of sight .. 0 hidden by cloud
##   PaintedCloudWorld.is_hidden(from, to)              true when the clouds block the view
##   PaintedCloudWorld.raycast(from, to)                where the line first enters cloud
##   PaintedCloudWorld.get_direction_to_cloud(pos)      towards cover (deeper, when inside)
##   PaintedCloudWorld.get_direction_to_clear_air(pos)  out of cloud by the shortest way
##   PaintedCloudWorld.get_hold_point(pos, offset)      the nearest point at offset metres from the
##                                               cloud surface (negative = inside)
##   PaintedCloudWorld.run_async(query, done)           any of these on a worker thread
##
## Rough costs (GDScript): density, distance or sunlight a few to tens of microseconds; line of
## sight and hold point well under a millisecond to a few. For many ships, stagger them (each
## ship every few seconds, not all in one frame) or run them with run_async().

# Replaced, never changed in place (copy on write), so a worker thread running a query keeps a
# consistent list while bakes come and go.
static var _bakes : Array[PaintedCloudBake] = []
static var _last : PaintedCloudBake # The bake the last lookup found: queries cluster in space.
static var _softness_value := 300.0
static var _voxel_value := 200.0
static var _max_distance_value := 4000.0


static func register_bake(bake : PaintedCloudBake) -> void:
	if bake and !_bakes.has(bake):
		var bakes := _bakes.duplicate()
		bakes.append(bake)
		# Finest first, so lookups find them first.
		bakes.sort_custom(func(a : PaintedCloudBake, b : PaintedCloudBake) -> bool: return a.tier < b.tier)
		_bakes = bakes
		_update_settings()


static func unregister_bake(bake : PaintedCloudBake) -> void:
	if _bakes.has(bake):
		var bakes := _bakes.duplicate()
		bakes.erase(bake)
		_bakes = bakes
		if _last == bake:
			_last = null
		_update_settings()


static func get_bakes() -> Array[PaintedCloudBake]:
	return _bakes


## Runs query (a Callable returning a value, e.g. func(): return PaintedCloudWorld.get_visibility(a, b))
## on a worker thread, then calls done(value) on the main thread. Returns the WorkerThreadPool
## task id.
static func run_async(query : Callable, done : Callable) -> int:
	var task := func() -> void:
		var value : Variant = query.call()
		done.call_deferred(value)
	return WorkerThreadPool.add_task(task, false, "PaintedCloudWorld query")


## Signed distance (m) from position to the nearest cloud surface: negative inside. Far from any
## cloud it reads at most the bake's max_distance (the field doesn't know further than that);
## INF with no bakes.
static func get_distance(position : Vector3) -> float:
	var bake := _find(position)
	if bake:
		return bake.sample_channel(position, PaintedCloudBake.CHANNEL_DISTANCE)
	# Outside every bake: a guess from the nearest one's edge.
	var nearest : PaintedCloudBake = null
	var nearest_gap := INF
	for candidate in _bakes:
		if candidate.has_data():
			var gap := candidate.distance_to_box(position)
			if gap < nearest_gap:
				nearest_gap = gap
				nearest = candidate
	return nearest.get_distance(position) if nearest else INF


## Rough cloud density: 0 in clear air, rising through the soft edge to 1 inside.
static func get_density(position : Vector3) -> float:
	return clampf(0.5 - get_distance(position) / (2.0 * _softness_value), 0.0, 1.0)


## How much direct sunlight reaches position through the clouds: 1 = full sun, 0 = deep shade.
## (The same value the cloud-shadowed ship material uses.) 1 outside every bake.
static func get_sunlight(position : Vector3) -> float:
	var bake := _find(position)
	return clampf(bake.sample_channel(position, PaintedCloudBake.CHANNEL_SUN), 0.0, 1.0) if bake else 1.0


## How much sky light reaches position (less under thick cloud): 1 outside every bake.
static func get_skylight(position : Vector3) -> float:
	var bake := _find(position)
	return clampf(bake.sample_channel(position, PaintedCloudBake.CHANNEL_SKY), 0.0, 1.0) if bake else 1.0


## The way out of the nearest cloud surface (the distance field's gradient), or ZERO when no
## cloud is within the field's max_distance (or position is exactly between two, outside them).
static func get_cloud_normal(position : Vector3) -> Vector3:
	var here := get_distance(position)
	if here >= _max_distance_value * 0.9:
		return Vector3.ZERO
	var e := _voxel_value * 0.75
	var gradient := Vector3(
		get_distance(position + Vector3(e, 0, 0)) - get_distance(position - Vector3(e, 0, 0)),
		get_distance(position + Vector3(0, e, 0)) - get_distance(position - Vector3(0, e, 0)),
		get_distance(position + Vector3(0, 0, e)) - get_distance(position - Vector3(0, 0, e)))
	# A true distance field changes by 2e across the probes; much less means a ridge: the middle
	# of a cloud (probe for the way out) or halfway between two outside (no one way: ZERO).
	if gradient.length() > e * 0.2:
		return gradient.normalized()
	return _probe_outward(position, here) if here < 0.0 else Vector3.ZERO


const _PROBES : Array[Vector3] = [
	Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
	Vector3(0.577, 0.577, 0.577), Vector3(-0.577, 0.577, 0.577), Vector3(0.577, -0.577, 0.577), Vector3(-0.577, -0.577, 0.577),
	Vector3(0.577, 0.577, -0.577), Vector3(-0.577, 0.577, -0.577), Vector3(0.577, -0.577, -0.577), Vector3(-0.577, -0.577, -0.577),
]


# Inside a cloud, on a ridge of the field: the direction, of 14 round position, whose distance
# grows most (the nearest way out).
static func _probe_outward(position : Vector3, here : float) -> Vector3:
	var reach := maxf(absf(here), _voxel_value * 2.0)
	var best := Vector3.ZERO
	var best_gain := 0.0
	for dir in _PROBES:
		var gain := get_distance(position + dir * reach) - here
		if gain > best_gain:
			best_gain = gain
			best = dir
	return best


## Towards the nearest cloud (cover), or deeper in when already inside. ZERO when no cloud is
## within the field's max_distance.
static func get_direction_to_cloud(position : Vector3) -> Vector3:
	return -get_cloud_normal(position)


## The shortest way out of cloud (or further from it when outside). ZERO when no cloud is near.
static func get_direction_to_clear_air(position : Vector3) -> Vector3:
	return get_cloud_normal(position)


## True when there's cloud within radius (m) of position.
static func has_cloud_within(position : Vector3, radius : float) -> bool:
	return get_distance(position) <= radius


## The nearest point to position that's offset metres from the cloud surface: positive outside
## (e.g. a refuelling boom's reach), negative inside (creeping along with a probe out), 0 on the
## surface. Returns position unchanged when no cloud is within the field's max_distance.
static func get_hold_point(position : Vector3, offset : float = 0.0, tolerance : float = 10.0) -> Vector3:
	var error := get_distance(position) - offset
	if error + offset >= _max_distance_value * 0.9:
		return position
	# Step along the field's gradient by the error. The blended field isn't an exact distance
	# everywhere, so steps are damped and the best point seen is kept.
	var point := position
	var best := position
	var best_error := absf(error)
	for i in 12:
		if absf(error) <= tolerance:
			break
		var normal := get_cloud_normal(point)
		if normal == Vector3.ZERO:
			break
		point -= normal * error * (1.0 if i < 2 else 0.7)
		error = get_distance(point) - offset
		if absf(error) < best_error:
			best_error = absf(error)
			best = point
	return best


## How clearly from can see to through the clouds: 1 = clear, 0 = completely hidden. Marches the
## line, jumping across clear air. cloud_depth is how many metres of solid cloud cut the view to
## about a third (three times that hides it almost completely).
static func get_visibility(from : Vector3, to : Vector3, cloud_depth : float = 300.0) -> float:
	var length := from.distance_to(to)
	if length < 1.0 or _bakes.is_empty():
		return 1.0
	var direction := (to - from) / length
	var softness := _softness_value
	var inside_step := maxf(_voxel_value * 0.5, 25.0)
	var optical_depth := 0.0
	var t := 0.0
	for i in 512:
		if t >= length:
			break
		var distance := get_distance(from + direction * t)
		if distance > softness:
			t += maxf(distance - softness, 20.0)
			continue
		var step := minf(inside_step, length - t)
		optical_depth += clampf(0.5 - distance / (2.0 * softness), 0.0, 1.0) * step
		if optical_depth > cloud_depth * 6.0:
			return 0.0
		t += step
	return exp(-optical_depth / maxf(cloud_depth, 1.0))


## True when the clouds between from and to cut visibility below threshold.
static func is_hidden(from : Vector3, to : Vector3, threshold : float = 0.1, cloud_depth : float = 300.0) -> bool:
	return get_visibility(from, to, cloud_depth) < threshold


## Where the line from from to to first enters cloud: {"hit": bool, "position": Vector3,
## "distance": float (m from from)}. Starting inside cloud is a hit at distance 0.
static func raycast(from : Vector3, to : Vector3) -> Dictionary:
	var length := from.distance_to(to)
	var result := {"hit": false, "position": to, "distance": length}
	if length < 1.0 or _bakes.is_empty():
		return result
	var direction := (to - from) / length
	var t := 0.0
	for i in 512:
		if t >= length:
			break
		var distance := get_distance(from + direction * t)
		if distance <= 0.0:
			result.hit = true
			result.position = from + direction * t
			result.distance = t
			return result
		t += maxf(distance * 0.9, 10.0)
	return result


# The finest bake holding position (the last one found first), or null.
static func _find(position : Vector3) -> PaintedCloudBake:
	var last := _last
	if last and last.contains(position) and last.has_data():
		# Still the finest? Only a lower tier could beat it.
		if last.tier == 0:
			return last
	for bake in _bakes:
		if bake.contains(position) and bake.has_data():
			# Only the main thread updates the shortcut (worker threads just read it).
			if OS.get_thread_caller_id() == OS.get_main_thread_id():
				_last = bake
			return bake
	return null


static func _update_settings() -> void:
	if _bakes.is_empty():
		return
	_softness_value = _bakes[0].softness
	_max_distance_value = _bakes[0].max_distance
	_voxel_value = _bakes[0].voxel_size
