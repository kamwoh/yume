# ADR 0055 — Multi-biome ground from the semantic map

_Date: 2026-05-20_
_Status: accepted (v2, reviewed by yume-tech-director 2026-05-20)_

_Revision log:_
- v1 → v2 (2026-05-20): closed 5 gaps from yume-tech-director review:
  level-transition rebind, world-space UV math, visual gate
  declaration, texture-acquisition path, FPS acceptance threshold.
- v2 accepted (2026-05-20): all invariants hold (1, 2, 3, 5, 8, 9,
  10, 11, 12 verified). Extends ADR 0052's existing shader primitive
  + adds one new engine method (`GroundRenderer.rebind_shader_params`)
  with documented invariant-#11 semantics.

## Context

The Tier 2.7v wireframe-to-map harness (compose_map + wireframe_to_map
+ yume-map-author) shipped 2026-05-20. It produces fit-fit entity
placements from a gemini-3.1 semantic top-down map. End-to-end works
for ENTITIES (anchors + scatter zones).

What it does NOT translate from the map to the in-engine scene:

- **Water bodies** (blue regions in the semantic map → a river)
- **Trampled dirt paths** (tan thin lines connecting anchors)
- **Grass-vs-dirt ground variation** (light green clearing vs base
  ground texture)

These read VISUALLY in the semantic map but the harness has no way
to surface them in 3D — they're not entity placements; they're
GROUND TEXTURE variations across the world floor.

Empirical case 2026-05-20: user generated a 3D-rendering preview of
the same semantic map via nanobanana
(`camp_map_e599183e_3drender.png`). The preview correctly showed:
- River as a blue water surface at the bottom
- Tan dirt paths radiating from the campfire
- Grass clearing with dry tufts + leaves
- Forest ring around the clearing

The harness output rendered the entities correctly but the GROUND
under them is a single uniform autumn-dirt texture (per
`scene.json:ground.albedo_texture`). The mismatch between the
semantic map's visual richness and the in-engine ground is the gap.

Phase A (2026-05-20) added flavor scatter entities (grass tufts,
fallen leaves) to lift soul.md axis 8 — but those are ENTITIES, not
ground. They don't address river/path regions. Per soul.md
composition axis 1 ("layered ground variation"), even with
abundant flavor entities the underlying floor still reads as
"prototype map" if it's monochrome.

## Decision

Author a **multi-biome ground shader** that samples a biome map
(8-bit colored PNG, one color per biome region) and blends N albedo
textures into the rendered ground. The biome map IS the semantic
map already produced by `compose_map.py` — no separate authoring
step needed.

Engine surface:

```jsonc
// scene.json (new fields under ground.mesh)
{
  "ground": {
    "mesh": {
      "size": [80, 80],
      "shader": "res://shaders/multi_biome_ground.gdshader",
      "shader_params": {
        "biome_map": "res://data/demo_aldenmere/assets/layouts/camp_map_e599183e.png",
        "biome_color_dirt":  [0.66, 0.55, 0.32, 1.0],  // base dirt (default)
        "biome_color_grass": [0.62, 0.85, 0.44, 1.0],  // #a0d870 light green
        "biome_color_water": [0.19, 0.44, 0.75, 1.0],  // #3070c0 blue
        "biome_color_path":  [0.78, 0.66, 0.47, 1.0],  // #c8a878 tan
        "biome_color_forest":[0.16, 0.35, 0.16, 1.0],  // #2a5a2a dark green
        "albedo_dirt":  "res://data/.../ground_albedo_5e572472_muted_v2.png",
        "albedo_grass": "res://data/.../grass_seamless.png",
        "albedo_water": "res://data/.../water_seamless.png",
        "albedo_path":  "res://data/.../dirt_path_seamless.png",
        "uv_tile": 30.0,
        "blend_softness": 4.0
      }
    }
  }
}
```

Shader logic (pseudocode):

Gap-2 fix: the biome_map MUST be sampled in **world space** (not raw
UV) because (a) the plane uses `uv1_scale` for tileable detail —
fragment UV is `[0, uv_tile]` not `[0, 1]`; (b) per
[[reference_godot_shader_coord_spaces]], `VERTEX` in `fragment()` is
view-space, so a custom `vertex()` is required to forward world-space
position to fragment. The shader maintains TWO UV spaces: one for the
biome lookup (world-space, plane-aligned, `[0,1]` per plane_size),
one for the tiled albedo samples (`UV * uv_tile`).

```glsl
shader_type spatial;
uniform sampler2D biome_map;
uniform vec4 biome_color_dirt;   // etc per biome (5 slots)
uniform vec4 biome_color_grass;
uniform vec4 biome_color_water;
uniform vec4 biome_color_path;
uniform vec4 biome_color_forest;
uniform sampler2D albedo_dirt;   // etc per biome (5 slots)
uniform sampler2D albedo_grass;
uniform sampler2D albedo_water;
uniform sampler2D albedo_path;
uniform sampler2D albedo_forest;
uniform float plane_size;         // set by GroundRenderer (ADR 0052,
                                  // ground_renderer.gd:185)
uniform float uv_tile = 30.0;     // tileable detail scale
uniform float blend_softness = 4.0;

varying vec3 world_pos;           // set in vertex(), read in fragment()

void vertex() {
    // World-space position for biome-map sampling. Avoids the
    // VIEW-space-VERTEX-in-fragment trap (empirical case
    // 2026-05-18 ground-splatmap drift).
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    // Biome UV from WORLD position. Plane center (0,0) → biome (0.5,0.5);
    // plane corner (plane_size/2, plane_size/2) → biome (1,1). Y is
    // mapped to the biome's Y so the semantic map's orientation
    // (image-down = world-south) is preserved.
    vec2 biome_uv = vec2(world_pos.x, world_pos.z) / plane_size + vec2(0.5);
    vec4 biome_pixel = texture(biome_map, biome_uv);

    // Compute color-distance to each biome's reference color
    float d_dirt   = distance(biome_pixel.rgb, biome_color_dirt.rgb);
    float d_grass  = distance(biome_pixel.rgb, biome_color_grass.rgb);
    float d_water  = distance(biome_pixel.rgb, biome_color_water.rgb);
    float d_path   = distance(biome_pixel.rgb, biome_color_path.rgb);
    float d_forest = distance(biome_pixel.rgb, biome_color_forest.rgb);

    // Sample each tileable albedo at the existing UV * uv_tile coords.
    // (UV here is the unscaled mesh UV, [0..1] over the plane; uv_tile
    // gives tileable detail without the biome lookup interfering.)
    vec2 tile_uv = UV * uv_tile;
    vec3 a_dirt   = texture(albedo_dirt,   tile_uv).rgb;
    vec3 a_grass  = texture(albedo_grass,  tile_uv).rgb;
    vec3 a_water  = texture(albedo_water,  tile_uv).rgb;
    vec3 a_path   = texture(albedo_path,   tile_uv).rgb;
    vec3 a_forest = texture(albedo_forest, tile_uv).rgb;

    // Soft-min blend: each biome contributes weight inversely
    // proportional to its color distance, raised by blend_softness.
    float w_dirt   = pow(max(0.001, blend_softness - d_dirt),   2.0);
    float w_grass  = pow(max(0.001, blend_softness - d_grass),  2.0);
    float w_water  = pow(max(0.001, blend_softness - d_water),  2.0);
    float w_path   = pow(max(0.001, blend_softness - d_path),   2.0);
    float w_forest = pow(max(0.001, blend_softness - d_forest), 2.0);
    float wsum = w_dirt + w_grass + w_water + w_path + w_forest;

    ALBEDO = (a_dirt   * w_dirt
            + a_grass  * w_grass
            + a_water  * w_water
            + a_path   * w_path
            + a_forest * w_forest) / wsum;
}
```

### Per-level binding + engine rebind on transition_level (gap-1 fix)

Per invariant #11 (level-discontinuity engine-state cleanup), any
engine state coupled to OLD level identity must declare its swap
behavior. The ground's `biome_map` shader uniform IS such state.

**Choice (a) — per-level override via `levels/<id>/scene.json`**:

A new file `data/<game>/levels/<id>/scene.json` (optional) overrides
the GAME-level `data/<game>/scene.json` for that level. Authors set
ONLY the fields that differ — typically just `ground.mesh.shader_params.
biome_map`. Engine merges the level-level overrides over the game-
level baseline at level load.

```jsonc
// data/<game>/levels/<id>/scene.json — sparse override
{
  "ground": {
    "mesh": {
      "shader_params": {
        "biome_map": "res://data/<game>/assets/layouts/<level-map>.png"
      }
    }
  }
}
```

**Engine change**: `GroundRenderer.rebind_shader_params(level_id)`
static method. Called by `level_transition_coordinator.gd` AFTER
`load_level()` completes (the same callsite that already manages
camera-snap on transition per invariant #11). The method:

1. Reads `data/<game>/levels/<level_id>/scene.json` if it exists.
2. Deep-merges its `ground.mesh.shader_params` over the cached
   game-level shader_params.
3. Calls `material.set_shader_parameter(k, v)` for each changed key
   on the existing Ground MeshInstance3D's ShaderMaterial (no node
   teardown).
4. Resource loading (`load(res_path)`) for any `res://` string-typed
   value, matching `_resolve_shader_param` from `ground_renderer.gd`.

**Snap behavior on transition**: parameters are updated at the same
moment camera-snap fires (after fade-out completes, before fade-in
begins per `transition_level_fade_request`). Zero-fade transitions
update synchronously with the level swap. No interpolation between
biome maps — the shader switches in one frame. The frame-perfect
swap matches camera-snap semantics; the player sees the new biome
map appear behind the entities at the same instant as the new
entities pop in.

**Why not choice (b) ("scene.json stays global")**: defers multi-
level games and reduces the framework's universality claim. Rejected.

### Authoring flow

1. `compose_map` produces the semantic map PNG (unchanged).
2. `wireframe_to_map preprocess` ALSO emits a `biome_config` section
   in the context file: per-color hex from the semantic map, mapped
   to biome name + suggested albedo path (from the game's
   `asset_resolution.biomes` config).
3. `yume-map-author` reads the biome_config + decides which biomes
   are present in this level. Writes a `levels/<id>/scene.json`
   override (sparse — only the ground.mesh.shader_params.biome_map
   pointing at THIS level's semantic map) alongside the level
   entities.json.
4. `postprocess` applies the scene.json override + applies the entities
   (with the same .bak backup discipline as today).
5. **Texture acquisition** (gap-4 fix): per-game albedo assets come
   from extending `tools/yume_assetgen/gen_ground.py` with biome-
   aware prompts — one `nanobanana` call per biome name (e.g.
   "seamless tileable top-down grass meadow texture, autumn palette,
   no central focal point, repeating-pattern safe across all edges"
   for grass). The script writes outputs to
   `data/<game>/assets/textures/biome_<name>_<hash>.png` and the
   resolved paths get auto-filled into `asset_resolution.biomes.<name>.albedo`.
   Matches the existing aldenmere ground-texture workflow
   (ground_albedo_5e572472_muted_v2.png was generated this way).

Per-game `asset_resolution.json` extension:

```jsonc
{
  "biomes": {
    "_doc": "Maps semantic-map color names to albedo textures + the engine biome key.",
    "dirt":   {"hex": "#a8895a", "albedo": "res://.../ground_albedo_muted_v2.png", "engine_key": "biome_color_dirt"},
    "grass":  {"hex": "#a0d870", "albedo": "res://.../grass_seamless.png",         "engine_key": "biome_color_grass"},
    "water":  {"hex": "#3070c0", "albedo": "res://.../water_seamless.png",         "engine_key": "biome_color_water"},
    "path":   {"hex": "#c8a878", "albedo": "res://.../dirt_path_seamless.png",     "engine_key": "biome_color_path"},
    "forest": {"hex": "#2a5a2a", "albedo": "res://.../forest_floor_seamless.png",  "engine_key": "biome_color_forest"}
  }
}
```

## Consequences

**What this enables:**
- Visual richness in the in-engine scene that matches the semantic
  map (river/grass/dirt/path/forest-floor variations visible under
  the entities).
- Soul.md composition axis 1 (layered ground variation) addressed
  at the framework level, not per-game hack.
- Same per-game asset_resolution.json that drives entity placement
  ALSO drives ground texture composition — single source of truth.
- The harness produces both spatial AND visual specs from a single
  semantic map.

**What this costs:**
- One new shader (`shaders/multi_biome_ground.gdshader`).
- One engine method: `GroundRenderer.rebind_shader_params(level_id)`
  + a `level_transition_coordinator.gd` callsite (gap-1 fix).
- Extension of `wireframe_to_map.py` to emit biome_config in context
  + a per-level `levels/<id>/scene.json` override in draft output.
- Per-game albedo asset acquisition via extension of
  `tools/yume_assetgen/gen_ground.py` with biome-aware prompts
  (gap-4 fix). One nanobanana call per biome per game (~$0.05
  each). Outputs to `data/<game>/assets/textures/biome_<name>_<hash>.png`,
  auto-filled into `asset_resolution.biomes.<name>.albedo`.
- Performance: 6 texture samples per ground fragment (1 biome_map
  + 5 albedos) + 5 color distances. **Acceptance threshold ≤5%
  FPS drop** measured on aldenmere at 1080p, single-albedo
  ground vs multi-biome ground. Implementer must capture
  before/after FPS in the acceptance evidence (gap-5 fix).

**Gates that apply at merge time:**

- **Visual gate** (per `.claude/rules/engine-scripts.md` § visual
  validation gate): rendering primitive change. Implementer must
  run `--capture` on aldenmere + invoke `yume-visual-designer`
  for 7-axis review. Any axis regression must be addressed via
  concrete JSON edits before merge. "I'll fix it next session"
  is not a merge condition (gap-3 fix).
- **Post-mortem ritual** (per `.claude/rules/post-mortem.md`): if
  any bug surfaces during implementation, fix → identify the gate
  that should have caught it → harden gate → commit both.
- **No-stray-scripts validator + no commercial game names**
  (existing gates) apply as always.

**What this precludes:**
- A "free-form" biome paint where players author arbitrary new
  biome types in JSON without engine-side shader uniforms. The
  shader has fixed slots (dirt/grass/water/path/forest); adding a
  6th biome (e.g. snow, lava) requires a shader update. ADR-update
  territory.
- Continuous biome heightmaps (snow elevation varies with altitude).
  Future ADR if needed; this one is hard-edge color regions.

## Alternatives considered

**(A) Multi-mesh ground**: spawn separate PlaneMesh per biome region.
- Pros: no shader work; uses standard Godot materials.
- Cons: requires region extraction from the biome map (CV-style),
  re-introduces the fragility we just removed. Each region needs a
  separately-positioned mesh; UV tiling discontinuities at region
  borders.
- Rejected: defeats the LLM-as-parser premise + reintroduces CV.

**(B) Decal-based paths/water**: leave the single ground texture +
overlay decal entities at the path/river positions.
- Pros: simpler — no shader changes.
- Cons: decals are entities, multiplying the entity count by N
  region tiles. Doesn't address grass-vs-dirt clearing variation.
  Visual quality lower (decals tile or stretch unnaturally).
- Rejected: doesn't generalize.

**(C) Bake per-level ground albedo**: at level-build time, composite
the biome map + albedo tiles into ONE big PNG per level, saved as
`assets/textures/ground_<level_id>.png`, swapped into scene.json.
- Pros: zero runtime shader cost; one texture per level.
- Cons: bake step is offline (Python with PIL or similar);
  textures get huge (~16MB per level at 4K). Re-bakes on every
  level edit. Cache invalidation pain.
- Considered but deferred — the shader approach is simpler and
  reuses tileable seamless textures across games.

## References

- `docs/adr/0052-shader-as-visual-primitive.md` — established
  `ground.mesh.shader` field; this ADR uses it.
- `.claude/rules/soul.md` § Composition axis 1 (layered ground
  variation) — the soul rule this ADR addresses.
- `tools/visual_layout/wireframe_to_map.py` — the harness this
  ADR extends.
- `godot/scripts/engine/coordinators/ground_renderer.gd` — current
  ground-rendering path; the entry point for the new shader.
- ADR 0054 (visual-layout-compiler) — defines the LLM-as-parser
  premise this ADR generalizes from entities to ground.
