@tool
extends Resource
class_name PaintedCloudPart
## One core shape of a PaintedCloudRecipe: a sphere or a vertical capsule, sized and placed relative to
## the PaintedCloudPoint's radius and height, so one recipe works at any size. Heights are given as a
## fraction of the cloud's height plus a lift in core radii (so e.g. "the top, less one radius").

enum Shape { SPHERE, CAPSULE }

@export var shape : Shape = Shape.SPHERE
## Its radius in core radii (the PaintedCloudPoint's radius).
@export_range(0.05, 8.0, 0.01, "or_greater") var radius_scale : float = 1.0
## Vertical squash: 1 = round, 0.3 = a flattened disc.
@export_range(0.02, 1.0, 0.01) var squash : float = 1.0
## Takes its squash from the cloud's height instead (height / diameter, times squash): for flat
## clouds whose thickness is set by the PaintedCloudPoint's height.
@export var squash_from_height : bool = false
## Sideways offset from the base centre, in core radii (x, z).
@export var offset := Vector2.ZERO

@export_group("Centre (sphere) or bottom (capsule)")
## Fraction of the cloud's height (0 = base, 1 = top).
@export_range(-1.0, 2.0, 0.01) var height_at : float = 0.5
## Plus this many core radii.
@export_range(-8.0, 8.0, 0.01) var radius_lift : float = 0.0

@export_group("Capsule top")
@export_range(-1.0, 2.0, 0.01) var top_height_at : float = 1.0
@export_range(-8.0, 8.0, 0.01) var top_radius_lift : float = -1.0
