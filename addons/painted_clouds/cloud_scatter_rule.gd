@tool
extends Resource
class_name PaintedCloudScatterRule
## One kind of cloud a PaintedCloudScatter places: which recipe, where the noise puts it, how often, how
## big and at what altitude. A scatter checks its rules in order and places the first that fits.

@export var recipe : PaintedCloudRecipe
## The noise values (0..1) it goes on: towers on the peaks, low patches at the fringes, and so on.
@export var noise_range := Vector2(0.5, 1.0)
## Chance it's placed where the noise fits (rarity): 1 = always, 0.05 = occasionally.
@export_range(0.0, 1.0, 0.001) var chance : float = 1.0
## Radius range (m). For a sheet, the whole field's radius.
@export var radius := Vector2(600.0, 1300.0)
## Height range (m). For a sheet, its thickness.
@export var height := Vector2(1200.0, 3000.0)
## Base altitude offset from the scatter node (m), random in this range.
@export var altitude := Vector2(-150.0, 150.0)
## How much the noise value (vs. chance) sets the size: 1 = stronger noise, bigger cloud.
@export_range(0.0, 1.0, 0.01) var size_from_noise : float = 0.6
## Lobe detail for its clouds (PaintedCloudPoint.detail).
@export_range(0.0, 3.0, 0.01) var detail : float = 1.0
