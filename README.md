# PaintedClouds (prototype)

Art-directed, Ghibli-style clouds for Godot 4.4+ (Forward+ / Vulkan). Clouds are authored as
a handful of **cloud points**, turned into seeded lobes, merged into one smooth **signed distance
field** and baked with sun and sky light into a 3D texture. A compositor effect raymarches that
texture: it jumps across clear air using the distance field, and shades the clouds through a
colour gradient rather than physically.

Open the project and run `demo/demo.tscn` (one fixed baked volume) or `demo/demo_tiles.tscn`
(the endless streamed world: fly in any direction; press T to turn the sun and watch the light
re-bake). Fly with the right mouse button held (look), WASD,
E/Q up and down, Shift faster and the mouse wheel for speed. The HUD shows the gameplay cloud query
at the camera.

## Nodes and resources

| Node / resource | What it does |
|---|---|
| `PaintedCloudRecipe` | A cloud type as data: core parts (`PaintedCloudPart`: spheres and capsules sized relative to the cloud), lobe rules (`PaintedCloudLobeRule`: on a part, on earlier lobes, or on sheet puffs, with size, spread, up/down bias) or a sheet of puffs (decks, fields), its gizmo colour and its noise scale. Built-in: `cumulus`, `tower`, `low_patch`, `stratocumulus_deck`, `altocumulus_field` in `addons/painted_clouds/recipes/`. Duplicate one to make a new type. |
| `PaintedCloudPoint` | One cloud: a recipe, radius, height, detail (lobe count scale) and seed. Its position is the centre of its base. The gizmo draws every shape the bake will use, in the recipe's colour. |
| `PaintedCloudScatter` | Scatters PaintedCloudPoints from world-space 2D noise on a jittered grid, matching each candidate against its `PaintedCloudScatterRule`s in order (recipe, noise range, chance for rarity, radius/height/altitude ranges). Use several at different heights for layers. **Scatter** replaces only its own children. |
| `PaintedCloudVolume` | The bake box. **Bake** merges every PaintedCloudPoint beneath it into the distance field and bakes sun and sky light, saved to `bake_path`, logging progress by stage, slice and percentage. Registers its bake with `PaintedCloudWorld`. |
| `PaintedCloudLayer` | One altitude layer of an endless world as data: noise, candidate spacing, base altitude, scatter rules, seed offset. Generated per cell on a fixed world grid, so the same seed always gives the same clouds. |
| `PaintedCloudTileWorld` | An endless sky: cells of `cell_size` (10–50 km, default 20) generated from a seed by its layers (or hand-made: a scene of PaintedCloudPoints for chosen cells), baked on a background thread into 2×2 or 3×3 tiles round the target as it travels. Also a background light re-bake when the sun turns more than `relight_angle`, and an optional floating origin (`shift_threshold`, `shift_root`; or call `shift_origin()` from your own system) that shifts by whole cells, so nothing re-bakes. Logs every tile it bakes. |
| `PaintedCloudWorld` | Static gameplay queries over every registered bake (see below). Works with no renderer (headless servers). |
| `PaintedCloudsEffect` | CompositorEffect that draws the clouds. Colour gradient, wrap, banding, rim, billow noise (scaled per recipe), steps and haze are all in the inspector. |

## Gameplay queries (`PaintedCloudWorld`)

All world space, metres. Measured with a full 3×3 plus far ring loaded (58 bakes, on a CPU that
also ran a software GPU): density, distance and sunlight about 0.005 ms; cover direction about
0.02 ms; line of sight about 0.15 ms (worst 0.5); hold point about 0.1 ms (worst 1.3). For a fleet, stagger checks (each ship every few
seconds, not all in one frame) or run them on a worker thread:

```gdscript
PaintedCloudWorld.run_async(func(): return PaintedCloudWorld.get_visibility(my_pos, enemy_pos),
	func(visibility): _on_visibility(visibility))
```

```gdscript
PaintedCloudWorld.get_density(pos)                 # 0 clear .. 1 inside
PaintedCloudWorld.get_distance(pos)                # signed distance to the nearest cloud surface
PaintedCloudWorld.get_sunlight(pos)                # 0 shaded .. 1 full sun through the clouds
PaintedCloudWorld.get_visibility(from, to)         # 1 clear line of sight .. 0 hidden
PaintedCloudWorld.is_hidden(from, to, 0.1)         # visibility below a threshold
PaintedCloudWorld.raycast(from, to)                # {hit, position, distance} where cloud starts
PaintedCloudWorld.get_direction_to_cloud(pos)      # towards cover (deeper when inside)
PaintedCloudWorld.get_direction_to_clear_air(pos)  # shortest way out
PaintedCloudWorld.get_hold_point(pos, offset)      # nearest point offset m off the surface
                                            # (+ outside, e.g. a boom's reach; - inside)
PaintedCloudWorld.has_cloud_within(pos, radius)
```

Far from every cloud (beyond the volume's `max_distance`, 4 km by default) the field only knows
"at least that far": the cover and hold calls then return ZERO / the position unchanged. Raise
`max_distance` for longer-range cover searches.

## Paint filters

On the PaintedCloudsEffect, under Paint filters. The clouds render to their own layer, the filters
work on that layer only (ships and scenery are untouched), then it's composited over the scene.
Each has a strength (0 = off) and they stack, in this order:

| Filter | What it does |
|---|---|
| Kuwahara | Flattens the clouds into soft painted patches. *Anisotropic* (strokes follow the shapes, like brush strokes; costs an extra pass) or *classic* (blockier). Radius, sharpness, anisotropy. |
| Hue-shifted shadows | Shadows towards one tint (violet), lights towards another (warm), brightness kept. |
| Watercolour edges | Pigment pools just inside the clouds' edges, deeper and richer. |
| Ink outlines | Soft coloured lines on the silhouettes, and fainter ones where the shading turns sharply. |
| Rim bloom | The brightest parts (silver linings) glow softly past themselves. |
| Canvas grain | A fixed paper and weave texture over the clouds. |

Radii are in pixels at 1080p and scale with the resolution. In the demos: 1 cycles Kuwahara
(off, classic, anisotropic), 2 to 6 toggle the others, 9 turns them all on, 0 all off.

## Endless worlds (`PaintedCloudTileWorld`)

1. Add a `PaintedCloudTileWorld`, give it `PaintedCloudLayer`s (each with its noise, spacing, altitude and
   rules), the sun and a target (or leave target empty for the active camera).
2. Optional: `hand_made_cells` maps cell coordinates (`Vector2i`) to scenes of PaintedCloudPoints laid
   out from the cell's corner (0..cell_size on x and z): those cells use them instead.
3. Floating origin: set `shift_threshold` and `shift_root` (whose children are moved), or call
   `shift_origin(offset)` from your own system. Shifts are whole cells. `to_absolute()` converts
   a local position to the unshifted world.
4. The same PaintedCloudsEffect draws it (no bake of its own set). PaintedCloudWorld queries work across
   every loaded tile.

### Distant clouds

Beyond the near tiles, `far_rings` rings of coarse far tiles (800 m voxels, a 7×7 of 20 km cells is
about 5 MB) bake in the background after the near ones. The effect paints them into a panorama
(2048 wide, from straight down to 45° up) seen from the camera, a few rows a frame, and fades it in over
the old one. It re-paints on entering a new cell (as the near window moves), when far tiles land,
after the sun re-bake, and as the camera moves (below). Each panorama also stores how far away its clouds are, so the effect re-projects
them for where the camera is now (`panorama_parallax`): it treats those distances as a surface
seen from where the layer was painted and steps along each camera ray until it reaches it, so
silhouettes keep their shape as you move (the sky beside a cloud doesn't drag its edge), and a ray
that passes behind a nearer cloud's edge carries on to whatever is further out. What the
panorama never saw (just behind a cloud's edge, seen from the side) shows as the background
until the next re-paint.

Beyond the far ring, `horizon_rings` rings of very coarse horizon tiles (2 km voxels, low lobe
detail) bake last, at the lowest priority. The panorama marches on through them, cross-fading
from the far tiles over the far window's edge band (`far_edge_fade`) and thinning out at the
horizon window's edge, with the haze taking over on the way. From altitude the clouds carry on
towards the horizon (about 130 km out with 3 rings of 20 km cells).

Every cloud is drawn once. The near tiles draw the clouds inside the near cells (the loaded
tiles), and the panorama leaves those cells out, so a cloud in the scene is never also in the
panorama. Over `handover_band` (4 km) just inside the near cells' outer edge, fixed in the world
rather than following the camera, the near clouds fade out exactly as the panorama's fade in, so a
cloud straddling the edge is still one cloud. That edge is a cell or more from the camera, so the
panorama only ever holds clouds at least ~16 km away (with 3×3 cells of 20 km).

When the near cells change (a cell crossing, or tiles landing), the hand-over happens in steps
and never leaves a gap or a double: the effect keeps drawing the cells it has (the tile world
holds them loaded, and doesn't overwrite their atlas slots), re-paints the panorama for the cells
it will draw next, then switches the near tiles over as that panorama fades in, and only then
lets the old cells go. On crossing a cell: the cells leaving the window go to the panorama first,
then the new cells' tiles land and come over from it.

**Hidden swaps.** A newly painted panorama (and the hand-over of near cells that comes with it)
doesn't swap in straight away: it waits for a moment when hardly any distant clouds are on
screen (`hidden_coverage`, 3%), such as flying through a cloud or a near cloud filling the view,
and swaps in quickly then (`hidden_fade_seconds`). While waiting, the raymarch counts how much
of the screen (every 4th pixel each way) shows clouds further than `hidden_distance` (10 km), and
the effect reads that back a frame later; it costs nothing the rest of the time. If no hidden
moment comes within `swap_max_wait` (6 s), the fallback wisp (`fallback_wisp`) fades in
(`wisp_fade_in`), still, where the camera will be in `wisp_ahead_seconds` (5 s) at its current
speed (between `wisp_min_distance` and `wisp_max_distance` ahead; straight ahead when hovering).
It's a new random cluster of `wisp_puffs` puffs each time (`wisp_radius` across, puffs
`wisp_puff_size` of that, `wisp_flatten` high, `wisp_density` thick), drawn by the same raymarch,
so it's lit and painted like the other clouds. Fly into it and the swap happens as it fills the
view; swerve past it, turn away, or take longer than `wisp_timeout`, and the swap is forced
(fading as usual). Once behind the camera it fades away (`wisp_fade_out`).

For gameplay (a boost for flying through, say): `PaintedCloudsEffect.get_wisp_density(position)`
(any thread; 0 outside, about 1 deep inside) and `PaintedCloudsEffect.is_wisp_out()`, or the
effect's signals `wisp_appeared(position, radius)`, `wisp_entered` and `wisp_gone(flown_through)`.
The demo's fly camera gives a 2.5× speed boost for 3 s after flying through one.
Turn `swap_when_hidden` off to swap in as soon as painted (fading over
`panorama_fade_seconds`).

The panorama re-paints when the camera has climbed or dropped `panorama_repaint_height` (1 km) or
moved `panorama_repaint_distance` (4 km) sideways from where it was painted, on those hand-overs,
and when the far tiles change. The new one fades in over the old (`panorama_fade_seconds`).
Painting is GPU work, spread over frames (`panorama_rows_per_frame`) so it never stalls one; all
tile baking is on the background thread. The panorama gets the same billow noise as the near
clouds, out to `distant_noise_distance`. The noise is sampled in world space, so a
floating-origin shift doesn't move it.

Queries (PaintedCloudWorld) use the near tiles where they're loaded and the far ones beyond (coarser:
answers within roughly a far voxel), out to the far ring's edge. Beyond that they're a rough guess.

GPU memory for 3×3 tiles of 20 km at 200 m, 13 km tall: about 50 MB, and the same again on the CPU for queries. Each tile bakes in the background:
4–7 s each on a CPU-emulated GPU (where it was tested); expect a small fraction of a second on a
real one.

## Workflow (one fixed volume)

1. Add a `PaintedCloudVolume`, and one or more `PaintedCloudScatter`s under it (one per altitude layer), each
   with its rules. Press **Scatter**, then tweak, move or delete the clouds it makes, or add your
   own `PaintedCloudPoint`s anywhere under the volume.
2. Assign the sun to the volume and press **Bake** (re-bake after editing clouds or moving the
   sun).
3. Add a `PaintedCloudsEffect` to the Compositor on your WorldEnvironment or Camera3D. Use the
   **Linear** tonemapper: the gradient is the look.

## Tools (run from the project folder)

- `godot --headless --path . -s res://tools/build_recipes.gd`: rewrites the built-in recipes.
- `godot --path . -s res://tools/build_demo.gd`: rebuilds and bakes the demo scene.
- `godot --path . -s res://tools/recipe_gallery.gd`: bakes one of each recipe side by side
  and renders them to `user://shots/`.
- `godot --path . -s res://tools/test_queries.gd`: bakes a test tower and checks every query.
- `godot --headless --path . -s res://tools/build_tile_demo.gd`: rebuilds the tile demo scene.
- `godot --path . -s res://tools/test_tiles.gd`: tests streaming, seams, determinism, floating
  origin and the sun re-bake.
- `godot --path . -s res://tools/test_far.gd`: tests the far tiles, the distant panorama and
  queries beyond the near tiles.
- `godot --path . -s res://tools/bench_queries.gd`: times every query with all tiles loaded
  (40 km / 1000 m cells; add `-- --default` for the demo's 20 km / 200 m), and checks run_async.
- `godot --path . -s res://tools/test_altitude_filters.gd`: climbs to 30 km checking the panorama
  re-paints, and renders every paint filter (a contact sheet in `user://shots/filter_sheet.png`).
- `godot --path . -s res://tools/test_handover.gd`: flies 40 km across cell borders measuring
  frame-to-frame change, to catch clouds popping between distant and near.
- `godot --path . -s res://tools/test_parallax.gd`: measures the distant clouds' parallax
  correction against a freshly painted panorama.
- `godot --path . -s res://tools/test_gaps.gd`: moves sideways past clouds and looks for gaps
  opening in the distant clouds, against a freshly painted panorama.
- `godot --path . -s res://tools/test_hidden_swap.gd`: checks a new panorama waits while distant
  clouds are in view, swaps inside a cloud, and that the wisp hides it otherwise (its flight is
  saved to `user://shots/wisp_sheet.png`).
- `godot --path . -s res://tools/test_crossing.gd`: crosses a cell border and holds still through
  the hand-over between the near tiles and the panorama, checking no frame jumps.
- `godot --path . -s res://tools/test_shift.gd`: flies across a floating-origin shift saving every
  frame, checking nothing jumps or flickers.
- `godot --path . -s res://tools/screenshot.gd`: renders the demo from several viewpoints.

## Memory

Voxels × 8 bytes (RGBA half float: distance, sun light, sky light, noise scale), held once on the
CPU (for queries) and once on the GPU. The demo is 240 × 70 × 240 voxels at 200 m = 31 MB.
Halving `voxel_size` costs 8×. Small puffs (radius under ~300 m) blur at 200 m voxels.

## Roadmap

1. ~~Recipes, scatter layers, gameplay queries~~
2. ~~Streamed baked tiles (2×2 or 3×3) with floating origin and hand-made cells; background
   light re-bake for a moving sun~~ (the close-up detail bake was tried and removed: the swap
   was too visible)
3. ~~Distant clouds rendered to a panorama, refreshed as you travel~~ (this version)
4. Effectors (static and moving: city clearings, ship wakes, explosions), lights inside clouds,
   cloud-shadowed ship material
5. Time-of-day palette presets and paint filters (Kuwahara and others)
