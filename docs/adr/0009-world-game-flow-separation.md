# ADR 0009 — World / Game / Flow separation + audio cues + variants + localization

_Date: 2026-05-05_
_Status: **accepted with conditions** (tech-director review 2026-05-05)_

## Context

Yume's `world_rules.json` is currently doing two conceptually distinct
jobs that have always been tangled:

1. **World physics**: how the simulated world runs. Bullets damage
   monsters; monsters home toward player; plants grow; weather
   changes. These are TRUTHS OF THE WORLD that exist regardless of
   whether anyone's "playing."
2. **Game logic**: the metagame layer. Score increases on monster
   death; win when score=25; transition level when goal touched. These
   are GOALS imposed on the world.

Without #2 (game logic), a Yume "game" is a sandbox — the world runs
but nothing matters; no win/lose. With #2, the same world becomes a
game.

The same world can host different games. doomarena3d's combat physics
could host: deathmatch, score-attack, capture-the-flag, survival,
escape-the-chamber. Currently all of these would require duplicating
the entire `world_rules.json`. That violates Yume's reuse principle.

Three other related issues compound this:

3. **`hud.json` mixes display widgets with win/lose conditions.**
   `{"binds": "clock.boss_killed", "op": ">=", "value": 1, "message": "WIN"}`
   is game logic, not display. The HUD should *display* state,
   not *decide* outcomes.
4. **Audio is hardcoded in rules.** Rules emit
   `{event: "play_sound", name: "hit"}` directly. To swap a game's
   audio palette (industrial → magical), every rule has to change.
5. **No variant / difficulty mechanism.** A game wanting easy/hard
   modes has to duplicate all rules with different numerics.

This ADR proposes a unified refactor addressing all five concerns.

## Decision

Reorganize game data into clearly-layered subfolders. Each layer
answers a distinct question and has a single skill that owns it.

### New layout

```
data/<game>/
├── entities/                     # Vocabulary (defs unchanged)
│   └── *.json
├── world/                        # The simulated world
│   ├── rules.json              # World rules — how things behave
│   └── state.json                # Initial world state (was world.json)
├── game/                         # The game played in the world
│   ├── goals.json                # Game goals — scoring, win/lose, progression triggers
│   └── flow.json                 # Level/scene sequencing (was progression.json)
├── ui/                           # Player-facing surface
│   ├── hud.json                  # Display widgets only
│   ├── input.json                # Input edge classification (was inputs.json)
│   └── strings.json              # Optional: localized text
├── audio/                        # Optional: audio cue mappings
│   └── cues.json                 # event_name → sound_name lookup
├── render/                       # Visual config
│   └── scene.json                # Camera, lighting, ground (was root scene.json)
├── variants/                     # Optional: difficulty/mode overlays
│   ├── easy.json
│   ├── normal.json
│   └── hard.json
└── levels/                       # Per-level data
    └── <name>/
        ├── entities.json         # Initial entity placements
        └── rules.json            # Per-level game rules (clear conditions)
```

### Layer ownership

Each layer maps to a designer skill:

| Layer | Skill | Question answered |
|---|---|---|
| `entities/` | yume-content-designer | What entity vocabulary exists? |
| `world/` | yume-systems-designer | How does the world physically behave? |
| `game/` (rules + flow) | NEW yume-game-rules-designer | What is the goal? How do you win/lose? What level comes next? |
| `ui/` | yume-content-designer + asset-designer | How is state displayed and controlled? |
| `audio/` | yume-asset-designer | Which sound plays for which event? |
| `render/scene.json` | yume-asset-designer | Camera, lighting, ground config |
| `variants/` | yume-game-rules-designer | What scaling overrides exist for difficulty? |
| `levels/` | yume-level-designer + yume-content-designer | Per-level world state + clear conditions |

Splits the current overstuffed yume-content-designer into 3-4 focused
skills, each producing one layer.

### How rules from multiple files compose

The engine loads ALL rule files and registers them as a single rule
set in the scheduler. The scheduler doesn't distinguish world-vs-game
rules at runtime — the split is purely AUTHORING-time. Files load in
this order:

1. `world/rules.json` — physics rules (e.g. bullet_kills_monster)
2. `game/goals.json` — game rules (e.g. score_on_kill, win_check)
3. `levels/<current>/rules.json` — per-level game rules (e.g. clear at score>=5)
4. `variants/<active>.json` — overlay (modifies rule values)

Each subsequent file can override or extend the previous via
explicit rule ids. Standard JSON deep merge by id.

### Audio cues layer (REV per tech-director — unified with localization @-prefix)

Currently: rules emit specific sound names (`"name": "hit"`). To swap
audio palette, every rule changes.

New: rules emit `play_sound` (existing event, no new shell event)
with EITHER a literal sound name OR a `@cues.<key>` reference.
GameShell resolves the prefix at receive time using `audio/cues.json`.

Rule emits one of:
```jsonc
// Concrete sound (legacy, still works):
{"type": "emit_shell_event", "event": "play_sound", "name": "hit"}

// Cue reference (resolved via audio/cues.json):
{"type": "emit_shell_event", "event": "play_sound", "name": "@cues.monster_died"}
```

`audio/cues.json`:
```jsonc
{
  "cues": {
    "monster_died": "kill",
    "bullet_hit": "hit",
    "level_cleared": "chamber_breach",
    "player_hurt": "hurt"
  }
}
```

GameShell on receiving `play_sound`: if `name` starts with `@`, look
up the path (`@cues.monster_died` → `cues.json["cues"]["monster_died"]`
→ "kill"); else use the name as-is.

This unifies audio with localization (`@hud.level_label` → strings.json)
under one indirection syntax. Single concept (`@`-prefix means "look
up via referenced file"); single shell event (`play_sound`); zero new
effect types.

To swap palette (industrial → magical): replace `audio/cues.json`'s
sound mappings. Rules unchanged. Sounds library (`sounds.json`)
unchanged. Only the cues mapping file changes.

### Variants layer

Optional `variants/<name>.json` overlay applied at load time:

```jsonc
{
  "_comment": "Easy mode for sokoban — gives the player a hint counter that displays optimal moves.",
  "rules": {
    "outer_imp_spawn": {"effect.value": 3.0},
    "boss_def": {"state_init.hp": 5}
  },
  "world_state": {"difficulty": "easy"}
}
```

Engine path: at scene load, check for active variant (config in
`scene.json` or env var). Apply rule-id-keyed overrides on top of
loaded rules. Apply world_state overlay on top of `world/state.json`.

Variants are PURELY ADDITIVE — they can override numeric values but
cannot change rule structure or add new rules. New rules belong in
`game/goals.json`.

### Localization layer

Optional `ui/strings.json`:
```jsonc
{
  "hud": {
    "level_label": "📚 Level {}",
    "moves_label": "moves: {}",
    "win_message": "🌟 ALL LEVELS CLEARED 🌟"
  }
}
```

HUD elements use `@key.subkey` syntax instead of literal strings:
```jsonc
{"type": "label", "binds": "world.current_level", "format": "@hud.level_label"}
```

GameShell substitutes at render time. Without strings.json, the
literal `@key.subkey` text falls through (visible debug output —
indicates missing localization). Default load only English; future
loads `ui/strings.<lang>.json` based on locale config.

### Per-level game rules

`levels/<name>/rules.json` carries level-specific game logic
(typically clear conditions). World physics rules stay global.
Example for sokoban level 5 (push-order constraints):
- Global: walks/walls/pushes (world/rules.json)
- Per-level: "level 5 is cleared when ALL three goals covered" (levels/5/rules.json)

Engine appends per-level rules at level-load (already does this for
the current `levels/<name>/world_rules.json` path; rename to
`rules.json`).

## Consequences

**Enables:**

- **Reusable worlds**: same `world/rules.json` hosts multiple games
  via different `game/goals.json`. Yume's "engine claim" becomes
  literal — a Yume "engine" is a world; games run on top.
- **Audio palette swap** without touching rules.
- **Difficulty modes** with one overlay file.
- **Cleaner LLM authoring**: each skill owns one focused layer.
  yume-content-designer becomes 3-4 focused skills.
- **Localization** without rule changes.
- **HUD becomes pure display** — no game logic in widgets.

**Costs:**

- **Migration**: 10+ existing demos need restructuring. ~1 hour each
  if done carefully. Total ~10-12 hours.
- **Engine loader**: must load multiple rule files instead of one,
  apply variant overlays, intercept audio cues, substitute strings.
  ~6-8 hours of engine work + tests.
- **Backward compat**: engine supports BOTH old layout (loaded as-is)
  and new layout, during the transition. Migration is opt-in
  per-demo. Older demos keep working until touched.
- **More files** = more conventions to remember. Mitigated by clear
  ownership per layer.
- **Drawing the line** is sometimes ambiguous. Examples:
  - "monster.hp ≤ 0 → spark + remove" — clearly world (physics).
  - "monster removed → score += 1" — clearly game (metagame).
  - "monster.hp ≤ 0 → spark + score+1 + remove" (current monolithic
    rule) — needs splitting.
  - "set time_of_day = sin(world.tick * 0.01)" — world.
  - "boss_killed → flash 'YOU WIN'" — game.
  - Most cases will split cleanly with one judgment call.

**Backward compatibility**:

- Engine load path: try new layout (`world/rules.json` etc.); fall
  back to old (`world_rules.json`) if missing. Per-demo migration is
  opt-in. Old demos keep working until someone migrates them.
- Old single-file `inputs.json` continues to load. New `ui/input.json`
  is the new path.
- `scene.json` at root continues to work. `render/scene.json` is the
  new path.
- Rule loader: if `world/rules.json` exists, use new path; else
  fall back to `world_rules.json`. Same for game rules / flow / etc.
- Audio cue indirection is opt-in (rules can still emit `play_sound`
  with concrete sound names for legacy / non-cue cases).
- Variants are opt-in.
- Strings are opt-in (literal HUD text still works).

**Updates needed**:

- `godot/scripts/engine/world.gd` — multi-
  file loader; variant overlay; new path resolution
- `godot/scripts/engine/game_shell.gd` —
  audio_cue interception; string substitution
- `docs/guideline/30_framework_primitives.md` — document the new layout
- `.claude/rules/data-demo.md` — schema rules updated
- New skills: `yume-game-rules-designer`, `yume-flow-designer`
- Existing skills updated: `yume-content-designer` (narrowed scope),
  `yume-systems-designer` (scope to world physics), `yume-asset-designer`
  (now also owns audio cues)

## Implementation phasing

**Phase 1**: this ADR + tech-director review. (~1-2h)

**Phase 2**: engine loader supports new layout WITH backward compat
for old. Migrate `demo_sokoban` to new layout (smallest, recently
authored, attached to current author). Validate end-to-end. (~3-4h)

**Phase 3+**: migrate other demos opportunistically — when a demo is
touched for any reason, migrate it as part of the change. Don't
force a big-bang migration. (~10h spread over weeks)

**Phase 4**: skills updates. Existing `yume-content-designer`
narrows scope; new `yume-game-rules-designer` and `yume-flow-designer`
skills. (~3-4h)

**Phase 5**: deprecation warning. Once all in-tree demos migrate,
engine emits warning when loading old layout (still works). (~1h)

**Phase 5b**: deprecation sunset (per tech-director condition 2). After
a grace period (1-2 ADR cycles, ~1 month), engine removes old-layout
loader entirely. Remaining old-layout demos error at load with a
helpful migration message. (~1-2h)

Total: ~25-30 focused hours over multiple weeks.

The sunset is planned at proposal time (not deferred) to prevent
indefinite carry of two loader paths. Backward compat is a transition
mechanism, not a permanent feature.

## Alternatives considered

### A. Status quo — keep `world_rules.json` as-is

Rejected: the seam is real and visible. Every new game forces another
"is this a world rule or a game rule?" judgment in a single file.
The HUD's win/lose mixing is also not getting fixer.

### B. Inline split via comments / sections within `world_rules.json`

Add `_section` markers ("=== WORLD ===" / "=== GAME ===") inside the
single file. Rejected: doesn't actually buy the layer separation. The
file is still one file; one skill still owns it; reuse is still
prevented.

### C. Per-rule `layer` field on each rule

Each rule declares `"layer": "world"` or `"layer": "game"`. Rejected:
shifts the burden onto rule-level metadata. Doesn't separate audio
cues / variants / strings. Half-measure.

### D. Mega-refactor: also split entities into world/game vocabulary

Some entities are clearly world (walls, plants, monsters). Some are
arguably game-only (score_widget, level_clock). Could split entities
by layer. Rejected for v1: too much migration cost; low payoff.
Entity defs are stable; rules are where the action is.

### E. JSON5 / TOML for the new files

Comments via `_comment` work fine in JSON; TOML would make migration
harder. Stick with JSON.

## Open questions for tech-director review

1. **Backward compat strategy**: should engine support BOTH old and new
   layouts long-term, or force migration after a deprecation window?
   Lean: backward-compat indefinitely; old layout valid; new layout
   is "recommended." Migration is per-demo as it's touched. Simple.

2. **Audio cue layer placement**: should it be intercepted in
   GameShell (current proposal) or in EffectApply itself? Lean:
   GameShell — keeps the engine generic; audio is shell concern.

3. **Variant selection mechanism**: command-line flag, scene.json
   field, or env var? Lean: scene.json field (`"active_variant":
   "easy"`) — content-authorable; falls back to no-variant.

4. **Level rules merge semantics**: when `levels/<x>/rules.json`
   defines a rule with the same id as `game/goals.json`, does
   per-level OVERRIDE or APPEND? Lean: override. Simpler mental
   model. If you want both, use distinct ids.

5. **Skills migration**: should `yume-content-designer` keep
   ownership of `entities/` + `levels/<x>/entities.json` (initial
   placements) while ceding rule-writing to specialists? Lean: yes —
   content-designer becomes the entity-and-placement specialist;
   game-rules-designer + systems-designer split rules.

6. **Empty-layer convention**: a sandbox sim (no game) would have no
   `game/goals.json`. Engine treats absence as "no game logic" —
   sandbox mode. Same for absent `audio/cues.json` (rules use
   concrete sound names) and `variants/` (no overlay). All optional.
   Lean: yes — every layer except `world/rules.json` and
   `entities/` is optional.

7. **Existing 0006 multi-level pattern**: this ADR's `game/flow.json`
   replaces `progression.json`. ADR 0006 stays in spirit — just
   renamed file. Lean: rename for consistency with new layout.

8. **`render/scene.json` vs `scene.json` at root**: is the directory
   move worth the migration cost vs leaving it at root? Lean: move
   for consistency — every layer in its own directory. Aesthetic
   preference, low impact.

## Notes

This is a structural refactor, not a new primitive. The engine's
seven primitives (Entity, Tag, Rule, Trigger, Effect, Query,
Relation) are unchanged. What changes is HOW content is organized
into JSON files.

Same flavor as ADR 0006 (multi-level architecture) — JSON layout
expansion + small engine code change for new file resolution. Not
the same flavor as ADR 0004 (blocks_motion) or ADR 0005 (raycast_hit)
which added new primitive vocabulary.

---

## Tech-director review

_Date: 2026-05-05_
_Reviewer: yume-tech-director_
_Verdict: **accept with conditions**_

### Invariant checks

All four invariant greps pass on the current engine. The proposal
does NOT introduce any new violations:

| Invariant | Verdict | Notes |
|---|---|---|
| #1 (JSON-only content channel) | ✓ PASS | All new layers stay JSON. No engine code carries game logic. |
| #2 (no semantic effect types) | ✓ PASS *with note* | See "audio cue scrutiny" below. |
| #3 (no entity subclasses) | ✓ PASS | Untouched. |
| #5 (queries first-class) | ✓ PASS | Untouched. |
| #8 (engine = primitives + interpreter) | ✓ PASS | Engine adds INTERPRETERS (file loader, variant merger, string substituter, cue resolver). Each is generic; none encode genre semantics. |

This is structural-refactor-shaped, not primitive-expansion-shaped.
Same risk profile as ADR 0006.

### Specific scrutiny points

**1. Audio cue mechanism — does `audio_cue` shell event violate "no
semantic effect types"?**

No, but the design choice could be tighter.

Current proposal: rules emit `{event: "audio_cue", name: "monster_died"}`
as a NEW shell event distinct from existing `play_sound`. The cue
lookup is generic — engine doesn't know what `monster_died` means;
content-defined cue table maps the name to a concrete sound.

This is invariant-compliant: `audio_cue` is a generic event-routing
mechanism (like signal_emit + signal handlers), and the cue table is
data. Engine stays generic.

**However** — introducing a parallel shell-event type (`audio_cue`
alongside existing `play_sound`) creates two paths for the same
fundamental concern (rules want to play sounds). The proposed
localization layer uses `@key.subkey` syntax for string indirection;
audio could use the same pattern:

```jsonc
// Rules emit existing play_sound, but with a cue reference:
{"type": "emit_shell_event", "event": "play_sound", "name": "@cues.monster_died"}
```

GameShell already handles `play_sound`. Adding `@`-prefix resolution
in GameShell unifies audio + localization under one indirection
syntax. **REVISION REQUEST 1**: unify audio cues with the @-prefix
mechanism instead of adding a parallel `audio_cue` shell event.
Cleaner, fewer concepts, consistent with localization.

**2. Variant overlay — generic or game-specific semantics?**

Generic. ✓

Variants are keyed by rule-id with field overrides. Engine performs
deep-merge by dotted path. Engine doesn't know what `outer_imp_spawn`
means or what `effect.value` is — just walks the path and assigns.
Content-defined; engine generic. No semantic baking.

The merge syntax (dotted path keys) is new but it's a CONTENT-author
convention, not a primitive. Same pattern Yume already uses in
formula context (`self.state.position.x`).

**3. Backward compat — indefinite vs sunset?**

The ADR leans "indefinite" support of the old layout. **REVISION
REQUEST 2**: prefer SUNSET. Specifically:
- Phase 2 lands: engine supports both layouts. Old works without
  warning.
- Phase 3+ lands as demos migrate. After ALL in-tree demos use the
  new layout, engine emits a deprecation warning when loading
  old-layout files (but still works).
- After a grace period (1-2 ADR cycles, ~1 month), engine drops
  old-layout support entirely. Old-layout `world_rules.json` simply
  doesn't get loaded.

Indefinite backward compat accumulates dead code paths in the engine
loader. Two paths to load rules → harder to reason about loader
correctness → drift over time. The whole point of this refactor is
clarity; backward compat that survives the refactor undoes the
clarity gain. Plan the sunset at proposal time so it's not a
later debate.

**4. Skills migration — natural specialization or scope creep?**

Mixed. Splitting yume-content-designer into:
- yume-content-designer (entities + placements only)
- yume-game-rules-designer (game/goals.json)
- yume-flow-designer (game/flow.json)
- yume-systems-designer (existing; rescoped to world/rules.json)
- yume-asset-designer (existing; now also owns audio/cues.json)

The first three (content-designer rescope + game-rules-designer)
are clear specialization. yume-flow-designer as a SEPARATE skill is
premature — game/flow.json is small (level sequence + transitions)
and one skill can reasonably own all of `game/`.

**REVISION REQUEST 3**: merge yume-flow-designer into
yume-game-rules-designer initially. Both own `game/` subfolder. If
flow content grows into substantial cutscene/narrative authoring
(unlikely until a narrative-heavy game), THEN split. Don't pre-split.

This reduces skill-maintenance overhead from 4 new skills to 3.

### Open questions resolutions

| # | Question | ADR lean | Tech-director resolution |
|---|---|---|---|
| 1 | Backward compat indefinite or sunset? | Indefinite | **SUNSET.** See revision request 2. |
| 2 | Audio cue in GameShell? | GameShell | **Accepted.** Engine stays generic. |
| 3 | Variant selection via scene.json? | scene.json field | **Accepted.** Content-authorable. |
| 4 | Level rules merge semantics — override or append? | Override | **Override accepted.** Simpler mental model; if append needed, use distinct rule ids. |
| 5 | Skills specialization | Yes, split | **Modified.** Split content-designer + game-rules-designer; do NOT pre-split flow-designer. See revision request 3. |
| 6 | Empty-layer convention (everything except entities + world physics is optional) | Yes | **Accepted.** Sandbox sims have no game/, audio cues are opt-in, variants opt-in. |
| 7 | progression.json → game/flow.json rename | Yes | **Accepted.** Consistency win. |
| 8 | scene.json → render/scene.json | Yes | **Accepted with note.** Move for consistency. Migration pain is small (one file path). |

### Conditions for acceptance

Three revision requests applied to ADR text before Phase 2 starts:

1. **Unify audio cues with localization @-prefix mechanism.** Replace
   the parallel `audio_cue` shell event with `@`-prefix resolution
   inside the existing `play_sound` event. Same pattern as
   `@hud.level_label` for strings.

2. **Plan the deprecation sunset for old layout.** Add explicit Phase
   5b/6 to the implementation phasing: emit deprecation warning when
   all in-tree demos have migrated, drop old-layout loader entirely
   after a grace period.

3. **Don't pre-split yume-flow-designer.** Have yume-game-rules-
   designer own all of `game/` (rules + flow). Split only if flow
   content grows substantial (cutscenes, dialog graphs).

### Implementation gates (verify post-migration)

1. **All four invariant greps pass post-implementation.** Same greps
   I ran here. Re-run after Phase 2 lands and after each subsequent
   migration phase.
2. **Existing test_main.tscn continues to pass.** No regressions on
   the 236 unit tests.
3. **All existing demos load + tick cleanly.** Backward compat must
   work for un-migrated demos. Smoke test each demo headless after
   each engine change.
4. **Migrated demos pass their scenario tests.** Sokoban v0.4 (after
   Phase 2 migration) must pass all 12 current scenarios; doomarena3d
   v3.1 (after eventual migration) must pass its 41.

### Reasoning summary

The ADR's core claim — that `world_rules.json` mixes two distinct
concerns and the seam is real — is correct. The proposed split aligns
with Yume's stated principle that "engine is generic, content is in
JSON." The new file layout makes the LLM-authoring path cleaner
(focused skills per layer) and unlocks reuse (swap `game/goals.json`
to host different game-modes in the same world).

The audio cue, variants, and localization additions are all small
generic mechanisms that fit naturally in the new layout. None
introduce semantic effect types or entity-class hierarchy.

The three revision requests are tightening — none reject the
proposal's direction. With them applied, the design is clean and
implementation can proceed.

**Approved to start Phase 2 once revision requests 1-3 are applied.**
**Phase 5b deprecation sunset must be added to phasing before Phase 5
starts.**

ADR status updated: `accepted with conditions`.

---

## Revision 2026-05-16 — collapse game/goals.json + directory split

_Status update: **revised** per task #110 (Change A) + task #109
(Change B)._

### What changed

The world/game split as originally specified (world/rules.json vs
game/goals.json) was implemented 2026-05-05 and shipped on all
subsequent demos. After live use, the boundary proved fuzzy in
practice — game/goals.json became a catch-all for "non-physics
rules" rather than the originally-intended "goal declarations."
Aldenmere's goals.json shipped with 14 rules, only 2 of which were
actual win/lose declarations; the rest were boot latches, day-
boundary transitions, objective HUD text updates, and tutorial
overlays.

The user's empirical observation (2026-05-16): the split adds
authoring friction without paying off in reuse. Same-world /
different-goals never actually happened in any shipped demo —
each game has its own world and goals together.

### The revised layout

- **`world/rules/*.json`** — DIRECTORY of feature-module rule files.
  Engine globs `*.json` alpha-sorted and concatenates their `rules`
  arrays. Single-file `world/rules.json` still works for small games
  (chess, sokoban) — directory form is opt-in by presence of the dir.
- **`world/state.json`** — initial world_state values (unchanged).
- **`game/flow.json`** — multi-level progression (unchanged).
- **`game/goals.json`** — **REMOVED**. Its content moves to
  `world/rules/13_transitions.json` (boot / day-boundary / win-lose
  rules) + `world/rules/14_objectives.json` (HUD-text + tutorial
  overlays). Declarative win/lose lives in `hud.json` win:/lose:
  blocks as before.
- **`tutorial.json`** — unchanged at root (per-game one-shot
  overlay sequencing).

### Why collapse, not just split

Reuse-by-swap-goals never materialized. Keeping a separate
goals.json file imposes:

- A skill split (yume-game-rules-designer vs yume-systems-designer)
  that has to make ambiguous calls on every new rule.
- A second file the author must open + cross-reference.
- A loader pass for content that 90% of games could put in their
  world chain modules.

The win/lose DETECTION is already declarative — `hud.json` carries
`win: {binds, op, value, message, screen}` blocks that the engine
reads at load and wires to a per-frame HUD evaluator. The
transition-to-ending rule (`win_day3_survived` etc.) is just one
signal-rule per condition and fits naturally in a transitions
chain module.

### Migration

- **demo_aldenmere**: migrated 2026-05-16 (#110). goals.json deleted;
  rules split across world/rules/13_transitions + 14_objectives.
- **Other demos**: still using single-file `world/rules.json` +
  `game/goals.json`. They continue to work — the engine accepts
  both layouts. Migrate them lazily, only when next touching them
  for unrelated work.

### Engine support

`WorldLoader.load_rules_files_for(path, append)` checks `<path
without .json>/` directory first, falls back to single file.
Wired into `world_boot._load_content` +
`level_transition_coordinator`. Old games keep working without
code change.

### Skill implications

- **yume-systems-designer**: scope grows to include scoring +
  transitions + objectives + tutorials. Effectively absorbs
  yume-game-rules-designer's prior scope.
- **yume-game-rules-designer**: scope shrinks to declarative
  win:/lose: block authoring in hud.json + transition-rule design.
  Could merge into yume-systems-designer; deferred for now (skill
  prompts unchanged this revision).

### Validation

- 875/0 unit tests stay green.
- 19/19 aldenmere scenarios stay green.
- Live boot capture shows objective "Find food before nightfall."
  + HUD layout + inventory strip exactly as before (zero behavioral
  regression).
- `tools/validate_rules.py` mirrors the new directory-or-file
  detection — same 8 production violations reported under new
  file paths.

### Status

`revised` (supersedes the original "split world from game"
granularity within the same ADR scope). The principle holds —
different concerns live in different files — but the granularity
moves from "world vs game" to "feature module within world."
Game-only rules either live declaratively in HUD or as one
signal-rule in transitions.json.
