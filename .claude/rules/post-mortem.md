# Post-mortem ritual — mandatory after every user-found bug

When the user surfaces a bug (anything from "this doesn't work" to a
specific stack trace), **do not just fix the bug**. Run the
post-mortem ritual. Skipping this means the same bug class
re-surfaces in a future session, in a future game, in a future
design pipeline.

## The ritual (4 steps, no skipping)

### Step 1 — Fix the bug

Diagnose, fix, verify. Standard work. Output: a commit with the
fix.

### Step 2 — Identify the gate that should have caught it

Ask: *which existing skill, rule, validator, or test should have
prevented this?* Be specific. Not "QA should be more careful" —
name the file. Examples:

- `yume-tech-director` Invariant #N — engine review missed it
- `yume-playtest` Gate M — playability harness didn't probe it
- `yume-game-reviewer` Axis K — design review didn't catch it
- `validate_screens.py` — static validator could have caught it
- `.claude/rules/data-demo.md` — schema discipline rule didn't list it
- `visual-qa.md` — VQA prompt didn't ask the right question
- (none — this is a NEW bug class without a current gate; flag it
  and propose a new gate)

### Step 3 — Harden the gate

Update the skill / rule / validator / test so the SAME bug class
cannot slip through again. The update must be:

- **Concrete and falsifiable** — a checklist item, a grep command,
  a heuristic minimum, an axis with measurable failure criteria.
  Not "be careful about X" — "every PR touching X must run Y."
- **Documented with the empirical case** — cite the bug that
  motivated the gate so future readers understand the intent.
- **Version-anchored** — date the change so future ripple-
  analysis can cross-reference.

If no gate exists for this bug class, CREATE one. New invariant in
the relevant skill, new axis in the relevant reviewer, new test in
the suite, new rule in `.claude/rules/`, new validator in `tools/`.

#### Step 3a — Bug-class generalization check (REQUIRED before declaring step 3 done)

Before committing the gate update, ask:

> *"Does this fix address the SYMPTOM site, or the underlying
> primitive / heuristic / pattern?"*

A symptom-site fix patches the one rule / file / button where the
bug surfaced. A primitive fix repairs the underlying mechanism so
the bug class can't reach any consumer.

Empirical case (2026-05-08): `state_set value="Find your shop..."`
crashed `Formula.evaluate` because `looks_like_formula` was too
permissive. The SAME bug class hit show_toast weeks earlier (commit
`caabe39`). The fix back then was localized — a `_value_text()`
helper for show_toast only. State_set still used the broken
heuristic. Fixing show_toast and not generalizing left the trap
loaded for state_set, future effects, and any new caller of
`_value()`. Today's fix tightened `looks_like_formula` itself,
eliminating the bug everywhere.

**Litmus test**: name two other call sites that could trigger the
same bug under similar input. If either could, the fix is
symptom-level — return to the primitive layer.

**Common patterns where this matters**:
- A wrong heuristic in shared code → fix the heuristic, not just
  the one caller that exposed it.
- A missing engine carve-out (e.g. freeze-policy) → audit ALL
  pending pipelines, not just the one that hit the bug.
- A schema-discipline gap (e.g. effect-chain ordering) → add a
  validator, don't fix one rule's chain by hand.
- A reviewer-axis miss → if axis N missed bug X, ask "would axis
  N also miss bugs Y, Z, W?" and broaden the axis.

If the bug-class generalization step would take 5x longer than the
symptom-site fix, document the gap and ship the symptom fix WITH a
TODO referencing this rule. Don't skip silently.

### Step 4 — Commit the gate update + cite the bug

Commit message must mention BOTH the bug fix AND the gate change.
Pattern:

```
<one-line bug fix summary>

<paragraph explaining the bug>

Gate hardening:
- <skill/rule>: <what was added>. Catches this bug class
  going forward.

Empirical case: <one-line description with date>.
```

This commit log is the institutional memory. Future sessions read
git log + skill files; both should reflect the lesson.

## Why this matters

Every bug is information. A bug that gets fixed but not gated will
re-occur. A bug that gets gated cannot re-occur in that exact
form — and the gate often catches related bugs too.

The ratchet only goes one way: each bug makes the system stronger,
not just the specific code patched.

## Empirical precedents (each one followed this ritual)

- **2026-05-08 boot-flow `transition_level` dropped under freeze**
  → Bug fix in `world.gd`. Gate: yume-tech-director Invariant #10
  (freeze-policy audit on every pending-state pipeline).
- **2026-05-08 first-frame game-flash before title**
  → Bug fix in `screen_flow.gd` (sync push). Gate: yume-playtest
  Gate 5b (two-frame boot capture comparison).
- **2026-05-08 modal stack covered Brookhaven after Travel button**
  → Bug fix: added `@root` engine sentinel + button update.
  Gate: yume-playtest Gate 5c (multi-modal commit-button must
  use `@root`).
- **2026-05-08 11 broken `_close` buttons across merchant**
  → Bug fix in screens.json. Gate: `tools/validate_screens.py`
  static validator + `.claude/rules/visual-qa.md` screen-flow gate.
- **2026-05-07 game shipped feature-complete but soulless**
  → Bug fix: flavor-design.md. Gate: yume-game-reviewer Axis 14
  (voice & texture density) + new yume-flavor-writer skill.
- **2026-05-07 contact-as-sale instant-despawn**
  → Gate: yume-systems-designer core-verb multi-tick spec rule.

Each gate now blocks that bug class at design time, not playtest
time.

## What this rule is NOT

- Not "be more careful." That's not actionable.
- Not "add a comment in the code." Comments rot.
- Not "remember for next time." Memory rots faster.
- Not "log it in task_plan.md." That's a TODO list, not a gate.

The gate must be ENFORCING — a checklist a future skill MUST run, a
test that runs in CI, a validator that fails sync, a reviewer axis
that blocks acceptance. Enforcement, not suggestion.

## When to skip this ritual

Almost never. Even minor bugs reveal a class. The exceptions:

- **One-character typos in the user's prose** (truly accidental,
  not a process gap)
- **Bugs in third-party code** outside Yume (Godot, OS) — file
  upstream and document a workaround, but the gate should still
  catch the workaround being correctly applied
- **The user explicitly says "just fix it, don't post-mortem"** —
  respect that and move on, but flag the gap before the
  conversation ends
