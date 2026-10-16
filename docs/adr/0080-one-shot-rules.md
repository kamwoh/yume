# ADR 0080 — One-shot rules (`once` / `once_per`)

_Date: 2026-08-16_
_Status: accepted (status corrected 2026-10-16 in batch H: the code shipped in commit deaf88e, and five demos use `once`)._

## Context

A rule fires every time its trigger fires and its query matches. There
is no way to say "at most once, ever."

`chance` narrows how *often* a rule fires but never stops it. `query`
narrows *what* it fires on. Neither expresses identity-over-time. The
only workaround is a sentinel: add a `state.foo_done` field, filter the
rule on `foo_done_eq: 0`, and set it to 1 in the rule's own effect list.
That works, and content does it constantly, but it has three costs:

1. **It only works when there is an entity to hold the flag.** A rule
   with no per-entity subject — a scripted world event keyed on a date
   and a location — has nowhere to put the sentinel except a
   purpose-built singleton entity.
2. **It doubles the authoring surface.** Every one-shot rule needs a
   state field declared in `state_init`, a query clause, and an extra
   effect. Forgetting any one of the three silently re-fires the rule
   forever. Forgetting the `state_init` entry hits the strict-missing
   query semantics documented in `.claude/rules/data-demo.md` and the
   rule never fires at all.
3. **It is invisible to tooling.** A validator cannot tell a sentinel
   pattern from ordinary state, so nothing can check that the three
   parts agree.

Scripted narrative content makes this acute: a story beat that fires
"when the player first enters this place" or "the first time this
threshold is crossed" is one-shot by nature, and a campaign has many of
them.

## Decision

Two optional Rule fields.

```jsonc
{"id": "first_arrival", "once": true,
 "trigger": {"type": "signal", "name": "entered_place"}, "effect": [...]}

{"id": "greet_each_villager", "once_per": "self",
 "trigger": {"type": "tick"}, "query": {"tags_all": ["villager"]},
 "effect": [...]}
```

- **`once: true`** — the rule commits its effects at most once per world
  lifetime.
- **`once_per: "<binding>"`** — at most once per distinct entity bound to
  that name. The binding is any name the trigger populates (`self`, `a`,
  `b`, `actor`, `target`, …), so `once_per` works across every trigger
  type rather than only entity-scan rules.
- Setting **both is an authoring error**, caught at load
  (`[rule.once_conflict]`). They are different quantifiers over the same
  rule and combining them has no coherent meaning.

**The mark happens when the rule commits its effects, not when it
matches.** This is the substantive semantic choice, and it is what makes
`once` compose with `chance`: a rule with `chance: 0.1, once: true` rolls
every time it matches and burns its single shot on the roll that
*succeeds*, rather than on the first roll that fails. Marking at match
time would make that combination silently mean "10% chance of ever
firing," which is never what an author wants.

**Storage.** The fired set lives in world state under `_fired_rules`:

```
_fired_rules = { "first_arrival": true,
                 "greet_each_villager": {"villager_02": true, ...} }
```

Per ADR 0047 world state is an engine entity and is already persisted, so
one-shot rules survive save/load for free — reloading a save does not
replay a story beat the player already saw. `reset_world` clears it,
because a new run must be able to see those beats again.

## Consequences

**Enables.** Scripted one-shot content — story beats, first-time
tutorials, discovery rewards, "the first enemy you kill" — without a
sentinel field per beat. Removes the most common three-part authoring
pattern in narrative content, and with it the two silent failure modes
(re-fires forever / never fires).

**Costs.** World state grows by one entry per fired one-shot rule. A
campaign with hundreds of beats stores hundreds of short keys — small
next to the entity state already saved. Save files gain the `_fired_rules`
key; saves written before this ADR simply have no entry, which restores
as "nothing has fired yet."

**Precludes.** Re-arming. There is no `unfire` effect. A rule that should
be able to fire again after some condition is not a one-shot rule — it is
an ordinary rule with a state guard, which is still fully available and
still the right tool for that job.

**Invariant check (#8).** `once` is a quantifier on rule firing, not a
semantic verb. The engine never reads a rule id for meaning; it only
compares ids for identity. A puzzle game's "first solve" bonus, a
shooter's "first blood" announcement, and an ecology sim's "species first
observed" log are the same field.

## Alternatives considered

**A. Keep the sentinel-state pattern.** Rejected: see Context. It is
verbose, has two silent failure modes, cannot be validated, and needs a
carrier entity that world-scoped events do not have.

**B. `max_fires: N` instead of a boolean.** Rejected as speculative
generality — no content wants "exactly 3 times", and N>1 raises questions
this ADR would have to answer badly (per what scope? reset when?).
`once` is the case that actually appears. If N ever has a real use, it is
a superset that can subsume `once` later.

**C. Mark at match time rather than at effect commit.** Rejected: it
makes `once` + `chance` mean "one roll, ever", which silently converts a
"rare event" author intent into "probably never happens".

**D. Store the fired set outside world state (a scheduler field).**
Rejected: it would not persist, so every save/load would replay every
story beat the player had already seen.

## References

- Code: `godot/scripts/engine/core/rule.gd` (`once`, `once_per`,
  validation), `godot/scripts/engine/core/phase_scheduler.gd`
  (`_fire_effects` — the single seam where a rule commits its effects)
- Tests: `godot/scripts/engine/tests/test_runner.gd` → `test_rule_once`
- Gate: `tools/validators/validate_rules.py` — rejects `once` +
  `once_per` together, and rejects a `once_per` naming a binding the
  trigger does not populate (the same binding-availability table that
  already backs the formula check)
- Related: ADR 0047 (world state as engine entity — where the fired set
  lives and why it persists), ADR 0010 (save/load)
