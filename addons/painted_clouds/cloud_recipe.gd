@tool
extends Resource
class_name PaintedCloudRecipe
## A cloud type: core parts and lobe rules (or a sheet of puffs), all relative to a PaintedCloudPoint's
## radius and height, so the same recipe scales to any cloud. Make new types by duplicating one of
## the recipes in addons/painted_clouds/recipes/ and editing it.

@export var display_name : String = "Cloud"
## The PaintedCloudPoint gizmo's colour for this type.
@export var gizmo_color : Color = Color(1.0, 1.0, 1.0, 0.8)
## Cuts the cloud off flat at its base.
@export var flat_base : bool = true
## Scales the billow noise's size and strength on this cloud: lower for small puffy types, so
## their surface noise doesn't swamp them.
@export_range(0.05, 4.0, 0.01) var noise_scale : float = 1.0

@export_group("Core")
@export var parts : Array[PaintedCloudPart] = []

@export_group("Sheet")
## A sheet: a field of separate puffs over a disc of the PaintedCloudPoint's radius, as thick as its
## height (stratocumulus decks, altocumulus fields), instead of one mass.
@export var sheet : bool = false
## Spacing between puffs, as a fraction of the radius.
@export_range(0.01, 1.0, 0.005) var sheet_cell : float = 0.12
## Chance of a puff in each cell (before clumping and the rim).
@export_range(0.0, 1.0, 0.01) var sheet_coverage : float = 0.8
## Puff radius as a fraction of the cell spacing (random in this range).
@export var sheet_puff_size := Vector2(0.6, 1.0)
## How much of the radius, in from the rim, the puffs thin out and shrink over.
@export_range(0.0, 1.0, 0.01) var sheet_edge : float = 0.35
## How much the puffs gather into clumps with gaps between: 0 = evenly spread.
@export_range(0.0, 1.0, 0.01) var sheet_clumping : float = 0.5
## Random up and down offset of each puff, as a fraction of the height.
@export_range(0.0, 2.0, 0.01) var sheet_height_jitter : float = 0.3

@export_group("Lobes")
@export var lobes : Array[PaintedCloudLobeRule] = []
