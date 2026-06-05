# Text-to-Game Pipeline — CCGS Analysis + Tier 2.5 Plan

_Session: 2026-04-23_

## Context

Mid-W1, during runtime-engine build, the user raised two strategic points:

1. **Side-quest**: read `/mnt/c/Users/kamwoh/Documents/Projects/Personal/Claude-Code-Game-Studios`
   (CCGS). User worried it might be "much better than Yume because we're not
   experienced game developers."
2. **Goal clarification**: "eventually our goal is to make Yume able to create
   any game we want with any different rules and physics, all just through
   text description."

This doc captures what we found, what it means for Yume's direction, and the
new Tier 2.5 ("Pipeline") that lands between runtime and actors.

---

## CCGS — what it actually is

A **Claude Code configuration template** that turns a single Claude session
into a simulated game studio. Ships:

- 49 subagents (Director/Lead/Specialist hierarchy, Opus/Sonnet/Haiku tiered)
- 72 slash-command skills (SKILL.md files)
- 12 hooks, 11 path-scoped rules
- 39 document templates (GDD, ADR, UX spec, art bible, post-mortem)
- **Zero runtime code.** No engine. No executable game.

Load-bearing patterns (patterns a junior dev would actually use daily):

1. **"Question → Options → Decision → Draft → Approval"** — every agent asks
   permission before writing files. Collaboration, not autonomy.
2. **Path-scoped rules** — editing `src/gameplay/**` auto-attaches rules
   forbidding hardcoded values and requiring delta-time. Per-dir standards.
3. **ADR-driven implementation** — `/dev-story` refuses to generate code
   until TR-registry + governing ADR + control manifest exist.
4. **TR registry** (`docs/architecture/tr-registry.yaml`) — single source of
   truth for requirements; stories reference TR-IDs rather than inlining text.
5. **Manifest version pinning** — stories embed the manifest version they
   were written against; drift detection forces a user decision.
6. **7-phase pipeline** — Concept → Systems-Design → Technical-Setup →
   Pre-Production → Production → Polish → Release, each with artifact gates.
7. **Engine version safety** — `docs/engine-reference/godot/{VERSION.md,
   deprecated-apis.md, breaking-changes.md, current-best-practices.md}`
   pins API knowledge. Agents must read before proposing APIs.
8. **Session state machinery** — `production/session-state/active.md`
   continuously written by skills; pre/post-compact hooks preserve progress.
9. **Data-driven gameplay rule** — *"ALL gameplay values MUST come from
   external config/data files, NEVER hardcoded."* This is the rule Yume
   most closely echoes.
10. **Skill self-testing framework** — each skill has a behavioral spec
    tested via `/skill-test static|spec|category`.

---

## Initial comparison — they're adjacent, not competing

| | CCGS | Yume |
|---|---|---|
| **Nature** | Process/orchestration layer | Runtime simulation engine |
| **Output** | Documents, structure, gates | Running simulation in Godot |
| **Sits in** | `.claude/` folder | `src/` folder |
| **Without it** | You could build a game ad-hoc | You have no engine |

**The user's worry was misplaced.** CCGS doesn't make you a better game
developer; it makes you a better-organized one. You still need a runtime.
**Yume *is* that runtime.** Dropping Yume for CCGS = keeping the blueprints,
losing the building.

---

## The reframe — text-to-game needs both

Once the user clarified the goal as **"text description → any simulation-shaped
game"**, CCGS became much more relevant. Text-to-game needs three layers:

```
1. DESIGN LAYER   "farming with moonlight-growing crops" → structured GDD
2. SPEC LAYER     GDD → entity defs, rule specs (ADR-tracked)
3. RUNTIME LAYER  entity defs + rules → running simulation   ← Yume today
```

CCGS's entire `.claude/` infrastructure is layers 1–2. We have layer 3.
Without 1–2, Claude has to hallucinate the intermediate spec from prose, and
any drift cascades into broken JSON. The 7 primitives are load-bearing —
they demand a structured intermediate representation, not freeform
prose-to-JSON.

---

## What to borrow from CCGS (ranked impact/effort)

| Pattern | Why load-bearing for text-to-game |
|---|---|
| **GDD-first pipeline** (`/dev-story` style) | Enforces "no JSON without a spec first." Kills the failure mode where Claude emits a pile of entities.json that sort-of-works. |
| **ADR + TR-registry** | Users iterate across sessions. ADR traces each decision. TR-IDs let rules.json reference requirements, so regeneration doesn't lose reasoning. *Critical* because Yume's 7 primitives demand a paper trail when design changes. |
| **MDA framework doc** | Principled vocabulary: Mechanics = Yume's rules. Dynamics = emergent behavior. Aesthetics = player experience. Structures how design agents decompose prose. |
| **Specialist agents (TRIMMED to 5–6)** | Text-to-game is multi-perspective. One agent producing everything makes weak designs. But 49 is overkill — lean version: `game-designer` / `systems-designer` / `content-designer` / `qa-tester` / `tech-director`. |
| **Path-scoped rules** | `src/engine/**` → "no semantic effect types, no genre-specific code." `data/demo_*/**` → "entities.json must validate against schema." Catches Claude's hallucinations automatically. |
| **Engine-reference pinning** | `docs/engine-reference/godot/VERSION.md`. Prevents pre-Godot-4 or deprecated APIs when generating scenes. |
| **Skill behavioral tests** | "Given prompt X, did `/yume create-game` produce valid entities.json that runs?" THE acid test for the whole pipeline. |
| **"Ask before write" protocol** | Kills the "Claude wrote 200 lines of the wrong thing" failure mode. Baked into builder/designer/tester agents. |

## What NOT to borrow

- **49-agent studio hierarchy.** Yume's lean 3-agent model already matches its
  scope. Bloating to 49 would obscure runtime-engine identity. CCGS solves a
  team-coordination problem Yume doesn't have.
- **7-phase full workflow pipeline.** Appropriate for a full studio simulation,
  overkill for a runtime engine. A 3-phase design/spec/runtime pipeline is
  sufficient.

---

## Honest scope — what "any game via text" really means

**"Any game we want with any rules and physics"** has real limits:

- **Physics.** Yume's "physics" is discrete-tick + rule-based. Not Box2D.
  Not fluid simulation. A drift-racing car or soft-body destruction game is
  out. Non-goals per the primitives contract: rhythm / twitch timing,
  continuous physics simulation.
- **Genre coverage.** 7 primitives cover **simulation-shaped** games:
  ecology, farming, shooter, RPG, survival, strategy, tower defense, chess,
  roguelike, puzzle-with-state. They do NOT cover (without extension):
  visual novels, rhythm games, precision-platformer physics, narrative-heavy
  adventures.
- **"Any rules" is true.** Rules are JSON; user can invent "moonlight
  accelerates growth near water" trivially. This part of the goal is real.

**Honest achievable version:** _"Any simulation-shaped game, any data-driven
rules, discrete-tick physics, text-described in natural language."_ Still
extraordinarily ambitious.

---

## Tier 2.5 — PIPELINE (new)

Runs between Tier 2 (runtime, current) and Tier 3 (actors). Adopts trimmed
CCGS patterns to make text-to-game achievable.

### Deliverables

1. **Path-scoped rules** — `.claude/rules/*.md` per directory, enforcing
   Yume's invariants:
   - `.claude/rules/engine-scripts.md` — no semantic effects, no genre
     assumptions, data-driven mandate
   - `.claude/rules/data-demo.md` — entities.json must validate against
     schema; formulas whitelisted
   - `.claude/rules/docs.md` — primitive changes require ADR

2. **Engine reference pinning** — `docs/engine-reference/godot/`:
   - `VERSION.md` — Godot 4.6.1 pinned
   - `deprecated-apis.md` — what NOT to emit
   - `current-best-practices.md` — GDScript idioms (typing, class_name, etc.)
   - `breaking-changes.md` — migration hazards

3. **ADR + TR-registry layer** —
   - `docs/adr/` — each primitive change or contract revision
   - `docs/architecture/tr-registry.yaml` — requirements tracked with TR-IDs
   - JSON comments reference `"_tr": "TR-042"` for traceability

4. **MDA framework doc** — `docs/guideline/32_mda_for_yume.md`. Translates MDA
   (Mechanics/Dynamics/Aesthetics) vocabulary into Yume terms:
   - Mechanics = Yume rules + entities
   - Dynamics = emergent behavior from rule composition
   - Aesthetics = what the player feels, experiences

5. **Slim specialist agent set** — `.claude/agents/yume/`:
   - `game-designer.md` — holistic; converts prose → GDD
   - `systems-designer.md` — rules, mechanics, balance
   - `content-designer.md` — entity defs, values, progression
   - `qa-tester.md` — validates generated JSON runs in Yume
   - `tech-director.md` — guards primitive invariants
   Replaces single-agent mode for text-to-game work.

6. **`/yume-design` skill** — the text-to-game pipeline entry point:
   - Accepts prose game description
   - `game-designer` produces GDD structured by MDA
   - `systems-designer` proposes rule sketches + ADRs
   - `content-designer` fills entities + values
   - `qa-tester` runs generated JSON against Yume, reports
   - Gates between phases, user approval required

7. **Skill behavioral tests** — `.claude/skills/*/test_spec.md`. Given a
   prose prompt, expected GDD shape / JSON structure / pass criteria.

8. **Collaboration protocol** — bake "Question → Options → Decision → Draft →
   Approval" into builder/designer/tester agent prompts. Prevents autonomous
   drift.

### Non-deliverables

- Don't build the 49-agent hierarchy.
- Don't build a 7-phase full production workflow; 3 phases (design, spec,
  runtime) is the right scope.
- Don't replicate CCGS's `production/` folder (sprints/milestones) — Yume
  isn't a project manager.

### Dependencies

- Blocked on Tier 2 exit (runtime primitives frozen). W1 must finish; W2–W6
  should complete before heavy Tier 2.5 work so the pipeline generates
  against a stable target.
- Some patterns are cheap enough to pull in early (path-scoped rules, engine
  reference) — these can land alongside W1.13 tests without disrupting the
  runtime track.

---

## Current state snapshot (as of discussion)

- **W1.1–W1.12** done. Runtime engine works end-to-end in Godot 4.6 headless.
  7 primitives + PhaseScheduler + World + WorldClock integrated; proof-of-life
  demo runs (tick increments growth state).
- **W1.13 parked** — unit tests not yet written. Resume either before or in
  parallel with Tier 2.5 depending on user preference.

---

## Decision taken

User chose **(1)** — finish W1 clean (W1.13 tests), then start Tier 2.5.
Saving this discussion was the immediate next step before continuing either
track.

---

## Pipeline expansion: authoring-time emitters (2026-05-17, ADR 0051)

The Tier 2.5 pipeline above describes the **prose → GDD → JSON**
path via /yume-design's specialist skills. As of 2026-05-17 there
are also two adjacent authoring channels that emit canonical JSON
+ asset files:

```
┌──────────────────────────────────────────────────────────┐
│  Authoring sources                                        │
├──────────────────────────────────────────────────────────┤
│  1. /yume-design pipeline   (prose → skills → JSON)       │
│  2. Hand-authored JSON       (direct editing)             │
│  3. tools/yume_codegen/      (Python typed builders)      │
│  4. tools/yume_assetgen/     (prompt → asset files)       │
└──────────────────────────────────────────────────────────┘
            │            │            │            │
            ▼            ▼            ▼            ▼
       data/<game>/*.json  +  data/<game>/assets/*.png/.glb
                      │
                      ▼
            tools/validate_*.py  ←  contract gate
                      │
                      ▼
                  Godot engine
```

The four sources are interchangeable — they emit the same canonical
JSON shape; the validator can't tell them apart. Mix freely per
authoring situation.

| Source | Best for |
|--------|----------|
| /yume-design | new games from a prose pitch |
| Hand-author | quick edits, one-off rules, short chains |
| yume_codegen | generating many similar rules, long effect chains, binding-name discipline |
| yume_assetgen | replacing flat-color primitives with per-entity textures + skinned meshes |

See ADR 0051 for the rationale + tooling docs (`tools/yume_codegen/README.md`,
`tools/yume_assetgen/README.md`).

---

## Reference

- CCGS repo: `/mnt/c/Users/kamwoh/Documents/Projects/Personal/Claude-Code-Game-Studios/`
- Key CCGS files:
  - `README.md`, `CLAUDE.md`, `UPGRADING.md`
  - `.claude/docs/agent-coordination-map.md`
  - `.claude/docs/workflow-catalog.yaml`
  - `.claude/rules/gameplay-code.md` (rules pattern template)
  - `.claude/skills/dev-story/SKILL.md` (ADR/TR enforcement pattern)
  - `.claude/skills/start/SKILL.md` (onboarding gold standard)
  - `CCGS Skill Testing Framework/README.md` (meta-QA pattern)
