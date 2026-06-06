# Post-mortem ritual — mandatory after every user-found bug

When the user surfaces a bug (anything from "this doesn't work" to a
stack trace), **don't just fix it**. Run the ritual. Skipping means
the same bug class re-surfaces in a future session, future game,
future pipeline.

## Self-enforcement: TaskCreate ritual

The moment a bug surfaces, **BEFORE writing the fix**, create ONE
TaskCreate bundling fix + gate. Subject: `"Post-mortem: <bug
name>"`; description includes both the symptom and the gate to add.
Set `in_progress` immediately. The task stays open until BOTH are
committed; closing without the gate is forbidden.

Forcing function: TaskList stays visible across the conversation.
A hanging post-mortem task is more embarrassing to ignore than a
paragraph in a rule file. The user can also see it.

**Empirical 2026-05-26**: skipped post-mortem on the
`shutil.rmtree(game_dir)` data-destruction bug, then again on the
`state.facing`/`state.yaw` rename. Both times the user had to ask
"do the post-mortem." This ritual binds it to the task list.

## The ritual (4 steps, no skipping)

### Step 1 — Fix the bug

Diagnose, fix, verify. Output: commit with the fix.

### Step 2 — Identify WHO is responsible

Ask explicitly: **"who is responsible?"** — i.e. which existing
skill / rule / validator / test should have prevented this. Name
the file, not "QA should be more careful." Every bug has an owner;
if it slipped through, the owner was missing a check.

Examples:
- `yume-tech-director` Invariant #N — engine review missed it
- `yume-playtest` Gate M — playability harness didn't probe it
- `yume-game-reviewer` Axis K — design review didn't catch it
- `validate_screens.py` — static validator could have caught it
- `.claude/rules/data-demo.md` — schema rule didn't list it
- `visual-qa.md` — VQA prompt didn't ask the right question
- (NEW bug class without current gate — flag + propose new gate)

### Step 3 — Harden the gate

Update the skill / rule / validator / test so the bug class can't
slip through again. Required attributes:

- **Concrete + falsifiable** — checklist item, grep command,
  heuristic, axis with measurable failure criteria. NOT "be careful
  about X" — "every PR touching X must run Y."
- **Documented with empirical case** — cite the bug; future readers
  need the intent.
- **Version-anchored** — date the change.

No existing gate → CREATE one (new invariant in the skill, new axis
in the reviewer, new test in the suite, new rule under
`.claude/rules/`, new validator under `tools/validators/`).

#### Step 3a — Bug-class generalization (REQUIRED before declaring step 3 done)

Ask: *"Does this fix address the SYMPTOM site, or the underlying
primitive / heuristic / pattern?"*

Symptom-site = patches the one rule/file/button where the bug
surfaced. Primitive = repairs the underlying mechanism so the bug
class can't reach any consumer.

**Litmus**: name two other call sites that could trigger the same
bug under similar input. If either could, the fix is symptom-level
— return to the primitive layer.

**Empirical 2026-05-08**: `state_set value="Find your shop..."`
crashed `Formula.evaluate` because `looks_like_formula` was too
permissive. The SAME bug class hit show_toast weeks earlier (commit
`caabe39`); that fix was localized to a `_value_text()` helper for
show_toast only. State_set still used the broken heuristic. Fixing
show_toast but not generalizing left the trap loaded for state_set,
future effects, anything else calling `_value()`. The recent fix
tightened `looks_like_formula` itself, eliminating the bug
everywhere.

**Common patterns this matters for**:
- Wrong heuristic in shared code → fix the heuristic, not the
  caller that exposed it.
- Missing engine carve-out (freeze-policy, etc.) → audit ALL
  pending pipelines, not just the one hit.
- Schema-discipline gap (effect-chain ordering, etc.) → add a
  validator, don't fix one rule's chain by hand.
- Reviewer-axis miss → if axis N missed bug X, ask "would axis N
  also miss Y, Z, W?" and broaden.

If generalization would take 5x longer than the symptom fix,
document the gap + ship the symptom fix WITH a TODO referencing
this rule. Don't skip silently.

### Step 4 — Commit the gate + cite the bug

Commit message mentions BOTH the fix AND the gate:

```
<one-line bug fix summary>

<paragraph explaining the bug>

Gate hardening:
- <skill/rule>: <what was added>. Catches this bug class going
  forward.

Empirical case: <one-line description with date>.
```

The commit log IS the institutional memory.

## Why this matters

Every bug is information. Fix-without-gate → bug re-occurs.
Fix-with-gate → bug class blocked, and the gate often catches
related bugs too. The ratchet only goes one way.

## Empirical precedents (each followed this ritual)

| Date | Bug | Gate added |
|---|---|---|
| 2026-05-08 | boot-flow `transition_level` dropped under freeze | yume-tech-director Invariant #10 (freeze-policy audit) |
| 2026-05-08 | first-frame game-flash before title | yume-playtest Gate 5b (two-frame boot comparison) |
| 2026-05-08 | modal stack covered Brookhaven after Travel | yume-playtest Gate 5c (`@root` for multi-modal commit) |
| 2026-05-08 | 11 broken `_close` buttons in merchant | `validate_screens.py` + visual-qa.md screen-flow gate |
| 2026-05-07 | game shipped feature-complete but soulless | yume-game-reviewer Axis 14 (voice & texture) + yume-flavor-writer |
| 2026-05-07 | contact-as-sale instant-despawn | yume-systems-designer multi-tick spec rule |
| 2026-05-18 | pattern-spawned bushes floated above ground | new `visual.y_offset_mesh` (scales with `state.scale`); `validate_mesh_y_offset.py` patterns iteration; level-designer + asset-designer SKILL notes. Generalization: numeric visual fields authored against a def's reference scale MUST scale with per-instance `state.scale`, OR be flagged pattern-incompatible. |
| 2026-05-18 | animated npc_morwen floated 0.85m | cleared stale `y_offset` after pivot-convention swap (static center-pivot → rigged foot-pivot). Gate: `animate_smoke.py` MUST pop legacy `y_offset`/`y_offset_mesh` before re-deriving, regardless of new bbox. Generalization: when pivot semantics change, the WHOLE pivot-dependent field family resets, not selective updates. |

Each gate now blocks that bug class at design time, not playtest.

## What this rule is NOT

- Not "be more careful" (not actionable)
- Not "add a comment" (comments rot)
- Not "remember for next time" (memory rots faster)
- Not "log it in `.claude/plan/backlog.md`" (that's a TODO list, not a gate)

The gate must be ENFORCING — a checklist a future skill MUST run, a
test in CI, a validator that fails sync, a reviewer axis that
blocks acceptance.

## When to skip

Almost never. Even minor bugs reveal a class. Exceptions:
- **Typos in user's prose** (truly accidental, not a process gap)
- **Third-party bugs** (Godot, OS) — file upstream + document
  workaround; the gate should still catch the workaround being
  correctly applied
- **User explicitly says "just fix it, don't post-mortem"** —
  respect, but flag the gap before the conversation ends
