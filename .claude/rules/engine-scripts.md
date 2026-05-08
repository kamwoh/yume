---
description: Path-scoped rules for Yume engine code
globs: godot/scripts/engine/**
---

# Engine scripts — invariants

The engine is **primitives + interpreter**. Adding a vocabulary item
(effect type, draw op, query operator) requires engine code; adding a
**composition** (specific rule, specific shape, specific binding)
requires only JSON.

Contract: `docs/30_framework_primitives.md` invariants #1–#8.

## DON'T

- ❌ **Add semantic effect types.** No `damage`, `need_decay`, `heal`,
  `gain_xp`, `attack`, `advance_stage` as effect `type` strings. Express
  them as `state_add` / `state_set` with semantic field names in JSON
  content.
- ❌ **Add entity subclasses.** No `Agent`, `Item`, `Projectile`,
  `Building` as `extends Entity`. Distinctions emerge from tags +
  properties + relations.
- ❌ **Hardcode entity ids in engine code.** No `entities.get("player_1")`,
  `if ent.def_id == "wheat":`. Engine sees IDs as opaque strings.
- ❌ **Hardcode field names in engine code beyond reserved set.** Reserved:
  `position`, `velocity`, `age`. Everything else (hp/hunger/xp/mana/...)
  is content vocabulary; engine never reads them by name.
- ❌ **Genre-specific functions.** No `damage_apply()`, `level_up()`,
  `harvest_crop()`. Engine is generic; semantics live in JSON rules.
- ❌ **Renderer code in engine modules.** Engine doesn't import Sprite2D,
  MeshInstance3D, or anything visual. Renderer modules read engine state.

## DO

- ✅ **Treat new vocabulary as a primitive expansion.** If you genuinely
  need a new effect/operator/binding, it joins the verb set for ALL games.
  Document the addition in `docs/30_framework_primitives.md`.
- ✅ **Pass `env: Dictionary` for cross-module state.** Modules access
  entities/relations/spatial_index through env, not via singleton or
  direct script reference.
- ✅ **Use Variant return types** for context-resolution helpers.
  `_value`, `_position`, `_resolve_id` return whatever shape JSON gives.
- ✅ **Strict missing-field semantics in queries.** A missing field =
  no match. No permissive fallback (matches `_match_fields` convention).
- ✅ **Ship tests with the phase.** Every primitive addition lands with
  unit tests in `tests/test_runner.gd`.

## Test invariants

The engine has a **no-genre-leak invariant** (W5.7). Run this grep
before merging — anything matching is a regression:

```bash
grep -rE 'type[":]?\s*[":]?(damage|need_decay|need_restore|gain_xp|heal|attack|advance_stage)' \
  godot/scripts/engine/
```

Should return zero matches.

## Camera-stability anti-patterns

When writing Camera2D / Camera3D follow code, never combine
**position-lerp + per-frame look_at**. The orientation re-aims each
tick using the LERPING (mid-flight) camera position, so during the
lerp the camera visibly rotates as the target translates. Symptom:
"when I walk in iso3d, I feel like the camera is trying to rotate."

✅ **Correct pattern**: compute a FIXED orientation (basis from
target-direction relative to FINAL desired position, not current
lerping position), then only the camera POSITION lerps:

```gdscript
var desired := target + offset
_camera3d.global_position = _camera3d.global_position.lerp(desired, t)
# Orient against the desired (final) position so basis is steady
# even while position is mid-lerp.
var basis := Basis.looking_at(target - desired, Vector3.UP, true)
_camera3d.global_transform.basis = basis
```

❌ **Wrong**:
```gdscript
_camera3d.global_position = _camera3d.global_position.lerp(desired, t)
_camera3d.look_at(target, Vector3.UP)   # ← uses lerping position
```

Empirical case: 2026-05-08 merchant iso-3d. Subtle "drift" on every
walk step that the user noticed but couldn't articulate. Fixed in
`game_shell.gd::_camera_isometric_3d`.

## Visual validation gate (rendering primitives)

**When modifying any of these files**, capture + invoke
`yume-visual-designer` BEFORE committing:

- `control_factory.gd`
- `screen_flow.gd`
- `entity_sprite_2d.gd` (or any `renderer_2d/*` / `renderer_3d/*`)
- `game_shell.gd` (HUD construction, camera, viewmodel sections)
- Any new module that instantiates Godot Control / CanvasItem / Mesh
  nodes from JSON

Phase A is not done until visual-designer accepts. Empirical
precedent: ADR 0011 Phase A (commit `6f6a8d4`) shipped with a
miscentered Sokoban title screen because the implementer noticed the
anchor offset, self-deferred to "Phase B," and committed Phase A
anyway. User caught it on the next message — pipeline failure.

**The check**: run a relevant demo with `--capture`, read the PNG,
and either fix the visual issue OR run `yume-visual-designer` on it
and apply its revisions. If you don't have a render to capture
(e.g. pure refactor), skip this gate; if you DO, it's mandatory.

Tech-director enforces this on merge: see
`.claude/skills/yume-tech-director/SKILL.md` §visual gate.

## Effect-chain validation gate (interaction primitives)

The visual gate above catches static rendering. It does NOT catch
broken effect chains (button click → nothing happens). When adding
or modifying an effect type that interacts with screen flow, save
state, or scene lifecycle:

- `transition_screen`, `transition_level`, `reload_scene`, `scene_change`
- `save_state`, `load_state`
- `quit_app`
- Any effect that reloads, destroys, or replaces the active scene

`screen_fade` is **non-destructive** — it tweens an overlay's alpha and
can safely be queued anywhere in a chain (e.g. a fade-flash before a
transition is fine). `transition_level` with `fade_duration > 0` is
still destructive at the swap midpoint: the level swap happens between
ticks once the fade-out completes, so any effect queued after it that
references the OLD level's entities will be silently dropped, same as
ordinary `transition_level`.

**Rule**: trace every `on_click` (and `on_submit`, `on_change`,
`on_press`) chain end-to-end before shipping. If any effect in the
chain destroys state, replaces the scene, or reloads data, it must
be the **LAST** effect. Anything queued after a destructive effect is
silently dropped when the destruction lands at end-of-frame.

Empirical precedent: ADR 0010 reference content (commit `13d2910`)
wired sokoban "New Game" as `[load_data, transition_screen]` (the
effect was later renamed to `reload_scene` for clarity). The button
rendered fine and the visual gate passed. But clicking it did
nothing — the scene reload queued by that effect destroyed the
following `transition_screen`. User caught it on the next message
(commit `b109324`). Visual gate didn't help because nothing was
visually wrong; the bug was in interaction.

**The check**: for each new screens.json / hud.json / overlay.json /
tutorial.json file (or rule that fires `transition_*` / `*_state`):

1. List every effect chain (on_click, on_press, on_submit, etc.).
2. For each chain, identify any destructive effects (above list).
3. Confirm destructive effects are LAST in the chain.
4. If a chain needs sequencing (e.g. "reset world then transition"),
   either combine into a single effect (preferred) OR queue the
   follow-up via a one-shot rule that fires after the destruction
   completes.
5. **Modal-pop reveals world (added 2026-05-08)**: any chain that
   pops a modal (`transition_screen @previous` or `@root`) reveals
   the world underneath. The world is visible until the NEXT thing
   covers it. Two flavors:

   a) **Pop → transition_level**: pop reveals OLD level for ~2
      frames before transition_level's fade-out kicks in.
      Empirical: merchant Travel-to-Brookhaven (user: "first load
      level_town_pendrel map then only load the hud conversation").

   b) **Pop → wait-for-signal-rule → next modal**: pop reveals
      world for ~1 tick (~0.1s) until the rule listening for the
      button's emitted signal fires `transition_screen` to push
      the next modal. Empirical: merchant funeral_splash "Goodbye,
      Uncle" → emits funeral_dismissed → @previous pops, leaving
      brookhaven world visible for 1 tick before
      brookhaven_debt_papers_trigger rule opens debt_papers_arrive
      (user: "between the funeral canvas and the next button, I
      see the default sky and grey ground").

   **Mitigation (both flavors)**: prepend a `screen_fade {alpha:
   1.0, duration: 0.15-0.2}` to the on_click chain. The opaque
   overlay covers the world BEFORE the modal pops; the next modal
   (or transition_level fade) takes over before the overlay
   releases. screen_fade is non-destructive so it stays intact
   through the whole chain.

   **The check**: any button whose on_click chain pops a modal
   (via `@previous` or `@root`) AND emits a signal consumed by a
   rule that opens another modal — must start with screen_fade.
   Visual gate misses it (flash too brief to capture); effect-
   chain gate only checks ordering not inter-tick reveal.

Effect documentation must spell out destructive-vs-additive semantics.
See `docs/engine-reference/api-manifest.json` (auto-generated).

## When in doubt

Ask: "could a different game (chess, shooter, ecology) want this
behavior?"
- If yes — it's a primitive (engine code).
- If no — it's content (JSON).

If a genre-specific behavior keeps "wanting" engine code, the
primitive vocabulary is missing something. Surface that gap, propose
the new verb, get an ADR (`docs/adr/`) — don't add the genre-specific
shortcut.
