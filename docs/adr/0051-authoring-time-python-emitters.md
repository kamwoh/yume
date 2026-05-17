# ADR 0051 — Authoring-time Python emitters (codegen + asset-gen)

_Date: 2026-05-17_
_Status: accepted_

## Context

Yume's authoring surface has two recurring frictions:

**Friction 1 — typo-fragile rule JSON.** Hand-authored rules
repeatedly hit the same bug classes: brace-wrapped bindings
(`"{world.X}"` vs `world.X`), wrong context-binding names
(`self.foo` in a signal rule whose binding is `actor.foo`), schema
landmines (`state_add` with `delta` vs `amount`). Each slipped
through unit + scenario tests for weeks before live play surfaced
it. Validators (`tools/validate_rules.py`) catch most at sync
time, but the iteration loop (author → run validator → fix) is
slow when generating many similar rules.

**Friction 2 — flat-color, code-drawn-only art.** Every entity
ships as a code-drawn primitive composition (boxes, cylinders) +
flat albedo colors. New games look immediately identifiable as
"Yume engineering preview." The visual-density vocabulary
(`.claude/rules/data-demo.md`) helps via layout discipline but
doesn't solve the per-entity aesthetic ceiling. AI image/mesh
generation could unblock this — but only with a pipeline that
ties prompts to entity defs + routes output back to the renderer.

Both frictions share a shape: **authoring is canonical-JSON, but
the author would benefit from a Python helper that emits that JSON
+ companion assets.**

Constraints (from ADR 0021 + Invariant #1):
- JSON remains the authoritative content format. The engine MUST
  read JSON, not Python.
- Validators (`tools/validate_*.py`) are the contract gate. Any
  emitter MUST produce JSON that passes them.
- Hand-authoring stays fully supported. Python is optional;
  authors can edit JSON directly.

## Decision

Ship two Python packages under `tools/` that are **authoring-time
emitters** — they read author intent (Python keyword arguments OR
prompt strings in entity defs) and emit canonical JSON / asset
files that the engine consumes unchanged.

### Package 1: `tools/yume_codegen/`

Composable builders for rule / entity / screen / lib_ref JSON
dicts. Each builder returns a plain `dict` so they mix freely with
hand-written JSON. The canonical authoring example:

```python
from tools.yume_codegen import (
    rule, tick, signal_trigger, query, require,
    state_add, array_insert_first_empty, save_rules,
)

rules = [
    rule(
        id="gather_pickup",
        trigger=signal_trigger("gather_request"),
        require=require(
            actor={"tags_all": ["player"], "state": {"inventory_empty_count_gt": 0}},
            target={"tags_all": ["forageable"]},
        ),
        effect=[
            array_insert_first_empty(
                target="actor", field="inventory",
                value="target.def_id", sentinel="",
                result_field="_last_slot",
            ),
            # ... binding name 'actor' is visible in code review
            # alongside 'actor.state._last_slot' formula below
        ],
    ),
]
save_rules("godot/data/demo_X/world/rules/02_inventory.json", rules)
```

The typed keyword arguments catch:
- `effect=[]` → `ValueError` at build time
- `state_clamp(min=None, max=None)` → `ValueError` (one bound required)
- `require(actor=..., target=...)` → binding names visible in code
  alongside `actor.state.X` formulas (the bug-class trigger from
  2026-05-16's repeated `gather_pickup` crash)

Modules: `rules.py`, `effects.py`, `entities.py`, `screens.py`,
`lib_refs.py`, `io.py`. ~720 LoC total.

### Package 2: `tools/yume_assetgen/`

Reads `data/<game>/asset_gen.json` (backend + style config),
walks entity defs for `*_prompt` fields under `visual:`, assembles
styled prompts, dispatches each to the configured backend, writes
output to `assets/textures/<entity_id>.png` and
`assets/meshes/<entity_id>.glb`, then patches the entity def in
place to reference the resolved file.

Backend abstraction: `tools/yume_assetgen/backends/base.py::Backend`
exposes `generate_texture(prompt, out_path, size)` and
`generate_mesh(prompt, out_path)`. Each backend implements one or
both. `REGISTRY` maps backend names (the `backend` field in
asset_gen.json) to classes.

Backends shipping in v1:
- `mock` — pure-stdlib, no external API calls. Emits prompt-hash-
  deterministic gradient PNGs + 24-vertex cube `.glb`s with the
  prompt's hue. Useful for end-to-end pipeline testing + visual
  placeholder until real art is generated.

Backends slotted-but-not-implemented (future sessions):
- `openai_images` (DALL-E 3 textures)
- `stable_diffusion_local` (Automatic1111 / ComfyUI HTTP)
- `tripo3d` (text + image → `.glb` skinned meshes)

The pipeline is the substrate; backend choice is per-project (set
in `asset_gen.json`).

### Engine support (companion to asset-gen)

For the asset-gen output to actually render, `entity_mesh_3d.gd`
gained:
- **`visual.albedo_texture`** on code-drawn meshes: walks every
  primitive's StandardMaterial3D + sets `albedo_texture` from a
  `res://` path. Per-primitive flat colors stay as tint atop.
- **Extended `material_overrides`** dict form (vs the legacy
  string-color shorthand) on `.glb` meshes: each entry can be
  `{albedo_color, albedo_texture, normal_texture, roughness,
  metallic}`. Material_overrides for `.glb`-backed entities was
  ADR 0046 Phase B; this ADR adds the texture-bearing patch.

## End-to-end flow (asset-gen)

```
┌──────────────────────────────────────────────────────────────┐
│ 1. AUTHOR — add *_prompt fields to entity defs                │
│                                                                │
│   "visual": {                                                  │
│     "color": "#a0c0e0",                                        │
│     "albedo_texture_prompt": "weathered villager body",        │
│     "mesh_prompt": "low-poly humanoid, T-pose"                 │
│   }                                                            │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. PIPELINE RUN                                                │
│   python3 -m tools.yume_assetgen demo_mygame                   │
│                                                                │
│   a) Load asset_gen.json (backend, style, output dirs)         │
│   b) Walk entities/**/*.json — collect *_prompt fields         │
│   c) Assemble: global_prefix + raw + <kind>_suffix             │
│   d) Dispatch to backend → PNG / .glb output                   │
│   e) Patch entity def in place:                                │
│        visual.albedo_texture = "res://data/mygame/assets/..."  │
│        visual.mesh           = "res://data/mygame/assets/..."  │
│      (preserves the *_prompt field so re-runs see it again)    │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. GAME LAUNCH — engine reads patched entity def               │
│                                                                │
│   entity_mesh_3d.gd dispatch:                                  │
│                                                                │
│   visual.mesh ends with .glb? ──── YES ─┐                      │
│                                          │ Phase B path        │
│                                          ▼                      │
│   _load_glb_mesh:                                              │
│     • load(path).instantiate(), add as child                   │
│     • find embedded AnimationPlayer                            │
│     • apply material_overrides {albedo_texture: res://...}     │
│     • register state_rules + clip_alias map                    │
│                                                                │
│   ────── NO (mesh-lib name) ────►                              │
│   Tier 2 mesh-lib path:                                        │
│     • compose primitives from meshes.json                      │
│     • if visual.albedo_texture present:                        │
│         walk children → paint every primitive's albedo_texture │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
                  player sees the textured /
                  skinned entity rendering
```

## Consequences

**Positive:**
- Typed authoring catches binding-name + schema bugs at author
  time instead of live-play crash (the `gather_pickup` class).
- AI-gen pipeline is plug-in: real backends slot into
  `tools/yume_assetgen/backends/` without changing pipeline code.
- Mock backend lets us smoke-test the full chain (prompt → file
  → engine load → render) without paying for API calls.
- JSON canonical-ness intact: codegen + assetgen both emit JSON
  + asset files that the engine reads exactly as before. Hand-
  authoring keeps working.
- Validators are the contract gate; emitter output passes them
  by construction.

**Negative:**
- Two more Python packages to maintain (~2000 LoC total).
- Real backends need API keys + per-backend testing; users without
  cloud access can only run the mock backend.
- Generated assets sit in `data/<game>/assets/` and are gitignored
  by convention — re-runs regenerate from the same prompts +
  backend, but reproducibility depends on the backend's
  determinism (mock is deterministic; OpenAI is not).

**Neutral:**
- Authoring path is now 3-way (hand JSON, codegen, asset-gen).
  Authors pick the right tool per situation; README documents the
  choice points.

## Alternatives considered

**A. Skip codegen + assetgen; double down on prose skills + LLM
authoring.** Rejected because the bug classes recur regardless of
authoring source — the validator-as-gate pattern works but the
debugging loop is slow. Typed Python catches the class at author
time, not sync time.

**B. Embed Python evaluation in the engine (PyGodot, GDExtension
binding).** Rejected outright. Would violate ADR 0021 (Yume = JSON
layer; engine reads JSON, period) AND Invariant #1 (no genre-specific
runtime in the engine). Python at authoring time is fine; Python at
runtime is not.

**C. Use a real schema-validation library (jsonschema, pydantic)
instead of validators + typed builders.** Considered. pydantic
would give type safety but require authors to learn a new abstraction
layer + adds a dep. The typed-keyword approach gives 80% of the
type-safety value in stdlib-only Python. Validators continue to
play the "contract gate" role unchanged.

**D. Generate `.tres` resources via Godot's editor scripts instead
of JSON files.** Rejected because `.tres` is Godot-specific binary-
ish and breaks the "JSON canonical, human-readable, LLM-editable"
property. JSON files diff cleanly; `.tres` doesn't.

## References

- `tools/yume_codegen/README.md` — codegen authoring guide
- `tools/yume_assetgen/README.md` — asset-gen authoring guide
- `tools/yume_codegen/tests/test_smoke.py` — 30 builder assertions
- `tools/yume_assetgen/tests/test_smoke.py` — 19 pipeline assertions
- `godot/scripts/renderer_3d/entity_mesh_3d.gd::_apply_albedo_texture_to_primitives`
- `godot/scripts/renderer_3d/entity_mesh_3d.gd::_apply_override_patch`
- ADR 0021 — Yume = JSON layer over Godot
- ADR 0046 — Animation via AnimationPlayer (Phase B's `.glb`
  loader is upstream of this ADR's material-override extension)
- task_plan.md § 2026-05-17 — full session log
- task_plan.md § 2026-05-16 — bug-class motivation that drove codegen
