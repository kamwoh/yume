---
name: yume-topdown-prompt
description: Generate a structured text-to-image prompt for orthographic top-down map renders (town / city / region / dungeon / level overview). Used right before calling openai_images / imagen / nanobanana with a "show me the whole map from above" intent. Produces a multi-section prompt (scene → perimeter → style refs → camera requirements → visual style → lighting → keywords) that reliably yields TRUE 90° orthographic views — not the angled cinematic shots image models default to. Empirical case: 2026-05-25 medieval-town render via gpt-image-2-2026-04-21 (194s, 2.7MB) succeeded end-to-end with this exact template.
---

# /yume-topdown-prompt

You are constructing a text-to-image prompt for a TOP-DOWN
ORTHOGRAPHIC map render — a flat 90° bird's-eye view of a town,
city, region, dungeon, or level. The prompt's job is to fight the
image model's default toward cinematic / angled / atmospheric
framing and force it into a clean, readable, map-style render.

## When to invoke

- About to call `openai_images` / `imagen` / `nanobanana` (any
  generic text-to-image backend) for a top-down view
- Generating a reference / concept image for a level layout
- Producing the "what should this place LOOK like?" companion image
  to a level-design.md or world plan
- User says "generate a top-down view of X" / "make a map image of
  Y" / "ortho render of Z" / "aerial of W"

## When NOT to invoke

- Generating compose_map's flat-color SEMANTIC blocks — that
  pipeline already has its own `STRICT_TEMPLATE_PREFIX` and is the
  STABLE 2D harness (see `.claude/rules/pipeline-stability.md`)
- Isometric (45°) / oblique / side-scroll / FPS / 3rd-person views
  — those are different framings
- HUD wireframes → `yume-hud-author`
- Modal screen wireframes → `yume-screen-author`
- Single-entity assets (a tree, an NPC) — use the per-entity
  prompt fields under `visual.*_prompt` instead

## Inputs

1. **Scene brief** — one or two sentences. e.g. "medieval fantasy
   town beside a river" / "post-apoc raider settlement in a desert"
   / "abandoned subway depot turned bandit camp"
2. **Genre + setting cues** (optional) — medieval / sci-fi / ancient
   / post-apoc / modern / fantasy
3. **Required features** (optional) — must-have elements the brief
   should encode (river, walls, central plaza, specific landmarks)

## Output

A single multi-line text-image prompt, 1200–1800 chars, in this
exact 8-section structure. Output the prompt as a fenced code block
ready to paste; no commentary unless asked.

---

## The 8-section template

### 1. Opening sentence (~25 words, LOAD-BEARING)

```
Ultra-detailed {GENRE} {SCENE_TYPE}, perfectly orthographic
top-down aerial view, 90-degree bird's-eye perspective, no horizon,
no cinematic angle, no perspective distortion.
```

The trailing **"no horizon, no cinematic angle, no perspective
distortion"** is load-bearing — image models default to cinematic
angles unless explicitly told otherwise. Don't paraphrase, don't
drop. Always use this exact tail.

### 2. Scene paragraph (50–80 words)

Concrete physical description of the main subject. Cover:

- Geometric layout (octagonal / radial / grid / organic / linear)
- Boundaries / walls / enclosures
- Central feature (plaza, fountain, focal anchor)
- Building types + materials (terracotta roofs, steel modules, etc.)
- Density signal (dense clusters, sparse, scattered)
- Notable interior content (markets, gardens, workshops, wells)

### 3. Perimeter paragraph (30–50 words)

What's OUTSIDE the main area or peripheral to it:

- Natural features (river, forest, mountains, desert)
- Transitional zones (fields, paths, suburbs, no-man's-land)
- Crossings (bridges, gates, checkpoints)
- Vegetation / terrain texture

### 4. Style references (comma list, 5–7 items)

Aesthetic anchors. Describe what the image should RESEMBLE without
naming copyrighted IP directly:

```
Style should resemble:
high-detail strategy game map,
city-builder game,
painted satellite view,
handcrafted procedural generation reference,
fantasy minimap.
```

Avoid: specific game titles, studio names, artist names. Describe
the aesthetic genre instead.

### 5. Camera requirements (comma list — ALWAYS THESE EXACT ITEMS)

```
Camera requirements:
true orthographic projection,
completely vertical top-down camera,
flattened rooftops,
no visible building facades,
no side walls,
no angled structures.
```

Don't paraphrase. These constrain the camera away from the model's
default cinematic angle. They're the most-skipped section in
ad-hoc prompts and the #1 cause of "but I asked for top-down and
got a 45° angle" failures.

### 6. Visual style (comma list, 7–10 items)

Polish + readability traits:

```
Visual style:
clean readable city layout,
dense believable urban planning,
warm medieval colors,
high geometric readability,
extremely detailed roofs and roads,
lush vegetation,
painted map texture,
civilization simulation feel.
```

Swap "medieval colors" for genre-appropriate palette. Keep the
"readability" and "geometric readability" cues — they push the
model toward map-style flatness vs photoreal complexity.

### 7. Lighting (comma list, 4–5 items)

For ORTHO you want REDUCED depth cues — long shadows imply a low
sun and side-angle, which the model overweights.

```
Lighting:
soft neutral daylight,
minimal shadows,
uniform illumination,
reduced depth cues.
```

For non-daylight (night ortho map, dawn render), swap "neutral
daylight" for the desired ambient quality but KEEP "minimal
shadows / uniform illumination / reduced depth cues."

### 8. Keywords (comma list, 6–8 items)

Emphasis tail. Repeats the orthographic + readability signal so
the model weights it heavily:

```
Keywords:
orthographic map,
top-down city layout,
fantasy town blueprint,
procedural generation reference,
strategy game world map,
satellite-style fantasy render,
urban layout readability,
roof-only visibility.
```

Substitute genre nouns ("medieval" / "sci-fi" / "post-apoc") into
"{genre} blueprint" and "{genre} render."

---

## Genre cheat sheet

| Genre | Walls | Streets | Plaza | Materials | Palette | Style refs |
|---|---|---|---|---|---|---|
| Medieval / fantasy | pale stone + round towers | cobblestone, radial | fountain / shrine | terracotta, wood, stone | warm earth | painted satellite, fantasy minimap |
| Sci-fi / cyberpunk | metal panels / energy fields | glowing lanes, grid | hologram / transit hub | chrome, neon glass, concrete | cool, neon underlights | tech blueprint, cyber minimap |
| Ancient (Roman/Egyptian/Sumerian) | stacked stone, ziggurat tiers | marble plazas, ceremonial axes | obelisk / temple / fountain | limestone, sandstone, granite | sun-bleached ochre | archaeological survey, ancient city map |
| Post-apocalyptic | ruined / patched-together | rubble, makeshift paths | scavenged shrine / signal tower | corrugated metal, rust, salvage | desaturated, dusty | post-apoc strategy game map, raider camp blueprint |
| Modern real-world | usually absent | asphalt grid + organic roads | park / public square | concrete, glass, brick | varied | satellite imagery, urban-planning blueprint |
| Dungeon / interior | rough-hewn cave walls | corridors + chambers | central pit / altar | flagstones, packed earth | torch-amber | dungeon master's map, hand-drawn parchment |

## Anti-patterns (do NOT do)

- Don't request "isometric" — that's 45°, NOT orthographic top-down
- Don't request "3D" — triggers perspective rendering
- Don't request "atmospheric haze" / "depth of field" / "bokeh" —
  those are depth cues, the opposite of ortho
- Don't request shadows beyond "minimal" — long shadows imply low
  sun + side angle, breaks the ortho illusion
- Don't include specific IP names (a city-builder, a strategy game,
  a 4X game) — describe the AESTHETIC; copyright-safety + style
  precision
- Don't ask for text labels — image models render text poorly and
  legible labels aren't reliable; if you need labels, overlay them
  in post-process
- Don't pile on contradictory style refs (e.g. "painted" +
  "photorealistic" + "hand-drawn pixel art") — pick one direction

## Worked example (the 2026-05-25 medieval town)

Input brief: *"compact octagonal fortified medieval town beside a
river"*

Output prompt:

```
Ultra-detailed medieval fantasy town, perfectly orthographic
top-down aerial view, 90-degree bird's-eye perspective, no horizon,
no cinematic angle, no perspective distortion.

A compact octagonal fortified town beside a river, enclosed by
pale stone walls with round defensive towers. Radial cobblestone
streets connect to a circular central plaza with a fountain.
Dense clusters of medieval houses with terracotta roofs, market
stalls, gardens, workshops, wells, and small courtyards fill the
interior.

Outside the walls are grassy fields, dirt paths, scattered trees,
farmland patches, and a flowing river with stone bridges and
small wooden boats.

Style should resemble:
high-detail strategy game map,
city-builder game,
painted satellite view,
handcrafted procedural generation reference,
fantasy minimap.

Camera requirements:
true orthographic projection,
completely vertical top-down camera,
flattened rooftops,
no visible building facades,
no side walls,
no angled structures.

Visual style:
clean readable city layout,
dense believable urban planning,
warm medieval colors,
high geometric readability,
extremely detailed roofs and roads,
lush vegetation,
painted map texture,
civilization simulation feel.

Lighting:
soft neutral daylight,
minimal shadows,
uniform illumination,
reduced depth cues.

Keywords:
orthographic map,
top-down city layout,
fantasy town blueprint,
procedural generation reference,
strategy game world map,
satellite-style fantasy render,
urban layout readability,
roof-only visibility.
```

Result: clean orthographic render with octagonal wall, radial
streets, central plaza+fountain, river+bridge, exterior fields
+ farmland. All sections of the prompt visible in the output;
no perspective distortion; no cinematic angle. Time: 194s on
gpt-image-2 high quality. File: `_test_town_orthographic.png`
(2.7MB, 1024×1024).

## How this connects to the rest of Yume

This skill produces **reference imagery** — the "this is what we're
aiming for" concept art. It does NOT produce the flat-color
SEMANTIC MAP that `compose_map` consumes for entity extraction —
that's a separate prompt template (the `STRICT_TEMPLATE_PREFIX` in
`tools/visual_layout/compose_map.py`) and lives in the STABLE 2D
harness (don't touch without an ADR).

Workflow:
1. User describes a scene → `/yume-topdown-prompt` produces a
   prompt → call `openai_images` / `imagen` → get a reference
   render the team aligns on
2. With the reference in hand, write a tighter brief for
   `compose_map` to generate the flat-color semantic map
3. `compose_map` + `/yume-map-author` extract entities + structure
   from the semantic map → level entities.json

This skill is for step 1 only. It's NOT a member of the
`compose_map` family.
