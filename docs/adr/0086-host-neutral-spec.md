# ADR 0086 — Yume is a host-neutral spec, and Godot is the reference interpreter

_Date: 2026-10-17_
_Status: accepted 2026-10-17_

_Revises: ADR 0021 (its "Constrains" item on porting and its Alternative C)_

## Context

Yume exists to make game development efficient for an LLM. The LLM
writes JSON that states game intent. It does not write the long,
repetitive engine code that humans usually write.

ADR 0021 calls Yume "the JSON layer over Godot". It accepts that
"Yume can't trivially port to other engines". It rejects Alternative C
("support Godot AND Unity AND Unreal") as premature. It adds this note:
"if Yume becomes valuable enough, port via specifications, not
reimplementation."

The owner's view (2026-10-17): the JSON is the product. The
interpreter is replaceable. A web interpreter on three.js, for
example, must be possible without a change to any game.

An audit on 2026-10-17 checked how much of today's JSON depends on
Godot. The full list is in
[`docs/engine-reference/host-coupling-audit.md`](../engine-reference/host-coupling-audit.md).
In summary:

- **Already neutral:** the seven primitives, the 50 effects and 10
  triggers, and queries. The UI vocabulary (`label`, `button`, `vbox`,
  ...) and `tests.json` scenarios (`press`, `tick`, `expect`) are
  neutral too. Asset
  files use open formats (glTF, PNG, OGG). No demo names a Godot
  class.
- **Tied to Godot:**
  1. Asset references use `res://` paths (201 references in 38 files).
  2. Formulas run on Godot's `Expression`. No list of functions is
     enforced, and rules call `atan2`, which the documented list of 14
     helpers does not include.
  3. Shaders are `.gdshader` files (17 references, 6 tracked library
     files), and one material is a `.tres` resource.
  4. Key names come from Godot's key table
     (`OS.find_keycode_from_string`).
  5. Physics, lighting and sky fields mean what Godot's nodes do with
     them. No document defines them.
  6. Randomness uses Godot's global PRNG (`seed()`, `randf()`).

The neutral parts are the core of the language. The tied parts are at
the edges. Thus the change is possible at a bounded cost.

## Decision

### 1. Three layers

| Layer | Owns | Example today |
|---|---|---|
| **Spec** | The JSON format and what each field means | `world/rules/*.json`, `screens.json`, `tests.json` |
| **Interpreter** | Reads the spec and drives one host | `godot/scripts/engine/*.gd` |
| **Host** | Rendering, physics, audio, input, UI | Godot 4.6.1 |

The spec is the contract. An interpreter is one implementation of it.

### 2. Godot is the reference interpreter

The Godot interpreter stays the only interpreter. Where the spec is
silent, the Godot behavior is the answer for now. Each such case goes
into the audit document until the spec defines it.

### 3. New spec fields describe intent, not the host

From this ADR on, a new or changed JSON field must not contain:

- a Godot class, node, property or enum name,
- a `res://` or `user://` path,
- a Godot-only file format (`.gdshader`, `.tres`, `.tscn`).

The tech-director checks this rule in each ADR review. A validator
enforces it after phase 1 (see Phases).

### 4. Exact and host-defined behavior

The spec puts each behavior in one of two classes:

- **Exact:** rule order, tick order, effect order, queries, formulas,
  state, relations, the calendar clock, UI structure and screen flow.
  Every interpreter must give the same result from the same input.
- **Host-defined:** physics results, pathfinding routes, rendering,
  shader output and audio mixing. The spec defines the inputs and the
  guarantees (for example, "a `static` body blocks a `character`
  body"). The exact numbers belong to the host.

A conformance test must not assert an exact value of a host-defined
behavior.

### 5. `tests.json` is the conformance suite

The per-game scenario tests already use only neutral steps. Every
interpreter must pass them. A new step verb must be neutral by rule 3.

### 6. ADR 0021 still applies inside each interpreter

"Expose, don't reimplement" stays. Each interpreter exposes its own
host's physics, UI and audio. It does not rewrite them. This ADR
changes only the scope of the promise: games depend on the spec, not
on Godot.

### 7. No second interpreter in this ADR

A later ADR decides whether to build one (for example, a small
TypeScript interpreter for 2D games). That decision waits for phases 1
to 4.

## Phases

Each phase gets its own ADR or revision when it changes a schema.

1. **Asset references.** Replace `res://` paths with paths relative to
   the game folder or the shared library. Each interpreter resolves
   them. A validator (`validate_host_neutral.py`) then fails on
   `res://`, `user://`, `.gdshader`, `.tres` and `.tscn` in spec files.
2. **Formula language.** Write the grammar, the function list and the
   number rules (for example, what `5 / 2` gives) into the contract
   document. The validator rejects any other function. The Godot
   interpreter keeps `Expression` as its implementation.
3. **Shaders.** The shader DAG (ADR 0058) becomes the only shader form
   in the spec. Hand-written `.gdshader` files become Godot-only
   extensions of the reference interpreter, outside the spec.
4. **Vocabularies.** Write the key-name list, the audio bus model,
   and the lighting, sky and physics fields into the contract
   document, each in host-free words.
5. **Contract document.** Update `docs/guideline/30_framework_primitives.md`
   to state the three layers and the two behavior classes. This ADR
   authorizes that change.

### Phase status (2026-10-18)

| Phase | ADR | Status |
|---|---|---|
| 1. Asset references | 0087 | done |
| 2. Formula language | 0088 | done |
| 3. Shaders | 0089 | done |
| 4. Vocabularies | 0090 | done |
| 5. Contract document | this ADR | done: §Architectural framing in `30_framework_primitives.md` |

Open questions 1 and 2 stay open. The answer to question 3 is "the
relative path is enough" (ADR 0087).

## Consequences

**Enables:**
- A second interpreter (web, mobile, another engine) without a change
  to any game.
- A vocabulary of game intent, which an LLM uses more reliably than
  Godot class names.
- A clear test of correctness: an interpreter is correct when it
  passes the conformance suite.

**Costs:**
- Phases 1 to 4 change schemas, validators, skills and the local
  demos.
- The spec must define behavior that Godot gives for free today. The
  formula language and the key names are the largest items.
- Rule 3 makes some ADRs longer, because each new field needs a
  host-free definition.

**Does not change:**
- How the Godot interpreter works inside. It still delegates to Godot.
- The per-game workflow. Authors still write only JSON.

## Alternatives considered

### A. Keep ADR 0021 as it is

No cost now. But each new ADR adds more Godot names to the JSON, and
a later port costs more each month. Rejected.

### B. Rewrite the interpreter for a second host now

This proves portability at once. But the spec has no definition yet
for formulas, keys or host-defined behavior, so the new interpreter
would copy Godot by trial and error. Rejected for now. Rule 7 keeps
it open.

### C. Spec plus conformance suite, with Godot as the reference (chosen)

Defines the contract first, at a bounded cost, and keeps one working
interpreter all the time.

## Open questions

1. **Randomness in conformance tests.** Must the spec define one seeded
   PRNG, so that random rules give the same results on every
   interpreter? Or do conformance tests avoid random rules?
2. **Tick timing.** The spec must state the order of input, rules and
   physics within one tick. The Godot interpreter runs them on the
   physics clock (ADRs 0068, 0069). Is that order exact or
   host-defined?
3. **Asset resolution.** Is a path relative to the game folder enough,
   or does the spec need an asset table with ids?

## References

- ADR 0001 — seven primitives
- ADR 0021 — Yume as JSON layer over Godot (revised by this ADR)
- ADR 0058 — shader DAG
- ADRs 0068, 0069 — sim tick and input poll on the physics clock
- `docs/engine-reference/host-coupling-audit.md` — the list of
  Godot dependencies in the JSON
