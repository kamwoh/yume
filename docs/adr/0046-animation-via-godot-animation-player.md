# ADR 0046 — Animation via Godot's AnimationPlayer (+ .glb skinned mesh support)

_Date: 2026-05-17_
_Status: **accepted** (tech-director gate cleared 2026-05-17 after 4 revision items applied)_

## Context

ADR 0035 (2026-05-09) introduced the Animation primitive. It declared
JSON `animations` blocks per mesh def (named clips with keyframe
tracks per piece + property) plus `animation_state_rules` (declarative
state-machine: "play 'walk' when velocity_speed > 0.1, else 'idle'").
Both the keyframe interpolator AND the state-rule evaluator landed
together inside `animation_director.gd` (~300 lines of GDScript).

Code-drawn mesh animation works in production today. The villager,
deer, rabbit, and wolf meshes all animate via `animation_director`'s
interpolator. The state-rule layer correctly switches clips based on
entity state.

**The 2026-05-13 audit** (commit `856e64a`, task #76) flagged a
smell: `_interp_keys` + `_apply_track` + `_cache_baselines` in
animation_director **reimplement keyframe interpolation in GDScript**.
Godot ships AnimationPlayer + Animation resources that do exactly
the same thing — in optimized C++, with cubic/spline interp, with
AnimationTree cross-fading, with state-machine blend graphs — none
of which Yume's hand-rolled interpolator offers.

That's an ADR 0021 smell: "Yume = JSON layer over Godot. Expose,
don't reimplement." The interpolator is a reimplementation. The
state-rule evaluator is NOT — it's a Yume-specific gameplay bridge
(`velocity_speed > 0.1 → walk`) that doesn't have a Godot equivalent
(AnimationTree's state machines don't know about entity tags or
world state).

Separately, the framework currently has no clean way to load
artist-authored skinned meshes. ADR 0007's Tier-1 .glb support
exists for static meshes, but skinned characters with their own
embedded AnimationPlayer + Skeleton3D don't flow through the
code-drawn-primitives pipeline. Authors who want a Mixamo-rigged
villager or a low-poly artist mesh today have to either (a) bypass
Yume's mesh system entirely or (b) accept the cylinder villagers.

## Decision

Migrate animation interpolation to Godot's AnimationPlayer in two
phases. **JSON authoring surface unchanged** — same `animations` +
`animation_state_rules` blocks, same effect on the game. What changes
is who does the interpolation under the hood.

**Phase A** (this ADR's primary scope): replace
`_interp_keys`/`_apply_track`/`_cache_baselines` with a translation
layer that builds Godot `Animation` resources at mesh-def load and
plays them via `AnimationPlayer`. Keep `_pick_state` + the state
rules — that's the Yume-specific gameplay-aware bridge.

**Phase B** (smaller, builds on A): accept
`visual.mesh = "res://x.glb"` as an alternative to code-drawn
primitive assembly. The .glb scene brings its own MeshInstance3D +
Skeleton3D + AnimationPlayer + named clips; state_rules call
`.play()` against the imported player. Code-drawn primitives keep
working unchanged — opt-in per entity.

### Authoring contract for Phase B (.glb-backed meshes)

The .glb-loader path uses the SAME `animations` + `animation_state_rules`
schema as code-drawn meshes — the state-rule evaluator doesn't care
whether the AnimationPlayer is the one we built or the one the .glb
brought.

**Default convention: state name IS the clip name.** A state called
`"walk"` plays the imported clip named `"walk"`. Authors rename clips
in their DCC tool (Blender, Maya) to match Yume state names. This is
the cleanest path — zero schema overhead.

**Escape hatch: per-state `clip_alias` field**. When a .glb's clip
naming can't be changed (third-party Mixamo download, baked rig from
an artist who's already shipped), add `clip_alias` to map Yume's
state name to the actual clip name in the .glb:

```jsonc
"animations": {
  "idle": {"clip_alias": "Armature.001|MyIdleTake"},
  "walk": {"clip_alias": "Armature.001|MyWalkTake"}
},
"animation_state_rules": [
  {"when": {"velocity_speed_gt": 0.1}, "play": "walk"},
  {"default": "idle"}
]
```

No leading-underscore prefix (per tech-director review 2026-05-17 —
underscore reads "internal/private" which is wrong for an authoring
field). The field is optional; absence means use the state name
verbatim as the clip name.

### Phase A — JSON → AnimationPlayer translation

The authoring contract:

```jsonc
"animations": {
  "idle": {
    "loop": true,
    "duration": 1.5,
    "tracks": [
      {
        "piece": "left_arm",
        "property": "rotation_x",
        "keyframes": [[0.0, 0.0], [0.75, 0.05], [1.5, 0.0]]
      }
    ]
  },
  "walk": { ... }
},
"animation_state_rules": [
  {"when": {"velocity_speed_gt": 0.1}, "play": "walk"},
  {"default": "idle"}
]
```

is **unchanged**. What changes is internal:

**Today** (animation_director.gd):
1. At mesh build, cache references to each piece (named MeshInstance3D
   child).
2. Each render frame, `_pick_state` evaluates the state rules against
   the entity's current state → picks one clip.
3. Each render frame, `_interp_keys` linear-interpolates the active
   clip's tracks at the current clock and writes transforms directly
   to the piece nodes.

**Phase A** (this ADR):
1. At mesh build, **translate** the JSON `animations` block into a
   Godot `AnimationLibrary` containing one `Animation` resource per
   clip. Track paths are `"<piece_name>:<property>"`. Loop mode +
   keyframe interpolation come from JSON.
2. Mount an `AnimationPlayer` node on the entity's visual root.
   Register the AnimationLibrary.
3. Each render frame, `_pick_state` still evaluates state rules.
   When the resolved state differs from the currently-playing clip,
   call `animation_player.play(state_name, blend_seconds)`. Cross-
   fade comes free.
4. Godot's AnimationPlayer drives the actual per-frame interpolation
   and transform writes in C++.

**Net effect**: ~200 lines of GDScript interpolator deleted; cubic/
spline interp + transition cross-fade unlocked; the gameplay-aware
state-rule layer stays put.

### Phase B — .glb skinned meshes alongside code-drawn

Add a path in the mesh-builder dispatch:

```gdscript
if str(visual.get("mesh", "")).ends_with(".glb"):
    # Imported mesh path: instantiate the scene as-is. The .glb
    # comes pre-wired with Skeleton3D + AnimationPlayer + named clips.
    var imported := load(visual.mesh).instantiate()
    parent.add_child(imported)
    # state_rules still drive WHICH clip plays — they call .play()
    # on the imported AnimationPlayer instead of a Yume-built one.
    return _animator_from_imported_glb(imported, def)
else:
    # Existing code-drawn primitive assembly path.
    return _animator_from_mesh_def(def)  # uses Phase A's translation
```

Authoring (state-name = clip-name, the default convention):

```jsonc
"visual": {
  "mesh": "res://assets/villager_skinned.glb",
  "material_overrides": {            // OPTIONAL — see Phase B.3 below
    "shirt_slot": "#7a5e32",
    "skin_slot":  "#d4a57a"
  }
},
"animations": {                        // Same shape as code-drawn.
  "idle": {},                          // Empty body — state "idle"
  "walk": {}                           // plays imported clip named
},                                     // "walk".
"animation_state_rules": [             // Unchanged — same evaluator.
  {"when": {"velocity_speed_gt": 0.1}, "play": "walk"},
  {"default": "idle"}
]
```

For details on `clip_alias` (escape hatch for when DCC rename isn't
possible), see the "Authoring contract for Phase B" section above.

The state_rules don't care whether the AnimationPlayer is the one we
built (code-drawn) or the one the .glb brought (imported). One state
machine, two animator sources.

**Material overrides** (optional): walk the imported scene's
MeshInstance3D nodes, duplicate-and-override matching material slots
with author-specified colors. Without overrides, the .glb's baked
materials apply unchanged. This is how a single "villager_skinned.glb"
can serve multiple in-game villagers in distinct shirt colors.

## Consequences

### What this enables

1. **C++-speed interpolation** for every animated mesh (free from
   Godot).
2. **Cross-fade transitions** via `play(name, blend_seconds)` — solves
   the snap-pop when state rules switch clips (walk → idle today
   instantly snaps; with Phase A, fades over 0.2s).
3. **Cubic / spline interpolation** opt-in per track via JSON (for
   smoother motion than linear-only).
4. **Artist-authored skinned meshes** (Phase B) — Mixamo, Blender
   rigs, and any standard .glb work without engine plumbing per game.
5. **AnimationTree migration path** later if multi-clip blending is
   ever needed (cross-fading is the cheap entry; full blend trees
   are an additional opt-in on top).

### What this precludes / narrows

1. **Bigger move-and-mutate fidelity than AnimationPlayer supports**
   is now wrong place to author (would have to use AnimationPlayer's
   own method-track or signal-track features, not the Yume primitive).
   No current Yume content does this.
2. **Per-track state-conditional gating** (e.g. "freeze the left arm
   if holding a heavy item") is not native to AnimationPlayer.
   Currently the state-rule layer would have to pick a different clip
   that bakes that variant. Not worse than today's interpolator —
   same workaround.
3. **The runtime cost of constructing many Animation resources at
   mesh-def load time.** For aldenmere's ~20 mesh defs × 3-5 clips
   each = ~80 resources at boot. Each is small (a dict of tracks +
   keyframe arrays). Profile during Session A; expected negligible.

### What does NOT change

- JSON authoring surface (animations + animation_state_rules schemas).
- Existing demos' content — no migration of game-side JSON.
- Yume's state-rule evaluator (`_pick_state` and the rules format).
- All other ADRs hold.

### Skill impact

- **yume-asset-designer** SKILL.md needs a "code-drawn vs .glb"
  decision section after Phase B. Today the skill assumes code-drawn
  only.
- **yume-content-designer** keeps writing the same JSON. No change.
- Visual designer + tech director gate criteria unchanged (the visual
  capture comparison still applies; the multi-frame anim gate per
  `.claude/rules/visual-qa.md` § "After animation change" still
  applies).

## Alternatives considered

### A. Status quo — keep the GDScript interpolator

**Pros**: zero migration cost. Works today.

**Cons**: violates ADR 0021's "expose, don't reimplement." Caps
animation fidelity at linear interp. No path to artist-authored
skinned meshes (a separate engine change required). The audit
docstring in animation_director.gd flags the smell — leaving it
unaddressed means the next person reads "yes we know" without action.

### B. Translate to AnimationPlayer (chosen)

See Decision section.

### C. Throw away the JSON authoring surface; require .glb for all
   animated meshes

**Pros**: simplest engine; no translation layer; one path.

**Cons**: breaks every existing Yume game. Forces every animation
into a DCC workflow (Blender → .glb), losing the LLM-authorable
JSON-keyframes story that's central to Yume's pitch. Bad for
non-artist authors. Bad for LLM-driven content generation.

### D. Add AnimationTree blend-tree authoring on top

Considered for Phase A but rejected as scope creep. The cross-fade
that comes free from `play(name, blend_seconds)` covers 90% of the
transitions Yume games need. AnimationTree's full blend trees +
state machines are a possible follow-up ADR if a future game's GDD
demands multi-clip blending (e.g. simultaneous walk + carry +
crouch). Today no Yume content needs that.

## Implementation phasing

### Phase A.1 — Translation layer + unit tests (1 session)

- Build `scripts/engine/directors/animation_translator.gd`:
  `static func build_library(animations_block: Dictionary)
  -> AnimationLibrary`. Each clip in the JSON → one `Animation`
  resource with tracks added via `add_track()` / `track_insert_key()`.
- Loop mode: read from JSON (`loop: true/false`).
- Track interpolation type: read from JSON (`interp: "linear"` or
  `"cubic"`), default linear.
- Unit tests in `test_runner.gd::test_animation_translator()` —
  round-trip a known JSON keyframe set, sample the Animation at
  specific times, assert correct interpolated values.

### Phase A.2 — Rewire + delete interpolator (1 session, MERGED A.2+A.3 per tech-director 2026-05-17)

**This is the cutover commit.** Per tech-director review: A.2 (rewire)
and A.3 (delete dead code) are merged into a single session. After
A.2 rewires `_pick_state` to call `animation_player.play()`, the old
`_interp_keys`/`_apply_track`/`_cache_baselines` paths are dead — no
callers. Bundling A.2+A.3 in one commit keeps the dead-code window
narrow and prevents accidental regression.

- In `entity_mesh_3d.gd` (or wherever code-drawn meshes are built),
  add an `AnimationPlayer` node to the visual root. **Per Invariant
  #11 (level-discontinuity cleanup, 2026-05-08)**: the AnimationPlayer
  is OWNED by the entity's visual root, so it dies with the entity
  on `transition_level`. No new smoothed-state surface that survives
  the discontinuity. Document this in the AnimationPlayer mount
  comment so future readers know the cleanup is automatic.
- Register the translated library on the AnimationPlayer.
- Refactor `animation_director._pick_state`: when the resolved state
  changes, call `animation_player.play(new_state, blend_seconds)`.
  Default blend 0.15s (configurable per-state via JSON).
- `_pick_state` evaluation cadence is unchanged. Per audit
  (`renderer_3d/entity_mesh_3d.gd:131-132`), this runs in `_process`
  — render frames, not sim ticks. AnimationPlayer's clock matches.
- **DELETE** `_interp_keys`, `_apply_track`, `_cache_baselines` from
  `animation_director.gd`. Director shrinks to ~80 lines: state-rule
  evaluation + AnimationPlayer dispatch.
- Update animation_director's docstring to remove the audit-pending
  note; cite this ADR.

**Merge-gate conditions** (tech-director will re-review):

1. **Multi-frame visual QA** (per `.claude/rules/visual-qa.md` §
   "After animation change") MANDATORY: two captures separated 0.3s
   of aldenmere villager walking; limb positions must differ between
   frames (proves animation fires). Compare against pre-A.2 capture
   for visual equivalence — both should LOOK identical EXCEPT for
   transitions becoming smoother (the cross-fade IS the intended
   visible difference).
2. **Unit tests** from A.1 (translator coverage) must include at
   least: one linear-interp track + one looping clip + one one-shot
   clip.
3. **Aldenmere scenario tests** (19/19) must pass post-merge.

If any of those three fail, merge is BLOCKED.

### Phase A.3 — Polish (cross-fade tuning, cubic interp, docs) — **shipped 2026-05-17**

- ✅ Per-state `blend_seconds` in JSON (default 0.15). Implemented in
  `animation_director.gd::tick` — reads `animations.<state>.blend_seconds`
  before falling back to `mesh_def.animation_blend_seconds` default.
- ✅ Per-clip `interp: "cubic"` for smoother motion. Implemented in
  `animation_translator.gd::_build_animation` + `_bake_track`. Authors
  set `animations.<state>.interp: "cubic"` (or `"nearest"` for stepped
  frames). Default is `"linear"`. Unit-tested in
  `test_animation_translator` (2 new assertions, 902 total tests).
- ✅ Cross-reference from ADR 0035 to ADR 0046 (front-matter follow-up
  note: status flipped to `accepted` + ADR 0046 link).
- Deferred: `engine-reference/api-manifest.json` — no engine signatures
  changed (effect types unchanged; this is a rendering-layer rewrite).
  Skipping manifest regen.
- Deferred: `docs/guideline/30_framework_primitives.md` Animation section — the
  primitives doc doesn't currently carry an animation section
  (animation lives entirely in ADRs 0035/0046). No edit needed; if a
  primitives-doc Animation section lands later, it should link to ADR
  0046 § Phase A as the canonical implementation reference.

### Phase B.1 — .glb loader detection — **shipped 2026-05-17**

- ✅ `entity_mesh_3d._load_glb_mesh`: dispatch path detects `.glb` /
  `.gltf` suffix on `visual.mesh`, loads via `ResourceLoader`, adds
  the instantiated scene as a child. Falls back to a bare colored
  box (with push_warning) if the load fails.
- ✅ `_find_imported_animation_player`: shallow tree-walk locates
  the embedded AnimationPlayer (Godot's GLTF importer always names
  it "AnimationPlayer" and parents it to the scene root).

### Phase B.2 — state_rules → imported AnimationPlayer — **shipped 2026-05-17**

- ✅ `AnimationDirector.set_clip_aliases(map)`: registers a
  `{state_name: clip_name}` mapping. `tick()` resolves the active
  state name via this map (falls back to state name verbatim if no
  alias), then calls `_animation_player.play(clip_name, blend)`.
- ✅ `entity_mesh_3d._build_clip_alias_map(rules)`: walks the
  `animation_state_rules` array, extracts each rule's
  `clip_alias` field (if present), and returns the lookup map.
- ✅ Tech-director note honored: authoring uses plain field name
  `clip_alias` (no leading underscore).
- ✅ Unit-tested in `test_animation_primitive` Assertion 8:
  director with aliases plays `Walking` when state="walk" and
  `Idle` when state transitions to "idle".

### Phase B.3 — material overrides + inspect-glb tooling — **shipped 2026-05-17**

- ✅ `entity_mesh_3d._apply_material_overrides`: walks every
  MeshInstance3D under the imported scene; for each surface whose
  material's `resource_name` matches a key in `material_overrides`,
  DUPLICATES the material (so the override is per-entity, not
  shared) and patches its albedo_color. Falls back to `surface_<i>`
  numeric keys when `resource_name` is empty. Untouched surfaces
  keep their baked .glb material.
- ✅ `tools/inspect_glb.py` (pure stdlib, no `pygltflib` dep —
  parses GLB JSON chunk directly). Prints nodes, meshes, surface →
  material mapping, material albedos, and animation clip names +
  durations. Authors copy names verbatim into `material_overrides`
  and `animation_state_rules.clip_alias`.
- ✅ yume-asset-designer SKILL.md gains Strategy A2 documenting
  the .glb authoring path + inspect-glb workflow + pre-ship gate.

### Phase B.4 — bundle 1 test .glb + asset-designer skill update — **shipped 2026-05-17**

- ✅ `tools/synth_test_glb.py` emits `data/test_assets/cube_anim.glb`
  (a 24-vertex cube with 2 materials and 2 animation clips). Pure
  stdlib generator — reproducible from source via
  `python3 tools/synth_test_glb.py`. The .glb is checked in.
- ✅ `test_animation_primitive` Assertion 9 loads + inspects the
  generated .glb via Godot (verifies AnimationPlayer exists + Idle/
  Walking clips present). 907/0 unit tests after Phase B.

### Phase B.4 (historical spec — kept for context) — bundle 1 test .glb

- Author or download a tiny test .glb (a cube with "Idle" + "Walking"
  clips). Bundle in `godot/data/test_assets/` or use a Godot built-in.
- Unit test instantiates the .glb via the same code path used by
  per-game entity defs, asserts AnimationPlayer present + clips
  named correctly.
- yume-asset-designer SKILL gains a "When to use code-drawn vs .glb"
  decision section. Default: code-drawn (LLM-authorable). .glb when
  an artist mesh is the right fit OR skinning matters OR an existing
  rig (Mixamo etc.) is being reused.

## Test plan

For Phase A:

1. All current Yume tests pass (873+ unit + 19+ scenario).
2. Multi-frame visual capture of aldenmere villager walking:
   t=2.0s and t=2.3s captures. Limb positions visibly differ between
   frames (proves animation fires). Compare against pre-migration
   capture from the same scenario — overall LOOK should be identical.
3. State-rule transitions: capture villager idle → walking. Cross-
   fade between clips should be smooth (not a snap). Without
   blend, snap is still observable on a single-frame capture.
4. New unit test `test_animation_translator`: feed JSON, assert the
   built `Animation` resource has correct tracks + sampled values
   at specific times.

For Phase B:

5. Unit test: instantiate the test .glb via the
   `visual.mesh = "res://.../test.glb"` path, assert AnimationPlayer
   is present + has expected clip names.
6. Visual capture: place a .glb-backed entity in a scene next to
   a code-drawn villager. Both should render. State-rule walk
   trigger should fire .glb-clip on imported AnimationPlayer and
   the translated walk clip on code-drawn villager IDENTICALLY at
   the JSON layer.
7. Material override test: same .glb spawned twice with different
   color overrides should render in two different colors.

## Out of scope (explicit)

- **AnimationTree blend trees / state machines**: separate ADR if
  ever needed.
- **Mixamo retargeting** between rigs: not addressed; .glb authors
  bring their own rigs.
- **Ragdoll** physics on imported skeletons: would be a separate
  PhysicsServer3D + Skeleton3D bridge ADR.
- **Rigging code-drawn primitives**: pursuing skinned cylinders is
  the wrong direction.
- **Sound-on-keyframe / step-event tracks**: out of Phase A. If
  needed later, AnimationPlayer supports method-call tracks; we'd
  just add JSON syntax.

## Visual gate (per `.claude/rules/visual-qa.md`)

Phase A.3 + B.2 + B.3 each touch rendering. Required:

- Two-frame motion comparison per multi-frame anim gate (see rules
  visual-qa.md § "After animation change").
- `yume-visual-designer` invocation for the .glb path on Phase B.2.
- Tech-director merge review on Phase A.3 (interp deletion is a
  big change; verify all current demos still animate correctly).

## Status

**Accepted** 2026-05-17 after tech-director gate review applied 4
revisions:

1. ✅ Invariant #11 note added to Phase A.2 (AnimationPlayer ownership
   / level-transition cleanup is automatic via entity scene tree).
2. ✅ A.2 + A.3 merged into single cutover session; clarified A.2 is
   the cutover moment. Sessions reduced from 8 to 7.
3. ✅ Phase B schema revised: dropped leading-underscore `_glb_clip`;
   default convention is state-name-as-clip-name; escape-hatch field
   renamed to `clip_alias` (no underscore).
4. ✅ Phase B.3 expanded to include `tools/inspect_glb.py` (or
   documented Godot Inspector recipe) for slot-name discovery —
   merge gate.

Phase A.1 (translator + unit tests) is approved to start. Each
subsequent session has its own merge gate documented above.
Tech-director will re-review at the A.2 cutover boundary.

---

## Tech-director review

_Date: 2026-05-17_
_Reviewer: yume-tech-director_

### Verdict: `accept-with-conditions`

Sound direction. Phase A is straight-line ADR 0021 alignment — deleting
reimplementation in favor of Godot's primitives. Phase B is a clean
primitive expansion (new mesh-source type), not a genre shortcut. The
phasing decomposes cleanly with one nuance noted below (the real
cutover is A.2, not A.3 — the ADR's risk framing should clarify this).

### Invariant audit

**Invariant #1 (JSON-only content channel) — ✅ HOLDS.**

The JSON `animations` + `animation_state_rules` schemas are unchanged.
The translator runs at mesh-def load (build time) and produces Godot
`Animation` resources from JSON keyframes. The engine still reads JSON
authoritatively. Phase B's `.glb` path treats the imported scene as
opaque CONTENT (same way ADR 0007 already treats `.glb` for static
meshes); engine code wires the imported AnimationPlayer to the
existing JSON state_rules evaluator. No game-specific behavior leaks
into engine. Confirmed.

**Invariant #5 (queries first-class) — ✅ HOLDS.**

Animation never queried entities; it reads bound entity state through
`_pick_state`. That stays. Nothing in the ADR introduces a new
entity-query bypass.

**Invariant #8 (engine = primitives + interpreter) — ✅ HOLDS, with
positive direction.**

Phase A REMOVES ~200 lines of `_interp_keys` + `_apply_track` +
`_cache_baselines` that reimplemented what `AnimationPlayer` does in
C++. This is the prototypical ADR 0021 alignment — exposing Godot's
primitive instead of hand-rolling.

Phase B adds a new mesh-source path (`.glb`). This is acceptable as a
primitive expansion because:
1. The .glb is opaque content; the engine doesn't interpret skeletons
   or armatures.
2. The state-rule evaluator is reused unchanged — same JSON authoring,
   different `AnimationPlayer` source.
3. No game-specific code is added. The `_animator_from_imported_glb`
   path is generic — any future game using .glb meshes gets it free.

ADR 0007 already established the mesh-as-content principle for static
imports; Phase B extends it to animated imports. Same architectural
pattern.

**Invariant #9 (phase boundaries flush) — ✅ HOLDS, not applicable.**

Animation runs in `_process` (render frames) via
`entity_mesh_3d.gd:131-132`, not in the phase scheduler's tick. No
phase ordering change. No flush placement change. The sim/render
boundary is clean today and stays clean post-Phase-A.

**Invariant #10 (freeze-policy) — ✅ HOLDS, concern in args #5 is
overstated.**

Audited the existing call site at
`renderer_3d/entity_mesh_3d.gd:126-132`. The renderer's `_process`
does NOT gate on `screen_freeze_world`. Today's GDScript interpolator
already keeps playing during freeze (the entity's `state.velocity` is
stale, so `_pick_state` returns the same clip; `_interp_keys` clock
keeps advancing via `Time.get_ticks_msec()`).

After Phase A, AnimationPlayer's clock advances identically. Same
behavior. No regression.

If a future game wants freeze to pause animations, that's a separate
JSON-level field (e.g. `pause_on_freeze: true` per mesh def) that
both implementations would need to honor symmetrically. Not part of
this ADR's scope.

**Invariant #11 (level-discontinuity cleanup) — ⚠️ NEEDS NOTE.**

Phase A.2 mounts an AnimationPlayer per entity. On `transition_level`,
entities are destroyed and respawned — their AnimationPlayer nodes
ride along with the entity scene tree, so cleanup is automatic. No
"smoothed state survives the discontinuity" risk.

But: per Invariant #11's generative checklist, the ADR should add
"AnimationPlayer.current_animation" to its enumeration of
"engine state coupled to entity identity" — if a future feature
adds per-game freeze on transition (e.g., "boss music keeps playing
during cutscene-transition"), the developer needs to think about
whether to snap or carry that AnimationPlayer state forward.

**Action**: add a one-line note in Phase A.2 docstring confirming
the AnimationPlayer is owned by the entity's visual root (so it
dies with the entity on level transition).

**Invariant #12 (persistent-entity clobber guard) — ✅ HOLDS, not
applicable.**

Persistent entities survive level transitions via the existing
spawn-skip guard. Their AnimationPlayer rides along — same as any
other child node of the persistent entity. No new clobber surface.

### Phasing-risk audit

The ADR labels A.3 (delete old interpolator) as the high-risk session.
**That's wrong** — the actual high-risk session is A.2.

Reading the ADR closely: Phase A.2 says "rewire `_pick_state` to call
`animation_player.play()` instead of `_apply_track`." That cutover IS
the moment animations stop using the old interpolator. After A.2,
`_interp_keys`/`_apply_track`/`_cache_baselines` are dead code — no
caller. A.3 just deletes dead code.

So A.2 is where the cutover lands. If A.2's translation has a
keyframe-mapping bug, animations break IMMEDIATELY in A.2's commit,
not in A.3.

**Conditions** for A.2 to be safe:

1. **Two-frame anim VQA (per `.claude/rules/visual-qa.md` § "After
   animation change") is MANDATORY on A.2's commit.** Capture t=2.0s
   AND t=2.3s of aldenmere villager walking; limb positions must
   differ; compare against pre-A.2 capture for visual equivalence.
2. **Unit tests for the translator (from A.1) cover at least one
   linear-interp track + one looping clip + one one-shot clip.**
   Without translator tests, A.2 is flying blind.
3. **Aldenmere scenario tests pass** post-A.2 (they don't test anim
   directly, but they exercise the full pipeline — any AnimationPlayer
   mount failure would crash the scenario boot).

If A.2 ships without those three, it's a hard reject.

A.3 is then a tiny, safe deletion commit once A.2's visual gate
passes. Bundling A.2+A.3 into a single commit (after A.1 has landed
separately with translator + tests) is actually CLEANER than the
ADR's current 3-session split — it keeps the dead-code window
narrow. **Suggestion**: merge A.2 + A.3 into one session: "rewire
and delete." Reduces git history churn and the risk of someone
calling the dead code in the gap window.

### Phase B audit

Schema review:

- `_glb_clip` field name: the leading underscore reads as "private/
  internal" which is inappropriate for an authoring field. Rename to
  `clip_name` (or `imported_clip`, or just reuse the dict key as the
  clip name if the .glb's clip names already match the state names —
  simplest possible authoring is "no `_glb_clip` field; if mesh is
  .glb, the dict KEY IS the clip name").

**Action**: revise Phase B schema. Recommend: when `visual.mesh` ends
with `.glb`, the state name in `animation_state_rules` IS the clip
name (no separate `_glb_clip` field needed). Author renames clips in
Blender to match Yume state names. If a clip is named differently in
the .glb and rename in DCC isn't possible, then a `clip_alias` field
on the state mapping it to the .glb's clip name.

- `material_overrides`: schema is clean, but the per-mesh slot-name
  convention is NOT documented. Different .glbs name slots
  differently (some have "Material.001", others have semantic names).
  ADR must include an `--inspect-glb` tool or similar so authors can
  discover slot names without opening Blender.

**Action**: Phase B.3 must include either (a) a tools/inspect_glb.py
script that prints slot names, OR (b) a documented Godot Inspector
recipe in yume-asset-designer SKILL for finding them. Without one
of those, authors will guess at slot names and silently get fallbacks.

### Phasing recommendation (revised)

Land in this order:

1. **A.1** — translator + unit tests (1 session). Isolated; no engine
   integration. Safe.
2. **A.2+A.3 merged** — mount AnimationPlayer, rewire `_pick_state`,
   delete dead interpolator (1 session). Single commit; reduces
   dead-code window. Requires multi-frame VQA + scenario tests as
   merge gate.
3. **A.4** — polish (cross-fade tuning, cubic interp, docs) (1 session).
4. **B.1** — .glb loader detection (1 session). Safe if no .glb is
   actually used yet.
5. **B.2** — state_rules bridge to imported AnimationPlayer (1 session).
   Schema-revised per above. Requires schema change before this lands.
6. **B.3** — material overrides + inspect-glb tool (1 session). Tool
   is the merge gate.
7. **B.4** — bundle test .glb + asset-designer skill update +
   "code-drawn vs .glb" decision section (1 session). yume-visual-
   designer invocation per visual-qa rule.

That's 7 sessions instead of the ADR's 8 (A.2+A.3 merged).

### Conditions for accept

Before Phase A.1 can start:

- [ ] Add the Invariant #11 note in Phase A.2 docstring about
      AnimationPlayer ownership / level-transition cleanup.
- [ ] Revise the ADR's phasing section to merge A.2+A.3 (and clarify
      A.2 is the cutover moment, not A.3).
- [ ] Revise Phase B's `_glb_clip` schema: drop the underscore,
      consider whether the field is needed at all (state-name-as-
      clip-name is cleaner if authors can rename in DCC).
- [ ] Phase B.3 must include the inspect-glb tooling or equivalent
      documented recipe.

After those revisions, Phase A.1 is approved to start. Each subsequent
session has its own merge gate (multi-frame VQA, scenario tests,
yume-visual-designer invocation on B.2). Tech-director will re-review
at the A.2+A.3 merge boundary (the highest-risk landing).

### Out-of-scope review

- AnimationTree blend trees: correct to defer. Cross-fade via
  `play(name, blend_seconds)` covers 90% of transitions Yume games
  need today.
- Mixamo retargeting / ragdolls / sound-on-keyframe: appropriate
  out-of-scope. Each is a separate primitive expansion that should
  earn its own ADR when a game's GDD demands it.

### Visual gate

Phases A.2/A.3, B.2, B.3 all touch rendering. The gate applies. The
ADR correctly cites it.

For Phase A.2+A.3: tech-director re-review required at merge time.
The multi-frame VQA capture pair + scenario tests must be attached to
the merge PR. Per `.claude/rules/visual-qa.md` § "HUD/UI design gate"
(extended 2026-05-16), the visual review must answer "compare against
pre-migration capture" — confirm both renders look visually identical
EXCEPT for transitions becoming smoother (the cross-fade is the
intended visible difference).

### Final note

This ADR is well-scoped and well-phased. The four conditions above
are tightening, not blockers. With them applied, Phase A.1 starts
clean and each subsequent session has clear merge criteria.

ADR status: `accept-with-conditions`. Apply the four revision items
above, then proceed to Phase A.1.
