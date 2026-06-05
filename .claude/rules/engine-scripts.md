---
description: Path-scoped rules for Yume engine code
globs: godot/scripts/engine/**
---

# Engine scripts — invariants

The engine is **primitives + interpreter**. Adding a vocabulary item
(effect type, draw op, query operator) requires engine code; adding
a **composition** (rule, shape, binding) requires only JSON.

Contract: `docs/guideline/30_framework_primitives.md` invariants #1–#8.

## DON'T

- ❌ **Add semantic effect types** (`damage`, `need_decay`, `heal`,
  `gain_xp`, `attack`, `advance_stage`). Express as `state_add` /
  `state_set` with field names in JSON.
- ❌ **Add entity subclasses** (`Agent`/`Item`/`Projectile`/`Building`
  as `extends Entity`). Distinctions emerge from tags + properties
  + relations.
- ❌ **Hardcode entity ids** in engine code (`entities.get("player_1")`,
  `if ent.def_id == "wheat"`). Engine sees IDs as opaque strings.
- ❌ **Hardcode field names** beyond the reserved set (`position`,
  `velocity`, `age`). Everything else is content vocabulary.
- ❌ **Genre-specific functions** (`damage_apply`, `level_up`,
  `harvest_crop`). Engine is generic; semantics live in JSON rules.
- ❌ **Renderer code in engine modules**. Engine doesn't import
  Sprite2D / MeshInstance3D / anything visual; renderer modules
  read engine state.

## DO

- ✅ **Treat new vocabulary as a primitive expansion** — it joins
  the verb set for ALL games. Document in
  `docs/guideline/30_framework_primitives.md`.
- ✅ **Pass `env: Dictionary`** for cross-module state — entities,
  relations, spatial_index. No singletons / direct script refs.
- ✅ **Variant return types** for context resolvers (`_value`,
  `_position`, `_resolve_id`) — return whatever shape JSON gives.
- ✅ **Strict missing-field semantics** in queries (missing = no
  match; no permissive fallback).
- ✅ **Ship tests with the phase** — every primitive addition lands
  with unit tests in `tests/test_runner.gd`.

## Test invariants

No-genre-leak invariant (W5.7). Before merging:

```bash
grep -rE 'type[":]?\s*[":]?(damage|need_decay|need_restore|gain_xp|heal|attack|advance_stage)' \
  godot/scripts/engine/
```

Zero matches required.

## Camera-stability anti-patterns

When writing Camera2D / Camera3D follow code, **never combine
position-lerp + per-frame `look_at`**. Orientation re-aims using
the LERPING mid-flight position → camera visibly rotates as target
translates. User feels "camera trying to rotate when I walk."

Correct: compute a FIXED orientation against the FINAL desired
position; only the camera POSITION lerps.

```gdscript
var desired := target + offset
_camera3d.global_position = _camera3d.global_position.lerp(desired, t)
# Basis oriented against desired (final), not lerping current.
# Camera3D forward is -Z → use_model_front MUST be false (default).
_camera3d.global_transform.basis = Basis.looking_at(
    target - desired, Vector3.UP, false
)
```

**`Basis.looking_at` `use_model_front` trap**: third arg `false` aims
-Z at target (Camera3D convention); `true` aims +Z at target (for
*meshes* with +Z front-face, NOT cameras). Setting `true` on a
Camera3D makes the camera face exactly the wrong way → empty
world capture. Empirical 2026-05-08: merchant iso-3d initial fix
shipped `true`, pendrel + brookhaven rendered as empty sky/ground.
Caught by user playtest — visual gate couldn't distinguish from
prior "empty world during transition" symptom.

## HUD panel anchor preset — CENTER presets, not WIDE

`game_shell.gd::_build_panel` maps panel `anchor` strings to Godot
Control presets. For `top-center` / `bottom-center` / `center`:

- ✅ `PRESET_CENTER_TOP` / `PRESET_CENTER_BOTTOM` / `PRESET_CENTER`
  — anchor x=0.5 single point. Authored offsets (`offset_left =
  -w*0.5`) yield a w-wide vbox centered on screen.
- ❌ `PRESET_TOP_WIDE` / `PRESET_BOTTOM_WIDE` — anchor_left=0,
  anchor_right=1. Vbox stretches viewport-wide regardless of
  offsets → vbox spans `[-w*0.5, viewport_w + w*0.5]`. Default
  HORIZONTAL_ALIGNMENT_LEFT renders text at the *left* edge of
  that off-screen box, invisibly.

**Second-layer rule**: labels inside centered panels need
`horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER` AND
`size_flags_horizontal = SIZE_EXPAND_FILL`. `_build_element`
detects centered anchors and sets both; authors override per-label
with `align: "center" | "left" | "right"`.

**Empirical 2026-05-10**: aldenmere's crosshair-target HUD label
(`anchor: top-center, y_offset: 60`) reported `node_pos=(-380,
62)` — never appeared on screen. No prior demo had authored a
*short* centered label; long bottom-center hints masked the bug
by stretching past visible area.

**Check before approving `_build_panel` / `_build_element` changes**:
short label (≤20 chars) under each centered anchor; capture +
verify text appears centered horizontally. Diagnostic print:

```gdscript
push_warning("[LBL-DBG] panel=%s vbox_pos=%s vbox_size=%s label_pos=%s text='%s'" %
    [anchor, vbox.global_position, vbox.size, lbl.global_position, lbl.text])
```

For 1280×720 w=760: expect `vbox_pos.x ≈ 100`, `vbox_size.x ≈ 760`.

## Visual validation gate (rendering primitives)

When modifying any of these files, capture + invoke
`yume-visual-designer` BEFORE committing:

- `control_factory.gd`, `screen_flow.gd`
- `entity_sprite_2d.gd`, `renderer_2d/*`, `renderer_3d/*`
- `game_shell.gd` HUD construction / camera / viewmodel sections
- Any new module instantiating Godot Control / CanvasItem / Mesh
  from JSON

Phase A is not done until visual-designer accepts.

**Empirical**: ADR 0011 Phase A (commit `6f6a8d4`) shipped with a
miscentered Sokoban title screen because the implementer self-
deferred to "Phase B" and committed Phase A anyway. User caught
on next message.

If there's no render to capture (pure refactor), skip this gate;
if there IS, it's mandatory. Tech-director enforces on merge
(`.claude/skills/yume-tech-director/SKILL.md` §visual gate).

## Effect-chain validation gate (interaction primitives)

Visual gate catches static rendering; effect-chain catches broken
chains (button click → nothing). When adding/modifying effects
that touch screen / scene / save lifecycle:

- `transition_screen`, `transition_level`, `reload_scene`,
  `scene_change`
- `save_state`, `load_state`
- `quit_app`
- Anything that reloads, destroys, or replaces the active scene

`screen_fade` is non-destructive (tweens an overlay alpha) — safe
anywhere in a chain. `transition_level` with `fade_duration > 0`
is STILL destructive at the swap midpoint: any effect queued
after, referencing the OLD level's entities, is silently dropped.

**Rule**: trace every `on_click` / `on_press` / `on_submit` /
`on_change` chain end-to-end. Destructive effects must be **LAST**.
Anything queued after is silently dropped at end-of-frame.

**Empirical**: ADR 0010 reference content wired sokoban "New Game"
as `[reload_scene, transition_screen]` — the screen transition
dropped silently. Visual gate passed (nothing visually wrong);
user clicked, nothing happened.

### Check for each new screens.json / hud.json / rule firing transitions

1. List every effect chain (on_click, on_press, on_submit,
   on_change).
2. Identify destructive effects per the list above.
3. Confirm destructive effects are LAST.
4. If sequencing needed: combine into a single effect (preferred)
   OR queue follow-up via a one-shot rule firing after destruction.

### Modal-pop reveals world (2026-05-08)

Any chain that pops a modal (`transition_screen @previous` /
`@root`) reveals the world underneath until the next thing covers
it.

- **Pop → `transition_level`**: world visible ~2 frames before
  fade-out. Empirical: merchant Travel-to-Brookhaven (user: "first
  load level_town_pendrel map then only load the hud").
- **Pop → wait-for-signal-rule → next modal**: world visible ~1
  tick (~0.1s). Empirical: merchant funeral_splash → emits
  funeral_dismissed → @previous pops, brookhaven visible 1 tick
  before debt_papers_trigger fires.

**Mitigation**: prepend `screen_fade {alpha: 1.0, duration:
0.15-0.2}` to the on_click chain. Overlay covers the world BEFORE
the modal pops; the next modal (or transition_level fade) takes
over before the overlay releases.

**screen_fade pairing**: every `alpha=1.0` from a modal-close MUST
have a downstream `alpha=0.0` — typically the LAST modal's
close-chain — or the player is left staring at solid black after
the sequence ends.

- First modal close in sequence: `[screen_fade 1.0, ..., @previous]`
- Middle closes: just `[..., @previous]` (overlay still up)
- LAST close: `[..., @previous, screen_fade 0.0]`

`transition_level`'s own fade state machine handles the fade-back;
signal-rule chains without transition_level need the explicit
alpha=0.

**Empirical 2026-05-08**: funeral_splash → debt_papers_arrive →
"just dark." Funeral close raised alpha=1; debt_papers Continue
only popped, left overlay black.

Effect docs must spell out destructive-vs-additive semantics. See
`docs/engine-reference/api-manifest.json` (auto-generated).

## When in doubt

Ask: "could a different game (chess, shooter, ecology) want this
behavior?"
- Yes → primitive (engine code).
- No → content (JSON).

If a genre-specific behavior keeps "wanting" engine code, the
primitive vocabulary is missing something. Surface the gap, propose
the new verb, get an ADR — DON'T add the genre-specific shortcut.
