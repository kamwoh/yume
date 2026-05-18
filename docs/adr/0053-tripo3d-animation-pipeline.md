# ADR 0053 — Tripo3D animation pipeline (rig + retarget capability exposure)

_Date: 2026-05-18_
_Status: proposed_

## Context

Yume's asset pipeline currently produces **static** AI-generated
meshes via Tripo3D's `image_to_model` task. Characters and creatures
in our games translate across the floor via `state.position`
mutations and rotate via `state.yaw`, but their limbs are frozen —
the visual reads as "sliding," not walking.

User request (2026-05-18): expose Tripo's animation pipeline through
a per-entity opt-in so player + named NPCs (and animals, see scope
below) animate when they move. Engine-side animation interpretation
already exists via ADR 0046 Phase B (commit `2026-05-13`):
`entity_mesh_3d._load_glb_mesh` adopts the GLB's embedded
`AnimationPlayer` + clips, and `animation_director.gd` maps engine
state → clip names via `visual.animation_state_rules` and
`visual.clip_alias`. Multi-clip GLB support is verified empirically
at `godot/scripts/engine/tests/test_runner.gd:5069` against
`godot/data/test_assets/cube_anim.glb` (a 2-clip GLB with Idle +
Walking). The capability is loaded but unused — no Yume AI-gen
character currently ships with an animated GLB.

Tripo3D's public API exposes four additional task types that
together produce animated GLBs (credit costs verified against the
official VAST-AI-Research/tripo-python-sdk client.py at
`VAST-AI-Research/tripo-python-sdk@main`):

| Task | Purpose | Approx credits | Approx USD |
|---|---|---|---|
| `image_to_model` | base mesh (existing) | 40 | $0.40 |
| `animate_prerigcheck` | validate that the given mesh can be rigged | 10 | $0.10 |
| `animate_rig` | skeleton bind for a chosen `rig_type` (default `v1.0-20240301`) | 30 | $0.30 |
| `animate_retarget` | apply a preset motion clip with `bake_animation: True` | 30 | $0.30 |

Each retarget call produces a GLB with ONE baked AnimationClip on
the skeleton. The pipeline ends when all desired clips have been
retargeted; merging into one multi-clip GLB happens at the Python
layer (see Decision § merge step).

### Tripo rig types and animation presets (verified 2026-05-18)

The `rig_type` parameter on `animate_rig` accepts EIGHT values, not
biped-only as initially assumed:

```
biped | quadruped | hexapod | octopod | avian | serpentine | aquatic | others
```

Verified from `tripo3d/models.py` (`class RigType(str, Enum)`).
Each rig type pairs with corresponding animation presets:

| `rig_type` | Verified preset clips | Yume use-cases |
|---|---|---|
| `biped` | `preset:idle`, `preset:walk`, `preset:run`, `preset:dive`, `preset:climb`, `preset:jump`, `preset:slash`, `preset:shoot`, `preset:hurt`, `preset:fall`, `preset:turn` | player, named NPCs |
| `quadruped` | `preset:quadruped:walk` (more may exist; not enumerated in SDK) | wolf, deer, rabbit |
| `hexapod` | `preset:hexapod:walk` | giant insect (none yet in Yume games) |
| `octopod` | `preset:octopod:walk` | spider (none yet) |
| `avian` | clip list TBD via API probe | bird |
| `serpentine` | `preset:serpentine:march` | snake |
| `aquatic` | `preset:aquatic:march` | fish, eel |
| `others` | TBD via API probe | fallback for hard cases |

Source: `Animation(str, Enum)` in `tripo3d/models.py` of the
official SDK. The non-biped presets present (one per rig type) cover
the locomotion case; we add others by API probe when needed.

## Decision

Expose Tripo3D's `animate_*` task chain through a per-entity opt-in
field `visual.animate: true` plus an explicit `visual.rig_type`
selector. Pipeline runs the full chain for every supported rig type
(biped + 7 others — see Context table). Multiple retarget GLBs are
merged into a single multi-clip GLB at the Python layer using
`pygltflib`.

### Schema (per-entity, in entity def)

Biped character:
```jsonc
{
  "id": "player_marken",
  "tags": ["actor", "character", "player"],
  "state_init": { "scale": 1.7 },
  "visual": {
    "mesh": "res://data/.../player_marken_animated_<hash>.glb",
    "y_offset_mesh": 0.5,
    "animate": true,
    "rig_type": "biped",                        // explicit; required when animate=true
    "animation_clips": ["idle", "walk"],        // defaults to ["idle","walk"]
    "clip_alias": {                              // auto-emitted; from Tripo preset → engine state
      "idle": "preset:idle",
      "walk": "preset:walk"
    },
    "animation_state_rules": [                   // ADR 0046; existing engine support
      { "if": { "velocity_magnitude_gt": 0.1 }, "play": "walk" },
      { "default": true, "play": "idle" }
    ]
  }
}
```

Quadruped animal:
```jsonc
{
  "id": "wolf",
  "tags": ["animal", "quadruped", "predator"],
  "state_init": { "scale": 1.2 },
  "visual": {
    "mesh": "res://data/.../wolf_animated_<hash>.glb",
    "y_offset_mesh": 0.4,
    "animate": true,
    "rig_type": "quadruped",
    "animation_clips": ["quadruped:walk"],       // current Tripo preset list is locomotion-only for non-bipeds
    "clip_alias": { "walk": "preset:quadruped:walk" },
    "animation_state_rules": [
      { "if": { "velocity_magnitude_gt": 0.1 }, "play": "walk" },
      { "default": true, "play": "walk" }        // no idle preset for quadruped — fall back to walk-loop
    ]
  }
}
```

Authoring discipline:
- `visual.animate: true` REQUIRES `visual.rig_type` set to one of:
  `biped`, `quadruped`, `hexapod`, `octopod`, `avian`, `serpentine`,
  `aquatic`, `others`. The validator rejects animate=true without a
  matching rig_type.
- `animation_clips` defaults to `["idle", "walk"]` for bipeds. For
  non-bipeds it defaults to the SINGLE preset Tripo currently exposes
  for that rig (e.g. `["quadruped:walk"]` for quadrupeds). The
  asset-designer skill explains how to expand once Tripo adds presets.
- `animation_state_rules` is content-designer's job (ADR 0046 schema).
  The asset emitter auto-suggests a `velocity → walk / else idle`
  block for bipeds (or `walk` fallback for non-bipeds without an
  idle preset), but does not overwrite an authored block.
- `clip_alias` is auto-populated by the pipeline. Tripo's preset
  names contain colons (`preset:walk`); Yume's `animation_state_
  rules` use simple names (`walk`). The alias bridges them — same
  mechanism ADR 0046 already documents.

### Pipeline flow (`tools/yume_assetgen/`)

```
                ┌──────────────────────┐
                │ entity has           │
                │ visual.animate=true? │
                └──────────┬───────────┘
                       Yes │
                ┌──────────▼───────────┐
                │ image_to_model       │  $0.40   (existing; ledger-cached)
                │ → base GLB           │
                └──────────┬───────────┘
                           │
                ┌──────────▼───────────┐
                │ animate_prerigcheck  │  $0.10
                │ + rig_type           │  (cached per image + rig_type + rig_model_version;
                │                      │   skip-result also cached)
                └──────────┬───────────┘
                pass │      │ Tripo rejects rig (e.g. mesh too
                     ▼      │  fragmented for this rig_type) →
                     │      │  skip animation, entity stays static,
                     │      └► log + cache the reject verdict.
                ┌──────────▼───────────┐
                │ animate_rig          │  $0.30
                │ + rig_type           │  (cached per image hash + rig_type)
                │ → rigged GLB         │
                └──────────┬───────────┘
                           │
                ┌──────────▼───────────┐
                │ for clip in clips:   │  $0.30 × N
                │   animate_retarget   │  (cached per image+clip)
                │   → 1-clip GLB       │
                └──────────┬───────────┘
                           │
                ┌──────────▼───────────┐
                │ glb_merge.py         │  free
                │ → multi-clip GLB     │
                └──────────┬───────────┘
                           │
                ┌──────────▼───────────┐
                │ patch entity def:    │
                │ visual.mesh = …glb   │
                │ clip_alias = {...}   │
                └──────────────────────┘
```

### Merge step (`tools/yume_assetgen/glb_merge.py`)

Tripo's retarget emits one GLB per animation. Yume's engine expects
one mesh file per entity. Bridge with a Python merge:

1. Load N retarget GLBs via `pygltflib`.
2. Verify all share the same skeleton (same node graph + joint IDs).
   Fail loudly with `ValueError` if not — retarget should always reuse
   the rig task's output, so this is an invariant.
3. Take the mesh + skin + skeleton from GLB 0 as base.
4. Append each GLB's `animations` array to the base's. Adjust internal
   buffer/accessor references so animation channels point at the
   base's skeleton.
5. Write merged GLB with hash-suffixed filename per the existing
   no-overwrite convention.

Expected output: one GLB per character, ~2× base size (skeleton +
mesh + N animations).

**Unit tests required** (ship with the merge tool):

1. Skeleton-matched 2-GLB merge → resulting GLB has both
   `animations[]` entries; both clips load correctly when fed to
   Godot's GLB importer (verified by loading the output via
   `cube_anim.glb`-style scenario test in `test_runner.gd`).
2. Skeleton-mismatched merge → raises `ValueError("skeleton
   mismatch: ...")` BEFORE writing any output file.
3. Single-clip merge (degenerate case) → output is identical to
   input.
4. Animation-name collision (two GLBs both named "walk") → either
   auto-suffix or raise — pick one and test it.

### Ledger keys

Three new entries per entity. All hashed against (prompt, rig_type,
and rig model version) so re-runs don't re-pay AND Tripo model bumps
auto-invalidate stale verdicts:

```
tripo3d:prerigcheck:<sha256(prompt)>:<rig_type>:<rig_model_version>     // cached even on REJECT
tripo3d:rig:<sha256(prompt)>:<rig_type>:<rig_model_version>
tripo3d:retarget:<sha256(prompt)>:<rig_type>:<clip>:<rig_model_version>
```

The `rig_model_version` suffix matters because Tripo's rig models
improve. As of 2026-05-18 the SDK exposes `v1.0-20240301` (default)
and `v2.0-20250506`. A mesh rejected by `v1.0` MIGHT be accepted by
`v2.0` — without version-tagging, a stale cached REJECT would
permanently block future regen attempts after a model bump.

The prerigcheck-REJECT cache is critical: re-running the pipeline
must not re-pay $0.10 per entity to re-confirm a rig that Tripo
already rejected. With the version tag, the cache stays correct
across upgrades.

### Validator (`tools/validators/validate_animate_scope.py`)

Fails sync if:
- Any def has `visual.animate: true` without `visual.rig_type`.
- Any def has `visual.rig_type` set but `visual.animate: false` (or
  absent). Avoids accidental no-op authoring.
- `visual.rig_type` is not one of {biped, quadruped, hexapod, octopod,
  avian, serpentine, aquatic, others}.

Warns (does not fail) if:
- Any def has `visual.animate: true` but `visual.animation_state_
  rules` is missing AND `clip_alias` is missing (mesh would animate
  but engine would never drive state).
- Any def has `visual.animate: true` with `rig_type: "others"` —
  Tripo's "others" rig is a fallback and may fail prerigcheck;
  budget for a wasted $0.10 per entity in this bucket.

## Consequences

### Enables

- **Walking characters.** Player + named NPCs visibly stride instead
  of sliding. Soul-pass Layer 4 (kinetic juice) gets a foundation.
- **Per-character animation variants.** Stretch goal — author per-
  NPC personality via custom retarget clips (gruff barker has
  slower walk, energetic merchant has bouncy walk). Same pipeline.
- **Cost-aware authoring.** Budget is visible per-entity. A 12-NPC
  village costs ~$17 to fully animate at minimal tier; authors
  choose which characters need animation.

### Precludes / costs

- **No custom mocap.** Tripo provides preset clip IDs only. If
  authors want unique motions per NPC, that's a separate
  capability (potentially Meshy, Mixamo, or manual skeletal authoring
  in Blender).
- **Cost ramp.** Per entity: $1.40 minimum (biped idle + walk) or
  $1.10 minimum (non-biped, one walk clip since Tripo currently
  exposes one preset per non-biped rig type). Pipeline failure modes
  (prerigcheck reject, retarget reject) waste partial credits the
  first time but are cached after.
- **Cost grows linearly with animated-entity count.** At ~$1.40 per
  animated biped + $1.10 per animated non-biped, a 20-entity village
  costs roughly $25-30 to fully animate. Threshold for concern: past
  ~10 animated entities, consider a rig-reuse ADR (share one rig +
  skeleton across visually-similar NPCs — see Open Questions).
- **Non-biped clip diversity is limited.** Tripo's SDK currently
  exposes ONE preset per non-biped rig type (walk/march). Bipeds get
  11 presets. Animal animations are walk-only until Tripo adds more.
- **Pipeline dependency.** Adds `pygltflib` to `tools/yume_assetgen`
  Python requirements. New dep is small (~50 KB) and pure Python.

### What other ADRs / files this touches

- **ADR 0046** (Animation via Godot AnimationPlayer): no changes;
  this ADR consumes 0046's existing engine path.
- **ADR 0051** (Authoring-time Python emitters): expands the
  emitter's responsibilities.
- **`tools/yume_assetgen/backends/tripo3d.py`**: new methods
  `_submit_prerigcheck`, `_submit_rig`, `_submit_retarget`, plus a
  high-level `generate_animated_mesh` orchestrator.
- **`tools/yume_assetgen/ledger.py`**: three new dedup keys.
- **`tools/yume_assetgen/glb_merge.py`**: NEW (~80 LOC).
- **`tools/validators/validate_animate_scope.py`**: NEW.
- **`.claude/skills/yume-asset-designer/SKILL.md`** § A2: document
  `visual.animate` opt-in + cost guidance.
- **`.claude/skills/yume-content-designer/SKILL.md`**: suggest
  `animate: true` for player + named NPCs in character defs.
- **`tools/yume_assetgen/README.md`**: update with the animation
  flow diagram + cost table.

## Alternatives considered

### Alt A — Engine-side multi-GLB loading

Pipeline ships separate `_idle.glb` + `_walk.glb`; engine extends
`entity_mesh_3d` to load N GLBs and concatenate their
`AnimationLibrary`s at runtime.

- Pro: no `pygltflib` dependency.
- Pro: pipeline simpler — no merge step.
- Con: engine code grows for what's a content-prep concern.
- Con: visual.mesh schema changes (becomes mesh + animate_clips
  dict); not a clean drop-in to existing GLB-loading defs.
- Con: per-frame work to find clips across libraries (small but
  nonzero).

**Rejected** — per ADR 0021 "expose Godot, don't reimplement," the
asset prep belongs in the Python pipeline, not the engine. Engine
should see one GLB per entity, full stop.

### Alt B — Auto-derive rig_type from entity tags

Pipeline reads `entity.tags` and picks `rig_type` heuristically:
`character → biped`, `quadruped → quadruped`, `bird → avian`, etc.

- Pro: zero new schema field, fewer keystrokes per entity.
- Pro: matches existing tag taxonomy.
- Con: implicit. A typo (`quadraped`) silently falls through to
  `biped` and wastes prerigcheck.
- Con: tag taxonomy isn't standardized across all Yume games. New
  games might use different tags.
- Con: harder to audit per-entity rig choices via grep.

**Rejected** — explicit `visual.rig_type` is more verbose but
inspectable and typo-proof. Per the Yume convention "be explicit
about engine-relevant fields."

### Alt C — Build our own skeletal animation in Blender

Author rigs + animations manually in Blender, ship hand-crafted GLBs.

- Pro: full creative control.
- Pro: zero per-character API cost after the rig exists.
- Con: defeats the LLM-driven pipeline goal. Adds a manual step that
  scales poorly with character count.
- Con: aligning Blender output to Tripo3D's image-to-mesh output is
  non-trivial (different mesh topology, different naming).

**Rejected** — keeps the framework's "JSON authoring → AI-generated
output" promise.

### Alt D — Stay static, fake animation via vertex shader

Use a shader to wave limbs procedurally (think "Roblox running
animation"). No skeleton needed.

- Pro: zero cost.
- Pro: works for any mesh, biped or quadruped.
- Con: only convincing for ambient idle; walk cycle in a vertex
  shader looks weird because limb positions don't sync with
  translation.
- Con: doesn't compose with future state-driven animations (attack,
  death, interaction).

**Deferred** — could complement (idle sway on quadrupeds) but
shouldn't replace the rig pipeline for bipeds.

## Open questions

1. **Tripo's animation preset list — RESOLVED 2026-05-18.** The
   official SDK's `Animation(str, Enum)` enumerates 11 biped presets
   (`preset:idle`, `preset:walk`, `preset:run`, `preset:dive`,
   `preset:climb`, `preset:jump`, `preset:slash`, `preset:shoot`,
   `preset:hurt`, `preset:fall`, `preset:turn`) and one preset per
   non-biped rig type (`preset:quadruped:walk`,
   `preset:hexapod:walk`, `preset:octopod:walk`,
   `preset:serpentine:march`, `preset:aquatic:march`). Avian +
   "others" presets are not enumerated in the SDK; an API probe
   during implementation will discover them. Source:
   `VAST-AI-Research/tripo-python-sdk@main/tripo3d/models.py`.
2. **Per-frame animation cost in Godot.** Each animated entity has
   an `AnimationPlayer` ticking. For ~5 characters per scene this is
   negligible; for 50+ NPCs it'd warrant a culling primitive (only
   animate visible characters). Out of scope for this ADR.
3. **Rig reuse across characters.** Tripo's rig output is
   per-character (different skeleton each). Sharing one rig across
   visually-similar characters (e.g. all generic villagers use the
   same skeleton + different mesh skin) would dramatically cut cost.
   Worth a future ADR if animated-entity count grows past ~10.
4. **Animal idle states.** Non-biped Tripo rigs don't expose an
   `idle` preset — only `walk`/`march`. Yume's
   `animation_state_rules` fall back to walk on default branch, so
   animals walk continuously even when their `state.velocity` is
   zero. Acceptable as a v1 limitation; if Tripo adds idle presets
   for non-bipeds we update entity defs without ADR change.

## References

- ADR 0021 — Yume as JSON layer over Godot (capability-exposure rationale)
- ADR 0046 — Animation via Godot AnimationPlayer (engine path this ADR consumes; multi-clip GLB support verified at `godot/scripts/engine/tests/test_runner.gd:5069`)
- ADR 0051 — Authoring-time Python emitters (pipeline this ADR extends)
- ADR 0052 — Shader as visual primitive (same capability-exposure pattern)
- `VAST-AI-Research/tripo-python-sdk@main` — source for Tripo API task shapes, RigType enum, Animation enum, rig model versions
- `tools/yume_assetgen/backends/tripo3d.py` — backend to extend
- `godot/scripts/engine/directors/animation_director.gd` — engine consumer (no change)
- `godot/data/test_assets/cube_anim.glb` — existing multi-clip GLB precedent (Idle + Walking)
