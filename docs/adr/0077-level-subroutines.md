# ADR 0077 — Level subroutines (`level_call` / `level_return`)

_Date: 2026-08-16_
_Status: proposed_

## Context

`transition_level` is a one-way GOTO. It tears down the current level and
replaces it, resolving its target against `level_order` — the linear
progression. There is no way to enter a level and come back.

That is the right primitive for linear progression and the wrong one for
everything shaped like a detour:

- a skill-check or training minigame entered from a town, returning a
  score
- a battle or encounter entered from an overworld, returning an outcome
- a dungeon or interior entered from a door, returning the player to the
  doorstep
- a cutscene level that hands control back where it left off

All of these are the same shape: **go there, do a thing, come back with a
result.** Today content fakes it with a second `transition_level` back to
a hardcoded caller, which (a) hardcodes the caller so the sub-level can
only ever be entered from one place, (b) has nowhere to put the result,
and (c) forces the sub-level into `level_order`, where "next" progression
can walk into it by accident.

This matters disproportionately for a genre built on minigames. The
important realisation is that **a minigame does not need a minigame
framework** — a grid puzzle, a rhythm test, a target-shoot are exactly
what Yume already builds. What was missing was the call/return edge.

## Decision

Two effects. `transition_level` is left exactly as it is.

```jsonc
{"type": "level_call", "level": "minigame_forge",
 "return_signal": "training_done",
 "args": {"difficulty": 3}}

{"type": "level_return", "result": {"score": 82, "passed": 1}}
```

- **`level_call`** pushes the current level id and the caller's
  `return_signal` onto a call stack, then swaps to `level`. `args` land
  in world state under `_call_args` so the sub-level's rules can read
  what they were invoked with.
- **`level_return`** pops the stack, swaps back to the caller's level,
  and THEN emits `return_signal` with `result` as the payload. Emitting
  after the swap is required: the caller's rules are not registered until
  its level loads, so a signal emitted before would fall on an empty
  bucket.
- **Sub-levels are off-progression.** `do_transition` normally rejects a
  target absent from `level_order`; call/return bypasses that check, so a
  minigame level is NOT listed in the progression and `transition_level
  "next"` can never walk into it.
- **An empty stack is a logged no-op** (`[level.return_empty_stack]`),
  not a crash — a sub-level reached directly (debug, a test, a save made
  inside one) can still run `level_return` harmlessly.
- **A caller that no longer exists** falls back to the progression's
  first level and logs `[level.return_orphaned]`.
- The stack lives in world state, so it persists with the save: a player
  who saves inside a minigame and reloads still returns to the right
  place.

**Both new effects are DESTRUCTIVE** and must be LAST in their effect
chain, exactly like `transition_level`. This is why they are new verbs
rather than flags on `transition_level`: `.claude/rules/engine-scripts.md`
maintains a destructive-effect list that the effect-chain gate depends
on, and overloading a verb so that it is destructive in one shape and a
subroutine call in another would make that classification unable to
answer "is this destructive?" by looking at the type.

## Consequences

**Enables.** Minigames as ordinary levels — no minigame framework, no new
rendering path, no engine knowledge of what the minigame is. Also
interiors, encounters, cutscene levels, and any "detour with a result".
Nesting works (a dungeon that calls a puzzle) because the stack unwinds
in order.

**Costs.** One more piece of world state to persist. Level swaps remain
as expensive as they were — call/return does not make a sub-level cheap,
so a minigame entered dozens of times per session pays a full teardown
each way. Content that needs a *cheap* modal interaction should use a
screen (ADR 0011), not a sub-level. The ADR does not try to blur that
line.

**Precludes.** Returning to an exact position within the caller level.
The caller is restored by level identity; entity positions come back from
whatever the level's spawn data and persistence rules say. Position
restoration would need per-entity snapshotting, which is the save
system's job and is deliberately not duplicated here.

**Invariant check (#8).** No new primitive: these are two effects
composing the existing level machinery and the existing signal buffer.
The engine never learns what a sub-level is FOR — "minigame", "dungeon",
"encounter" are content words. A puzzle game calling a bonus stage and a
strategy game calling a tactical battle use the identical pair.

## Alternatives considered

**A. Add `return_to` / `return_signal` fields to `transition_level`.**
Rejected: it makes one effect type sometimes-destructive-replace and
sometimes-subroutine-call, which breaks the destructive-effect
classification the effect-chain gate depends on. Keeping the verbs
separate keeps that gate answerable by type alone.

**B. A dedicated minigame framework** (a registry of minigame types, an
engine-side score protocol). Rejected outright — it would put game
vocabulary in the engine, violating invariant #8, and it is unnecessary:
a minigame is already expressible as a level. The only thing missing was
the edge back.

**C. Render the sub-level into a sub-viewport over the caller**, leaving
the caller loaded. Rejected for now: it avoids the teardown cost but
needs a second active World, doubling every director's lifetime
assumptions. Worth revisiting only if measurement shows the swap cost
actually hurts.

**D. Keep faking it with a second `transition_level`.** Rejected: see
Context — it hardcodes the caller, has nowhere to put the result, and
pollutes `level_order`.

## References

- Code: `godot/scripts/engine/core/effects/effect_shell.gd`
  (`level_call`, `level_return`), `godot/scripts/engine/core/effect_apply.gd`
  (dispatch), `godot/scripts/engine/coordinators/level_transition_coordinator.gd`
  (`process_pending`, `do_transition` off-progression flag, post-swap
  signal emission)
- Tests: `godot/scripts/engine/tests/test_runner.gd` → `test_level_subroutine`
- Gate: `.claude/rules/engine-scripts.md` § effect-chain gate — both verbs
  added to the destructive-effect list; `validate_rules.py` enforces
  destructive-last for them
- Related: ADR 0006 (multi-level architecture), ADR 0011 (screens — the
  cheap-modal alternative), ADR 0047 (world state — where the stack
  lives and why it persists)
