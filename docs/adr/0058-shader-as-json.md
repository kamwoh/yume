# ADR 0058 — Shader as JSON (templates + composable primitives)

_Date: 2026-05-23_
_Status: proposed_

## Context

Per `docs/00_what_yume_is.md`, Yume is an explicit programmable
world model whose specification language is JSON. The seven
primitives are the alphabet of the world model itself; ADR 0021
(`expose, don't reimplement`) directs us to use Godot as the
*projection function* (state → pixels) rather than re-implementing
rendering.

But the current shader system breaks the "JSON is the spec" rule:

- `data/lib/shaders/ground_5biome.gdshader` is hand-written GLSL.
- It hardcodes a 5-biome vocabulary (`dirt / grass / water / path /
  forest`) into uniforms, fragment-side weight math, and a fixed
  5-way blend.
- Adding a 6th biome ("snow" for a winter game) means editing GLSL.
  Adding a custom biome name means editing GLSL. Removing an unused
  biome means editing GLSL.
- The same shader can't be reused across games whose biome sets
  differ.

Shader content is *projection-configuration*, not engine code. It
should be JSON-specified like every other piece of world / scene
content. The hand-written .gdshader file is a temporary
implementation artifact, not the long-term content channel.

Two adjacent design tensions:

1. **GLSL is high-performance / hand-tunable.** A fully-generic
   "shader DAG compiler" risks producing slower GLSL than the
   current hand-written version, and slows iteration on visual
   tuning.
2. **The space of shader operations is large but bounded.**
   Most game shaders compose from a small set of operations:
   sample-textured-input, blend-N-inputs, displace-vertex,
   compute-normal, scroll-UV, animate-by-TIME, modulate-by-mask,
   project-to-world-space. ~20-30 such primitives cover the
   majority of cases.

The right move is to land the JSON-spec capability in two
deliberately-layered phases that can both ship value and don't
lock us into either extreme.

## Decision

Adopt a **two-phase layered design**:

### Phase A — Shader templates with parameterized expansion

The shader is a **template** with named placeholders. A codegen
tool reads the JSON description from `scene.json` (or a per-game
shader-spec file), substitutes placeholders, and emits a concrete
`.gdshader` per game. The TEMPLATE lives in the shared library;
the CONCRETE compiled .gdshader is a per-game artifact (gitignored
like other generated assets).

Concrete shape:

- `data/lib/shaders/templates/ground_biome.gdshader.j2` — Jinja2
  template (lightweight, well-known, already in our Python stack
  for other tools). Placeholders for biome count, biome names,
  optional features (water animation, displacement, per-biome
  material).
- `data/<game>/shader_spec.json` — declarative spec:
  ```jsonc
  {
    "template": "ground_biome",
    "biomes": [
      {"name": "dirt",   "color": [0.66, 0.55, 0.32], "roughness": 0.92, "metallic": 0.00},
      {"name": "grass",  "color": [0.62, 0.85, 0.44], "roughness": 0.95, "metallic": 0.00},
      {"name": "water",  "color": [0.19, 0.44, 0.75], "roughness": 0.25, "metallic": 0.05, "animate": true},
      {"name": "path",   "color": [0.78, 0.66, 0.47], "roughness": 0.80, "metallic": 0.00},
      {"name": "forest", "color": [0.16, 0.35, 0.16], "roughness": 0.90, "metallic": 0.00},
      {"name": "snow",   "color": [0.92, 0.94, 0.97], "roughness": 0.85, "metallic": 0.00}
    ],
    "features": {
      "water_animation": {"speed": 0.15, "amplitude": 0.06},
      "displacement":    {"scale": 0.6, "offset": -0.5},
      "blend_softness":  0.10
    }
  }
  ```
- `tools/yume_shadergen/__main__.py` — CLI: reads
  `data/<game>/shader_spec.json`, renders the template, writes the
  concrete shader to `data/<game>/assets/shaders/ground.gdshader`,
  patches `scene.json.ground.mesh.shader` to point at it.
- `scripts/play.sh` — invokes shadergen before sync (next to the
  existing asset gen step).

**What Phase A delivers:**
- Game-specific biome sets without GLSL edits
- Optional features (water animation, displacement) flip on/off
  declaratively
- Hand-tuned GLSL math preserved inside the template
- One template per shader family (ground, water-only, sky, etc.)

**What Phase A does NOT deliver:**
- Cross-shader composition (water_uv_scroll can't be reused in a
  fountain shader)
- DAG-style authoring (still procedural)
- Live preview / hot-reload across template edits

### Phase B — Composable shader primitives

Shader operations become first-class Yume vocabulary, the same way
the seven core primitives are vocabulary for world rules. Each
primitive is a small, typed, JSON-describable unit:

```jsonc
{
  "id": "ground_5biome_demo",
  "stages": {
    "vertex": [
      {"op": "sample_height_map",
       "params": {"map": "$heightmap", "uv_space": "world_xz"},
       "output": "height_offset"},
      {"op": "displace_vertex_y",
       "params": {"amount": "$height_scale", "value": "@height_offset"}},
      {"op": "compute_normal_from_height",
       "params": {"map": "$heightmap", "eps": 0.001},
       "output": "NORMAL"}
    ],
    "fragment": [
      {"op": "sample_biome_map",
       "params": {"map": "$biome_map", "uv_space": "world_xz"},
       "output": "biome_color_probe"},
      {"op": "biome_blend",
       "params": {
         "probe": "@biome_color_probe",
         "biomes": "$biomes",
         "softness": "$blend_softness"
       },
       "output": "blend_weights"},
      {"op": "tile_sample_per_biome",
       "params": {
         "weights": "@blend_weights",
         "biomes": "$biomes",
         "uv_tile": "$uv_tile",
         "animate": {"water": {"speed": "$water_scroll_speed",
                               "amplitude": "$water_scroll_amplitude"}}
       },
       "output": "ALBEDO"},
      {"op": "weighted_material_blend",
       "params": {"weights": "@blend_weights", "biomes": "$biomes"},
       "outputs": ["ROUGHNESS", "METALLIC"]}
    ]
  }
}
```

A compiler walks the DAG, validates input/output types match,
inlines parameters from JSON (`$param`), threads outputs through
the GLSL pipeline (`@output_name`), and emits a concrete .gdshader.

**Primitive interface** (every primitive declares):
```jsonc
{
  "id": "biome_blend",
  "stage": "fragment",            // vertex | fragment | both
  "inputs":  {"probe": "vec3", "biomes": "list<biome>", "softness": "float"},
  "outputs": {"weights": "list<float>"},
  "glsl_template": "...",
  "uniforms_required": [],
  "varyings_required": ["v_world_pos"]
}
```

**Primitives in the starter set** (10-12):
- `sample_world_uv`, `sample_height_map`, `sample_biome_map`
- `tile_sample`, `tile_sample_per_biome`
- `biome_blend`, `weighted_material_blend`
- `displace_vertex_y`, `compute_normal_from_height`
- `uv_scroll_animated`, `triplanar_sample`
- `procedural_noise_2d`

Each primitive's GLSL template is hand-tuned. The compiler's job is
composition + parameter binding, not GLSL synthesis.

**What Phase B delivers:**
- Shader fragments reusable across domains (water_uv_scroll works in
  a fountain, biome_blend works on a backdrop sky, etc.)
- Type-checking at compile time (catches "you passed a vec3 to a
  float input" at sync time, not at GLSL compile time)
- A path for non-developers to compose shaders
- A real "primitives + interpreter" architecture for the projection
  layer, mirroring the world-model layer's primitives + interpreter

**What Phase B does NOT deliver:**
- Auto-tuning / auto-optimization (compiler emits hand-written GLSL
  per primitive, doesn't rewrite)
- Visual graph editor (JSON DAG only; visual editor is a future ADR
  if it's worth doing)

## Generality principles (applies to BOTH phases)

These are the design rules that prevent us from painting ourselves
into a corner:

1. **Names are not vocabulary.** `dirt / grass / water` are
   *content-level labels* in a specific game, not primitives.
   The template / DAG accepts N biomes named freely. No primitive
   should hardcode "water is biome 3."

2. **Counts are parameters, not constants.** Whenever the current
   GLSL has a literal `5` (biomes) or `4` (something else), the
   refactor must expose it as a JSON parameter. The compiler/
   template loops over the actual count.

3. **Stages are explicit.** Every operation declares whether it
   runs in vertex, fragment, or both. The compiler enforces
   ordering and varying declarations.

4. **Types are typed.** Inputs/outputs declare types (`float`,
   `vec3`, `sampler2D`, `list<T>`). The compiler refuses to
   connect mismatched types.

5. **Hand-tuned GLSL stays hand-tuned.** Phase A's templates and
   Phase B's primitive `glsl_template` fields are written by humans
   for performance + quality. The compiler does composition, not
   synthesis. We don't auto-generate GLSL from algebraic specs.

6. **JSON-first, GLSL-last.** No game-specific GLSL files should
   land in `data/<game>/` long-term. The per-game artifact is a
   compiled .gdshader, equivalent to a baked texture — content,
   not code.

7. **Each phase replaces the previous outright.** Yume is pre-1.0;
   there are no external users on the shader system. Phase A
   replaces hand-written `data/lib/shaders/*.gdshader` with
   templates. Phase B replaces templates with primitive DAGs.
   We migrate shaders one at a time and DELETE the old version
   once the new one ships — no deprecation period, no parallel
   systems, no compatibility shims. Cleanest move from any state
   is to overwrite + commit.

## Consequences

**Positive:**
- Game authors stop seeing GLSL. Adding "snow" to a winter game is
  one JSON entry, not a GLSL edit.
- The 5biome shader's hardcoded biome set becomes one *example* of
  a possible biome set, not a constraint.
- Generality from day one: even Phase A's template-substitution
  pattern is N-biome-ready, so a future game with 7 biomes won't
  require an architectural change.
- Phase B's primitive set is reusable across shaders, opening the
  door to a *primitives + interpreter* projection layer that
  mirrors the world-model layer. Both halves of Yume — world model
  AND projection function — become JSON-driven.
- Aligns shader work with the world-model framing in
  `docs/00_what_yume_is.md`: projection configuration is content.

**Negative:**
- New build step: shader codegen must run before Godot sync. Same
  shape as `tools/yume_assetgen/` and `tools/yume_codegen/`.
- Compiled shaders are a build artifact. They live under each game
  directory (gitignored) and are regenerated from the JSON spec.
  This adds one more thing to .gitignore + the sync logic.
- Phase B's DAG validation is non-trivial. The compiler needs
  type-checking, topological-sort, varying-dependency tracking.
  Expect 500-1000 lines of Python for the compiler.

**Neutral:**
- No engine GDScript changes. The runtime still loads a .gdshader
  via `scene.json.ground.mesh.shader`. Only the *origin* of the
  .gdshader file shifts (hand-written → template-rendered → DAG-
  compiled). Engine doesn't care.

## Alternatives considered

1. **Keep hand-written GLSL forever** — current state. Every new
   biome / lighting feature / animation needs GLSL edits. Violates
   ADR 0021 (`projection should be JSON-driven` is the natural
   extension of `world model is JSON-driven`). Rejected.

2. **Phase A only, skip Phase B.** Templates handle most current
   pain. But each new shader (water-only, sky, fog, fountain)
   gets its own template, and no primitive reuse across them.
   Acceptable as a long-term state IF Phase B's added complexity
   exceeds its reuse benefit — but we should at least design
   Phase A's spec format so it can later be subsumed by Phase B
   without a content migration.

3. **Use Godot's VisualShader directly.** Godot 4 has a built-in
   visual shader graph. We could author shaders as `.tres`
   resource files. Rejected: VisualShader is editor-bound (.tres
   isn't human-authorable, isn't diff-friendly, isn't JSON),
   doesn't compose well with our existing scene.json driven
   pipeline, and abandons the JSON-spec property we want.

4. **Use a third-party shader DSL** (ShaderToy-style, Slang, WGSL,
   etc.). Rejected: extra dependency, extra learning curve, and
   none are JSON. Phase B's DAG is more constrained than these
   general-purpose DSLs but exactly what we need.

## Phasing

### Phase A — Templates (target: 1-2 weeks)

- **A.1**: Convert `ground_5biome.gdshader` to
  `data/lib/shaders/templates/ground_biome.gdshader.j2`. Replace
  hardcoded biome slots with Jinja2 loops over `biomes` list.
- **A.2**: Build `tools/yume_shadergen/` CLI. Reads
  `data/<game>/shader_spec.json`, renders templates, writes
  `data/<game>/assets/shaders/<name>.gdshader`, patches
  `scene.json.ground.mesh.shader` to point at it.
- **A.3**: Migrate `demo_aldenmere` from the hardcoded 5-biome
  shader to the template-driven version. Same visual output;
  validate via the new visual_qa runner from ADR 0056.
- **A.4**: Update `scripts/play.sh` to call shadergen before sync
  (gated on whether `shader_spec.json` is newer than the compiled
  output, like Makefile dependency tracking).
- **A.5**: Document the new authoring path in
  `docs/30_framework_primitives.md` § Shaders (new section).

**Acceptance:** Aldenmere renders identically before vs. after.
Adding a 6th biome to a hypothetical new game requires zero GLSL
edits.

### Phase B — Composable primitives (target: 4-6 weeks)

- **B.1**: Define primitive interface schema
  (`data/lib/visual_qa/shader_primitives/primitive.schema.json`).
  Land 4-5 starter primitives with hand-tuned GLSL templates.
- **B.2**: Implement DAG compiler
  (`tools/yume_shadergen/compiler.py`). Topological-sort the DAG,
  validate types, emit .gdshader. Unit-test against synthetic DAGs.
- **B.3**: Migrate `ground_biome` template to a DAG spec.
  Verify identical output to Phase A's templated version.
- **B.4**: Land the remaining 6-8 primitives (water animation,
  triplanar, procedural noise, etc.).
- **B.5**: Delete the Phase-A template engine and templates;
  Phase B's compiler replaces it. Migrate all Phase-A `.j2`
  templates to primitive DAGs in the same commit.
- **B.6**: Document primitive vocabulary in
  `docs/30_framework_primitives.md` § Shader primitives.

**Acceptance:** at least 2 distinct shaders (ground + e.g. sky or
water-only) share 3+ primitives between them. Adding a new shader
domain requires only new primitive instances in JSON, no compiler
changes for common cases.

## Open questions

1. **Live reload.** Phase B should support `shadergen --watch` so
   editing the JSON DAG triggers re-compilation + Godot reimport
   without restarting the game. Phase A first; live reload as B.7.
2. **Cross-game primitive registry.** Should games be able to
   ship their own primitive `.json` files in
   `data/<game>/shader_primitives/`, or are primitives strictly
   library-level? Recommend library-level for now; promote a
   game-local primitive to library if a second game adopts it.
3. **Performance regression detection.** When Phase A's
   template-rendered shader replaces the hand-written one, we
   should benchmark FPS to confirm no regression. Add an
   acceptance gate similar to ADR 0055's ≤5% drop threshold.
4. **Editor preview.** Should `tools/yume_shadergen/` produce a
   live preview during authoring (compiled shader applied to a
   sphere/quad in a headless Godot view)? Probably a Phase C
   ADR if it earns its keep.

## Related

- `docs/00_what_yume_is.md` — the framing this ADR is derived from
  (Yume = explicit world model; projection is content, not code)
- ADR 0021 — Yume is a Godot layer (expose, don't reimplement)
- ADR 0052 — Shader as visual primitive (declared `ground.mesh.shader`
  field; this ADR completes the "shader is content" picture)
- ADR 0055 — Multi-biome ground from semantic map (the hardcoded
  5-biome shader being unblocked by this ADR)
- ADR 0051 — Authoring-time Python emitters (the precedent for
  codegen tools alongside the JSON content)
- `docs/30_framework_primitives.md` — primary contract doc; gets
  a new section after Phase A and another after Phase B
