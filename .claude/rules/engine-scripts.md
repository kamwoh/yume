---
description: Path-scoped rules for Yume engine code
globs: archetypes/core/templates/godot/scripts/engine/**
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
  archetypes/core/templates/godot/scripts/engine/
```

Should return zero matches.

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

## When in doubt

Ask: "could a different game (chess, shooter, ecology) want this
behavior?"
- If yes — it's a primitive (engine code).
- If no — it's content (JSON).

If a genre-specific behavior keeps "wanting" engine code, the
primitive vocabulary is missing something. Surface that gap, propose
the new verb, get an ADR (`docs/adr/`) — don't add the genre-specific
shortcut.
