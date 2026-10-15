# Asset strategies — full reference

_Moved from `yume-asset-designer/SKILL.md` on 2026-10-15 so that the skill loads faster. The skill links here._

## Asset strategies (pick ONE per game)

### Strategy A: Library lookup (Kenney etc.)

For pixel-art / low-poly with consistent style. Maps entity tags →
asset paths.

```jsonc
{
  "matchers": [
    {"match": {"tags_all": ["plant", "crop"]},
     "sprite_2d": "res://assets/lib/kenney/farm/wheat.png"}
  ]
}
```

### Strategy B: AI-gen prompts

For bespoke style. Add `*_prompt` fields per entity, plus project-wide
style + backend config in `asset_gen.json`. Then `yume assets generate`
(offline tool) realizes prompts to files.

#### Game-perspective consistency (REQUIRED for AI-gen, added 2026-05-18)

Every AI-gen prompt must be written with the **gameplay use case in
mind**, not just "what does this entity look like". Different
entities need different framing because they're consumed differently:

| entity class | required prompt framing |
|---|---|
| **Characters** (player, NPCs, animals) | **FULL BODY** standing pose, T-pose preferred. Front 3/4 view from waist OR full standing height. Body must be complete from head to feet — characters get walked around, viewed from all angles, cast shadow even when hidden (`hide_for_camera_attach`). A waist-up portrait is a portrait, not a character mesh. |
| **Architecture** (huts, structures) | Front 3/4 view showing entry side + roof line. Distinct silhouette at distance. |
| **Foragables / props** (mushrooms, baskets) | Front 3/4 or top-3/4 view. Held visible. Scale-tagged ("small primitive" / "single ...") so Tripo3D doesn't oversize. |
| **Tools / inventory items** | Side view if held. Top-down if dropped on ground. |
| **Landmarks** (statues, markers) | Front view emphasizing recognizable silhouette. |

**Empirical case 2026-05-18**: player_marken's prompt said "standing
T-pose" but produced a waist-up portrait (Tripo3D's image-to-3D
generated only the visible upper-body portion of the concept image).
Same generation cycle, npc_morwen's prompt said "standing dignified"
+ "weathered face" + "holding a wooden walking staff" — produced a
full-body figure because the prompt implicitly required the staff +
posture, forcing the concept image to frame the whole body.

**The principle**: the prompt has to MENTION every part of the body
the game might ever show. For characters specifically:
- Mention legs / feet / tunic-bottom explicitly
- Specify "full body" or "standing T-pose, full standing height"
- Include grounding details ("standing on the autumn ground" or
  similar) so the concept image frames feet-to-head
- Add "viewable from any angle" for emphasis

Bad: `"young farmer in tunic, holding a tool"`
Good: `"young farmer standing full body T-pose, brown-green tunic
extending to mid-thigh, brown leather belt, simple trousers tucked
into ankle-high boots, arms slightly extended at sides, head looking
forward, viewable from any angle, front view with feet visible at
the base of the frame, autumn ground beneath"`

When in doubt: generate twice and compare. Cost is ~$0.40 per
character retry; cheaper than shipping a half-body player who casts
half a shadow.

##### Consistency across a cast

When prompting multiple characters that should feel like the same
art direction (a village's NPCs + the player), use a SHARED prefix
that locks the style:

```
shared_prefix = "low-poly stylized, painterly, earnest folkloric
aesthetic, [autumn village setting / setting type], full body
standing pose, front 3/4 view from head to feet, isolated against
neutral background, viewable from any angle, "
```

Per-character details (clothes, hair, age) go AFTER the shared
prefix. This guarantees coherent silhouette / palette / style across
the cast — without it, each character drifts toward Tripo3D's mean.

##### Background discipline (concept_suffix — REQUIRED for image-to-3D)

When a concept image will be fed to Tripo3D's `image_to_model`, the
image MUST have a clean solid-color background. Gemini Flash Image
(nanobanana) tends to add scenery (trees, buildings, ground) even
when the per-entity prompt says "isolated against neutral
background" — that directive is too weak when the entity prompt also
mentions a setting (e.g. "autumn village setting").

Background contamination has two costs:
1. Tripo3D's image-to-3D may incorporate background geometry into
   the mesh (extra polys for half-resolved tree shapes around the
   character).
2. Tripo3D's `animate_prerigcheck` may reject the mesh because
   background "limbs" confuse skeleton binding.

**The fix**: set `style.concept_suffix` in `asset_gen.json` to a
strong background-stripping directive. Aldenmere uses:

```json
"concept_suffix": ", PLAIN SOLID NEUTRAL GREY BACKGROUND, subject only centered against featureless backdrop, NO scenery, NO trees, NO buildings, NO landscape, NO ground, NO environment, NO foliage, NO sky, studio reference image style for 3D modeling"
```

This is appended to EVERY concept prompt for the game. Per-entity
prompts may still mention setting context (good for vibes), but the
suffix overrides for the BACKGROUND of the IMAGE specifically.

Empirical case 2026-05-18: morwen's first concept came back with
trees and houses despite "isolated against neutral background" in
the per-entity prompt. The aggressive suffix above resolves it.

For new games, copy this `concept_suffix` (and `negative_prompt`)
into `asset_gen.json` as part of the default style block. The
asset-gen pipeline doesn't enforce it — it's a convention.

### Strategy A2: .glb skinned meshes (ADR 0046 Phase B, 2026-05-17)

Drop a `.glb` (or `.gltf`) export from Blender / Maya / GLB-emitting
tool into `data/<game>/assets/` (or wherever you prefer) and point
`visual.mesh` at it directly. The engine loads the scene, hooks the
embedded `AnimationPlayer`'s clips to the same `animation_state_rules`
machinery the code-drawn meshes use, and re-skins surfaces via
`material_overrides`.

```jsonc
{
  "id": "villager_glb",
  "visual": {
    "mesh": "res://data/test_assets/cube_anim.glb",
    "animation_state_rules": [
      {"if_velocity_gt": 0.1, "state": "walk", "clip_alias": "Walking"},
      {"default": "idle", "clip_alias": "Idle"}
    ],
    "animation_blend_seconds": 0.15,
    "material_overrides": {
      "body": "#a0c0e0",
      "trim": "#202060"
    }
  }
}
```

Pre-shipping a .glb-backed entity:

1. **Inspect the .glb** to discover its slot names + clip names —
   blind guesses silently fall back to baked materials:
   ```bash
   python3 tools/inspect_glb.py path/to/file.glb
   ```
   Output enumerates `materials:` (with names), `meshes:` (with
   surface→material mapping), and `animations:` (clip names +
   durations). Copy the names verbatim into `material_overrides` and
   `clip_alias`.
2. **clip_alias is required** when the .glb's clip names don't match
   your engine-side state names. Blender exports often use
   PascalCase (`Walking`, `Idle`) while rules use lowercase (`walk`,
   `idle`). The alias maps state → clip.
3. **Skip code-drawn fallback** if a .glb is present — `visual.mesh`
   ending in `.glb` or `.gltf` short-circuits the mesh-library lookup.
4. **Material overrides duplicate** the imported material per-entity,
   so two villagers with different `material_overrides` don't share
   tinted colors.

A reproducible test asset lives at
`godot/data/test_assets/cube_anim.glb`. Regenerate with
`python3 tools/synth_test_glb.py` — it emits a 2-material cube with
`Idle` + `Walking` clips.

#### A2 extras (2026-05-18) — fields for AI-gen .glb integration

**`properties.mesh_yaw_offset` for Tripo3D characters** (REQUIRED, 2026-05-19):
Tripo3D's image-to-3D outputs the mesh's authored "front" along **+Z**
(toward the concept image's viewing angle — the side the concept was
drawn from). Yume's convention is **-Z forward** (state.facing=0 means
looking world-north which is -Z). Without compensation, a Tripo character
faces TOWARD the camera in third-person AND walks BACKWARD relative to
their visible front.

Compensate via `properties.mesh_yaw_offset: 3.14159265` (π radians,
180°). entity_mesh_3d's `_sync_yaw` adds this offset to `state.facing`
when computing the rendered rotation.y. The mesh's authored +Z front
rotates to align with Yume's -Z forward.

```jsonc
{
  "id": "npc_morwen",
  "properties": {
    "display_name": "Elder Morwen",
    "mesh_yaw_offset": 3.14159265,
    "_comment_yaw_offset": "Tripo3D outputs +Z front; Yume convention is -Z. π aligns."
  }
}
```

Applies to ALL Tripo-generated character/animal meshes. Non-Tripo
meshes (Blender exports with explicit -Z front, code-drawn meshes,
existing aldenmere props like mud_hut) don't need the offset.

Empirical case 2026-05-19: player_marken + morwen rendered facing the
camera in third-person AND moonwalked (walked one direction, facing
opposite) before the offset was added.

**`visual.y_offset_mesh`** (preferred) or `visual.y_offset` (legacy)
— required for Tripo3D outputs and any .glb whose pivot isn't at the
mesh base. Tripo3D's natural mesh origin is at the geometric center,
so placing an entity at world y=0 sinks the lower half underground.

**Preferred — author in MESH-space**:

```
y_offset_mesh = -bbox.min.y       // mesh-space, NOT scaled
```

Engine multiplies by current `state.scale` at sync time. This means
pattern-spawned variants with different scale (e.g. dwarf bushes via
`scale_min/scale_max` on the same fruit-tree def) also land correctly
— their per-instance scale is applied to the same mesh-space lift.

**Legacy — `y_offset` in world units**:

```
y_offset = -bbox.min.y * state_init.scale     // world-units, bakes in def's reference scale
```

Constant lift regardless of per-instance scale. Pattern variants will
float (scaled down) or sink (scaled up). Only use when you're certain
no level pattern will scale this def's instances. New AI-gen output
should always use `y_offset_mesh`.

Auto-computed by `tools/yume_assetgen` when wiring AI-gen output to
an entity def. Manually adjustable via `visual.y_offset_intentional:
true` for debris-artifact meshes (e.g. a fire pit with baked-in ash
below the visible ring — keep the artifact buried).

`tools/validators/validate_mesh_y_offset.py` catches missing/wrong
y_offset at sync time, AND flags legacy `y_offset` defs that get
spawned by patterns with off-spec scale ranges. Run as part of
`tools/validators/run_all.py`.

**Empirical case 2026-05-18** — prop_tree_fruit shipped with
`y_offset: 1.337` (correct at state_init.scale=3.5). A level scatter
pattern reused the def at `scale_min: 0.3, scale_max: 0.55` for dwarf
bushes. The constant 1.337 lift was inherited regardless of
per-instance scale → bushes floated ~1.15m above ground. Migrating to
`y_offset_mesh: 0.382` fixed all variants because the engine now
multiplies by `state.scale` per-instance.

**`material_overrides` PBR fields** — full schema (was: just
albedo_color):

```jsonc
"material_overrides": {
  "tripo_material_<uuid>": {
    "albedo_color":   "#9a6840",
    "albedo_texture": "res://.../foo.png",   // optional
    "normal_texture": "res://.../foo_n.png", // optional
    "roughness":      0.92,                  // 0=mirror, 1=matte
    "metallic":       0.0                    // 0=dielectric, 1=metal
  }
}
```

Setting `roughness` / `metallic` factors ALSO clears their respective
PBR textures so the factor is authoritative. Without that, Tripo3D's
baked ORM (Occlusion/Roughness/Metallic) makes the override silently
partial — all 28 aldenmere entities shipped looking too reflective
for 1 iteration until the renderer was fixed (2026-05-18).

Sensible matte defaults for stylized low-poly:
- Wood / cloth / foliage: `roughness 0.92-0.95`, `metallic 0.0`
- Stone: `roughness 0.85`, `metallic 0.0`
- Skin / fur: `roughness 0.88-0.90`, `metallic 0.0`

Per-entity tinting via material_overrides also drives distinctness
when 8+ structures look similar at distance (e.g. mud_hut warm
terracotta, lean_to cool blue-grey, market_stall punchy orange).

**`visual.shader` (ADR 0052)** — REPLACES the StandardMaterial3D
with a ShaderMaterial backed by a `.gdshader` file. Uniforms via
`visual.shader_params`. Used for animated / procedural visuals
where flat PBR isn't enough.

Available shared shaders under `data/lib/shaders/`:
- `water_stylized.gdshader` — animated noise ripples for rivers /
  ponds. Set on `prop_water_plane`-style entities.
- `ground_multi_biome.gdshader` — used by ground_renderer; not
  per-entity.
- `sky_clouds.gdshader` — used by lighting_director; not
  per-entity.

Authors can add new entity-level shaders following the same pattern.
The shader-as-primitive ADR (0052) covers fire glow, ice, magic
auras, force fields — anything that benefits from animated /
view-aware materials beyond StandardMaterial3D.

**`visual.animate` + `visual.rig_type` (ADR 0053, 2026-05-18)** —
opt-in skeletal animation via Tripo3D's rig + retarget pipeline.
For characters, animals, and any entity that walks/moves visibly,
adding `animate: true` makes the asset-gen pipeline produce a
multi-clip animated GLB instead of a static mesh.

```jsonc
"visual": {
  "mesh": "res://...player_marken_animated_<hash>.glb",  // auto-set after gen
  "animate": true,
  "rig_type": "biped",                                    // REQUIRED when animate=true
  "animation_clips": ["idle", "walk"],                    // optional; default
  "animation_state_rules": [                              // engine — ADR 0046
    { "if": { "velocity_magnitude_gt": 0.1 }, "play": "walk" },
    { "default": true, "play": "idle" }
  ]
}
```

Allowed `rig_type` values (one per Tripo skeleton family):

| rig_type | Use case | Default clips |
|---|---|---|
| `biped` | Players, NPCs | idle, walk (+ run, jump, attack, etc.) |
| `quadruped` | Wolf, deer, rabbit, dog | quadruped:walk |
| `hexapod` | Giant insect | hexapod:walk |
| `octopod` | Spider | octopod:walk |
| `avian` | Bird (probe API for clip list) | TBD |
| `serpentine` | Snake | serpentine:march |
| `aquatic` | Fish, eel | aquatic:march |
| `others` | Fallback rig — may fail prerigcheck | TBD |

Cost per entity (one-time, ledger-cached forever after success):

| Stage | Cost |
|---|---|
| image_to_model (existing) | $0.40 |
| prerigcheck | $0.10 (cached even on reject) |
| rig | $0.30 |
| retarget × N clips | $0.30 each |
| **Biped total (idle + walk)** | **$1.40** |
| **Non-biped total (1 walk)** | **$1.10** |

Budget guidance:
- Player + each named NPC: opt in. $1.40 per biped.
- Generic crowd NPCs: usually keep static. Crowd costs scale to $20+
  fast.
- Predators / threats players track (wolf, boss): opt in. Visible
  pursuit reads better animated than sliding.
- Prey / ambient critters: optional. A single walk clip ($1.10/animal)
  is enough to convey life.
- "Others" rig: only when the entity genuinely doesn't fit other
  taxonomies. Budget for a wasted $0.10 prerigcheck per entity.

Validator: `tools/validators/validate_animate_scope.py` enforces
animate + rig_type pair correctness at sync time. Run via
`tools/validators/run_all.py demo_<name> --strict`.

Non-biped clip diversity is limited: Tripo currently exposes ONE
preset per non-biped rig type (walk/march). Bipeds get 11 presets.
Animal `animation_state_rules` fall back to the single walk clip on
the default branch — animals walk continuously instead of idling
when stopped. Accept as v1 limitation; Tripo may add idle presets
later, at which point update entity defs (no engine change).

### Strategy C: Code-draw fallback (default)

Pure JSON. Each entity references a shape from `data/shapes.json`
(2D) or `data/meshes.json` (3D):

```jsonc
{
  "id": "wheat_mature",
  "visual": {
    "shape": "crop_mature",
    "flip_with_velocity": true,   // optional — mirror sprite when velocity.x flips sign
    "params": {"grain": "#d4b54a"}
  }
}
```

This is the **default fallback strategy** — every entity should at
minimum have a shape reference. Library / AI-gen are upgrades.

**Critical: shapes.json lives at `data/shapes.json` (root), NOT per-game.**
The renderer's `shapes_path` is hardcoded to `res://data/shapes.json`.
A `shapes.json` placed at `data/demo_<game>/shapes.json` is dead — never
loaded. Add per-game shapes by appending to the root file.
(Empirically discovered: a sim demo once shipped a per-game shapes.json
that did nothing — every entity rendered as a grey circle. Tier 2.6h
finding.)

**Visual sizing — use 12-30px range:**
- Small entities (seeds, tiles): radius 4-8 OK, but 8+ recommended
- Medium (crops, animals, fish): radius 12-18
- Large (structures, buildings): 25-40
- Sun / large decor: 30-50
- **3-6px is too small** to read at default zoom levels. Tinypond
  shipped at 3-6px first and was illegible. Default to 12+.

**Directional sprites should opt into `flip_with_velocity: true`.**
Required for fish, characters, vehicles — anything that visually has
"front" and "back". Renderer mirrors `scale.x` based on velocity.x sign.
Convention: art is drawn facing right; flip happens when moving west.

### Strategy C2: Kit-of-parts composite meshes (3D buildings, 2026-05-27)

> **2026-10-15 (ADR 0083).** Author each new kit with the forked skill
> `/yume-mesh-author`. It plans the parts, validates them, renders a
> calibrated turntable and fixes up to 3 rounds. Kits can now use
> `lathe`, `extrude`, `sweep`, CSG cuts and a shared `materials` block.
> See `.claude/skills/yume-mesh-author/reference/mesh-ops.md`.

A `data/meshes.json` entry can compose MANY primitives into one
recognizable object — a "kit". Each primitive is
`{op, pos, size|radius|height, color}` in UNIT space (y 0..1);
`state.scale = [W, H, D]` sizes the whole kit per instance. `color`
may be a literal hex OR a `$param` token resolved from the entry's
`params` block (or overridden per-instance by `visual.params`).

```jsonc
"house_2f": {
  "primitives": [
    {"op": "box",   "pos": [0, 0.40, 0],  "size": [1.0, 0.80, 1.0],  "color": "$albedo"},
    {"op": "prism", "pos": [0, 0.88, 0],  "size": [1.12, 0.26, 1.12], "color": "$roof"},
    {"op": "box",   "pos": [0, 0.45, 0],  "size": [1.03, 0.035, 1.03], "color": "$trim"},
    {"op": "box",   "pos": [-0.27, 0.25, -0.5], "size": [0.12, 0.13, 0.04], "color": "$window"}
    // ...door, more window rows, chimney
  ],
  "params": {"albedo": "#b85030", "roof": "#6e3b2e", "door": "#2c1c12",
             "window": "#7da8c0", "trim": "#5a4836", "chimney": "#4a4038"}
}
```

ops available: `box`, `sphere`, `cylinder`, `prism`, `capsule`,
`plane`, `quad`, `torus`. The map pipeline (compose_world) routes a
class/bucket to a kit via the strategy's `mesh` field.

**Buildings must READ as buildings, not extruded boxes. Two rules:**

1. **Proportional height — never ship thin towers.** A fitted
   footprint of ~2m with a 6-11m height reads as a tower, not a
   house. Tie height to floor count: 1 floor ≈ 3.5m, 2 ≈ 6.5m,
   3 ≈ 9.5m. For map-extracted buildings, the area-bucket picks the
   floor tier (small=1f, medium=2f, large=3f) AND the matching kit.

2. **Make the storey count legible.** A 3-floor box with one window
   doesn't read as 3 floors. Give each kit a window ROW per storey
   plus a floor-divider trim band between rows (see `house_1f` /
   `house_2f` / `house_3f` in meshes.json). The rows + dividers make
   the floor count obvious at any fitted footprint.

**`$albedo` is the per-instance body color; everything else is a kit
default.** `primitive_visual` in compose_world overrides ONLY the
`albedo` param with the instance's color. Roof/door/window/trim keep
the kit's authored defaults — so author those to look good as a
family.

**Building color comes from a DESIGNED albedo, NOT the semantic-map
classification hex.** The catalog hex (e.g. townhall `#c02040`) is a
MAP CLASSIFICATION color picked for color-separation in the semantic
map — it is not a display color and often reads wrong (that crimson
renders as pink). Set the strategy's `albedo` field to a designed
building color (`#b03828` brick-red) so the kit body uses it instead
of the raw classification hex. See [[feedback-prompt-game-perspective]]
and `extraction_strategies.json` — fountain/townhall both override
`albedo` this way. Empirical case 2026-05-27: townhall shipped pink
because compose_world used the `#c02040` classification hex as the
body color until a strategy `albedo` override was added.

Current kits: `house_1f`/`house_2f`/`house_3f` (floor-tiered),
`tower_kit`, `townhall_kit` (two-tier + columns + finial),
`bridge_kit` (deck + railings + abutments), `wall_kit` (body + cap +
crenellation merlons), `fountain_kit`. Long-term these primitive
parts can be swapped for Tripo3D part-meshes on the same recipe.

### Textured prims — three UV traps (2026-06-12, autorace)

1. **BoxMesh UV-maps a dice-style atlas.** An `albedo_texture` on
   `prim_unit_box` renders as BANDS (each face samples a different
   atlas cell), not artwork. For signs / banners / billboards use
   the `prim_unit_banner` kit (full-UV quad pair) from meshes.json.
2. **Anisotropically scaled prims stretch UVs per instance** — road
   segments of varying lengths each stretch the texture differently.
   Set `visual.texture_triplanar: true` (+ `visual.texture_scale`)
   for world-uniform tiling independent of instance scale.
3. **Tileable textures**: author LOW-CONTRAST with no landmark
   features, and verify with a ground-level CLOSE-UP capture — an
   overview hides the repeat grid (`.claude/rules/visual-qa.md`
   baseline #10).
