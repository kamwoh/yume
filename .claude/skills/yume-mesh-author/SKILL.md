---
name: yume-mesh-author
description: >-
  Author one code-built 3D mesh in meshes.json from a text brief and an
  optional concept image. Plan the parts, validate, render a turntable,
  compare it with the brief, fix up to 3 rounds. Use for a new prop,
  building piece or simple character mesh.
context: fork
background: false
---

# /yume-mesh-author

You author ONE code-built mesh for `godot/data/meshes.json` (ADR 0083).
A code-built mesh is a list of parts: Godot primitives, CSG ops (`lathe`,
`extrude`, `sweep`) and cuts. It costs nothing to make, it is
deterministic, and its pivot and size come from its data.

## Inputs and outputs

This skill runs as a forked skill (ADR 0082). It runs in its own
subagent and does not see the chat history. The arguments and the
files below carry all the input.

1. **Arguments.** A mesh name, a text brief in quotes, and optional
   flags. Example: `lamp_post_3d "iron street lamp, 3 m, a lantern on a
   curved arm, warm glow" --image=docs/games/x/concepts/lamp.png
   --draft-only`. The brief can name a size, a base (on the ground or
   hovering), a front, a palette and a part budget.
2. **Output.**
   - The mesh entry goes into `godot/data/meshes.json`. With
     `--draft-only`, it stays in the draft file only.
   - A note goes to `docs/reviews/mesh-<name>.md`. It holds the brief,
     the part plan, the base and front choices, the review of each
     round, and the final verdict.
3. **Return.** Reply in 200 words or fewer: the verdict, the mesh name,
   the sheet path, and the top 3 notes for the caller. The verdict is
   `accept`, or `needs-human` after 3 rounds.

## Rules

- Read `reference/mesh-ops.md` first. It lists every op, its fields,
  its local frame, the CSG limits and 3 worked examples.
- Build in **unit space**. The mesh is about 1 unit tall, and
  `state.scale` sets the real size. For a tall thin object, keep its
  real proportions in the parts, for example 0.12 x 1.0 x 0.12.
- **Base and front are your choice, and you write them down.** Most
  floor props sit on y = 0. A hovering object, a projectile or a sunk
  rock can differ. Godot forward is -Z, so give actors and signs a -Z
  front unless the brief says otherwise. Record both choices in the note.
- Use the `materials` block for shared materials (`wood`, `iron`,
  `stone`). Add a new material only when no existing one fits. Use
  `$param` colors for parts that a game tints per instance.
- Budget: 4-30 parts. Silhouette first, then detail. Detail that is
  smaller than 3% of the mesh height does not show at game distance.
  Leave it out.
- A part with `name` stays a separate node for animation. Give a part a
  name only when an animation needs it.
- Never copy a mesh from a commercial game. Describe shapes, not
  brands.

## Procedure

### 1. Plan

Write the part plan in the note before any JSON. For each part, give the
op, its role in the silhouette, its size and its material. Compare the
plan with the brief: every noun in the brief has a part, or the note
says why it has none.

### 2. Write the draft

```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"
mkdir -p "$TEMPLATE_DST/_mesh_drafts" && touch "$TEMPLATE_DST/_mesh_drafts/.gdignore"
# Write {"materials": {...new only...}, "meshes": {"<name>": {...}}} to:
#   "$TEMPLATE_DST/_mesh_drafts/<name>.json"
python3 tools/validators/validate_meshes.py --strict --file="$TEMPLATE_DST/_mesh_drafts/<name>.json"
```

Fix every validator error before you render.

### 3. Render the turntable

Sync the engine scripts once per run, then render 8 views:

```bash
cp -r godot/scripts/. "$TEMPLATE_DST/scripts/" && cp godot/data/meshes.json "$TEMPLATE_DST/data/"
cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . scenes/asset_preview.tscn -- \
  --asset=<name> --lib=res://_mesh_drafts/<name>.json --turntable=8 \
  --turntable-output=res://_mesh_drafts/<name>_r<round>.png
```

The sheet is `$TEMPLATE_DST/_mesh_drafts/<name>_r<round>.png`, with 4
columns and 2 rows. Frame 0 (top left) is the view from -Z. Each next
frame turns the mesh 45 deg. The light is calibrated, so the colors on
the sheet match the authored colors within about 6/255.

### 4. Review the sheet

Read the PNG. Score each item pass or fail, with the frame number as
evidence:

1. **Silhouette.** Frames 0 and 2 read as the brief's object to a person
   who did not read the brief.
2. **Proportions.** The height-to-width ratio and the size of the main
   parts match the brief (or the concept image).
3. **Connection.** No part floats free of the others, unless the brief
   says so. No part pokes through another by accident.
4. **Color.** The colors match the brief's palette. Two parts that must
   read as different materials are different in value, not only in hue.
5. **Front.** Frame 0 shows the side that the note calls the front.

All 5 pass: accept. Any fail: change the parts, write a new draft and
render the next round. After round 3 with a fail, stop with
`needs-human` and list the fails in the note.

### 5. Write the result

Without `--draft-only`, merge the entry (and any new material) into
`godot/data/meshes.json`, then keep its compact format:

```bash
python3 tools/fmt_json_compact.py godot/data/meshes.json
python3 tools/validators/validate_meshes.py --strict
```

The sheets stay in `_mesh_drafts/`. They are generated files. Never
commit them.
