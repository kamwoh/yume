# Mesh run: lamp_post_3d

_Date: 2026-10-15 · skill: yume-mesh-author · mode: `--draft-only`_

## Brief

> iron street lamp post for a small fantasy town, about 3 m tall in game
> (state.scale sets it). A thin round iron pole on a wider stepped stone
> base, a curved iron arm near the top that reaches out to one side, and a
> small boxy lantern that hangs from the arm end, with a warm yellow
> glowing glass core. Base on the ground at y = 0. The arm reaches toward
> -Z (the front). Palette: dark iron, grey stone, warm glow. Budget 8-20
> parts.

## Choices

- **Base:** y = 0. The bottom stone step sits on the floor.
- **Front:** -Z. The arm and the lantern reach toward -Z. Frame 0 shows the lantern in front of the pole.
- **Size:** 0.97 units tall (finial top). At `state.scale` 3.0 the post is about 2.9 m. The pole is 0.04 units wide (about 12 cm at 3 m).
- **Materials:** the library had no `materials` block. The draft adds `iron` (#2e2e33, metallic 0.6) and `stone` (#8c8982, rough 0.95). The glass uses inline emission because only this part glows.
- **Part count:** 18.

## Part plan

| # | Op | Role | Size (units) | Material |
|---|---|---|---|---|
| 1 | box | bottom stone step | 0.22 x 0.06 x 0.22 | stone |
| 2 | box | middle stone step | 0.16 x 0.05 x 0.16 | stone |
| 3 | box | top stone step | 0.10 x 0.04 x 0.10 | stone |
| 4 | cylinder | iron foot collar | r 0.032, h 0.05 | iron |
| 5 | cylinder | pole | r 0.02, h 0.78 | iron |
| 6 | sphere | pole finial | r 0.028 | iron |
| 7 | sweep | curved arm, pole to -Z | 8-gon r 0.012, reach 0.23 | iron |
| 8 | sweep | brace scroll under the arm | 4-gon r 0.007 | iron |
| 9 | cylinder | hanger rod | r 0.006, h 0.035 | iron |
| 10 | lathe (4 segments) | pyramid lantern roof | r 0.07, h 0.03 | iron |
| 11 | box | lantern top plate | 0.095 x 0.012 x 0.095 | iron |
| 12 | box | glowing glass core | 0.07 x 0.09 x 0.07 | inline glow |
| 13 | box | lantern bottom plate | 0.085 x 0.012 x 0.085 | iron |
| 14-17 | cylinder | 4 lantern corner posts | r 0.006, h 0.10 | iron |
| 18 | sphere | lantern bottom drop | r 0.012 | iron |

Brief check: pole (5), stepped stone base (1-3), curved arm (7, 8), boxy hanging lantern (9-13, 14-17), warm glass core (12). Every noun has a part.

## Rounds

Sheets: `$TEMPLATE_DST/_mesh_drafts/lamp_post_3d_r{1,2,3}.png` (generated, not committed).

### Round 1

| Check | Result | Evidence |
|---|---|---|
| Silhouette | pass | Frame 2 reads as a street lamp with a hanging lantern. |
| Proportions | pass | Thin pole, base about 5x the pole width, lantern at the top quarter. |
| Connection | pass | The arm meets the pole and the hanger. The brace touches both. |
| Color | **fail** | The glass clips to (255,255,232). It reads as white, not warm yellow. |
| Front | pass | Frame 0 shows the lantern in front of the pole. |

Change: glass albedo #ffd27a to #f0b040, emission #ffb040 at 2.0 to #ff9a20 at 0.9.

### Round 2

| Check | Result | Evidence |
|---|---|---|
| Silhouette, Proportions, Connection, Front | pass | No change from round 1. |
| Color | **fail** | The glass clips to (255,255,76). Red and green both clip, so it reads as lemon, not warm. |

Change: glass albedo #d89a40, emission #ff8c1a at 0.45, so the green channel stays under 255.

### Round 3

| Check | Result | Evidence |
|---|---|---|
| Silhouette | pass | Frames 0 and 2 read as a fantasy street lamp. |
| Proportions | pass | Same geometry as round 1. |
| Connection | pass | No floating parts in any frame. |
| Color | pass | The glass is (255,190,64), a warm amber. Dark iron, light grey stone and the glow differ in value. |
| Front | pass | Frame 0 shows the lantern face-on in front of the pole. |

## Verdict

**accept** (round 3). Draft only. The entry is not merged into `godot/data/meshes.json`.

## Notes for the caller

- The glow saturates fast in the preview light. An emission energy above about 0.5 clips the channels and shifts the hue. Keep it near 0.45.
- The draft adds the first `materials` block (`iron`, `stone`) to the library. Other meshes can reuse it after the merge.
- The mesh does not emit real light. If the lamp must light the ground, give the entity a `visual.light` block (ADR 0072, see `yume-lighting-designer`). (Corrected by the caller: the first version named `scene.json`.)

## Final entry

```json
{"materials": {
  "iron": {"color": "#2e2e33", "roughness": 0.5, "metallic": 0.6},
  "stone": {"color": "#8c8982", "roughness": 0.95, "metallic": 0.0}
},
"meshes": {"lamp_post_3d": {"primitives": [
  {"op": "box", "pos": [0, 0.03, 0], "size": [0.22, 0.06, 0.22], "material": "stone"},
  {"op": "box", "pos": [0, 0.085, 0], "size": [0.16, 0.05, 0.16], "material": "stone"},
  {"op": "box", "pos": [0, 0.13, 0], "size": [0.1, 0.04, 0.1], "material": "stone"},
  {"op": "cylinder", "pos": [0, 0.17, 0], "radius": 0.032, "height": 0.05, "material": "iron"},
  {"op": "cylinder", "pos": [0, 0.54, 0], "radius": 0.02, "height": 0.78, "material": "iron"},
  {"op": "sphere", "pos": [0, 0.945, 0], "radius": 0.028, "material": "iron"},
  {"op": "sweep", "material": "iron",
   "polygon": [[0.012, 0], [0.0085, 0.0085], [0, 0.012], [-0.0085, 0.0085], [-0.012, 0], [-0.0085, -0.0085], [0, -0.012], [0.0085, -0.0085]],
   "path": [[0, 0.86, 0], [0, 0.895, -0.035], [0, 0.918, -0.08], [0, 0.928, -0.13], [0, 0.925, -0.18], [0, 0.912, -0.215], [0, 0.9, -0.23]], "interval": 0.02},
  {"op": "sweep", "material": "iron",
   "polygon": [[0.007, 0], [0, 0.007], [-0.007, 0], [0, -0.007]],
   "path": [[0, 0.78, 0], [0, 0.81, -0.03], [0, 0.85, -0.07], [0, 0.89, -0.1], [0, 0.915, -0.12]], "interval": 0.02},
  {"op": "cylinder", "pos": [0, 0.885, -0.23], "radius": 0.006, "height": 0.035, "material": "iron"},
  {"op": "lathe", "segments": 4, "pos": [0, 0.852, -0.23], "rotation_deg": [0, 45, 0], "profile": [[0, 0.03], [0.07, 0]], "material": "iron"},
  {"op": "box", "pos": [0, 0.846, -0.23], "size": [0.095, 0.012, 0.095], "material": "iron"},
  {"op": "box", "pos": [0, 0.795, -0.23], "size": [0.07, 0.09, 0.07], "color": "#d89a40", "emission": "#ff8c1a", "emission_energy": 0.45, "cast_shadow": false},
  {"op": "box", "pos": [0, 0.744, -0.23], "size": [0.085, 0.012, 0.085], "material": "iron"},
  {"op": "cylinder", "pos": [0.04, 0.795, -0.19], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "cylinder", "pos": [-0.04, 0.795, -0.19], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "cylinder", "pos": [0.04, 0.795, -0.27], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "cylinder", "pos": [-0.04, 0.795, -0.27], "radius": 0.006, "height": 0.1, "material": "iron"},
  {"op": "sphere", "pos": [0, 0.73, -0.23], "radius": 0.012, "material": "iron"}
]}}}
```
