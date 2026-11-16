@tool
extends Resource
class_name PaintedCloudLobeRule
## A set of lobes a PaintedCloudRecipe scatters over its cloud: on a core part, on the lobes before them
## (for smaller puffs on bigger ones), or on a sheet's puffs. Sizes are a fraction of whatever
## they sit on.

enum Placement {
	## On one of the recipe's core parts (part_index).
	PART,
	## On the lobes made by the rules before this one.
	PREVIOUS_LOBES,
	## On a sheet recipe's puffs.
	SHEET_PUFFS,
}

@export var placement : Placement = Placement.PART
## For PART: which core part.
@export var part_index : int = 0
## How many.
@export_range(0, 256) var count : int = 12
## Plus this many per thing it can sit on (per sheet puff or previous lobe): scales with the cloud.
@export_range(0.0, 4.0, 0.01) var count_per_parent : float = 0.0
## Lobe radius as a fraction of what it sits on (random in this range).
@export var size := Vector2(0.33, 0.55)
## How far out from what it sits on, in its radii (random in this range): ~0.9 sits on the surface.
@export var outward := Vector2(0.6, 0.95)
## For PART on a capsule: where along it (0 = bottom, 1 = top), random in this range.
@export var height_range := Vector2(0.0, 1.0)
## 1 = only on top, 0 = all round, -1 = only underneath (hanging).
@export_range(-1.0, 1.0, 0.01) var up_bias : float = 0.9
## Flattens their spread towards horizontal: 0 = none, 1 = only sideways.
@export_range(0.0, 1.0, 0.01) var flatten : float = 0.0
## Pushes them away from the cloud's centre: 0 = none.
@export_range(0.0, 2.0, 0.01) var outward_bias : float = 0.0
## Their squash: what they sit on's squash times this (capped at 1, round).
@export_range(0.1, 4.0, 0.01) var squash_scale : float = 1.0
