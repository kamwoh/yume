# ADR 0012 — Tutorial overlay primitive

_Date: 2026-05-06_
_Status: **accept-with-conditions (TD review 2026-05-06; depends on ADR 0011 refactor)**_

## Context

Tutorials are universal in shipping games but currently impossible to
express in Yume cleanly. The closest existing path is "spawn a label
entity at startup, remove it after a tick" — which works for one-shot
hints but not for the typical sequence:

1. Welcome message → press any key to advance
2. Highlight player → press WASD to move → wait for movement
3. Highlight enemy → press space to attack → wait for kill
4. Highlight HUD score → wait 3 seconds → done

The hard parts are:

- **Pausing the world** while a hint is on screen
- **Highlighting** specific entities (visual emphasis)
- **Advance conditions** that wait for a player action
- **Sequencing** — step N+1 fires after step N completes
- **Skipping** — power users can opt out
- **Replay** — tutorials can be re-run from settings

A hardcoded tutorial system would be game-specific GDScript. Per
constraint: tutorials must be JSON.

## Decision

Add an **overlay primitive** to the engine: a generic "show this
message until this condition is met" mechanism. Tutorial steps become
just rules whose effect is `show_overlay`. Sequencing happens through
existing signal chaining. No tutorial-specific code in the engine.

### File layout

```
data/<game>/
├── tutorial.json          # tutorial steps as rules (or rules in game/rules.json)
└── ... (existing)
```

`tutorial.json` is OPTIONAL — its rules append to the scheduler same
way `world/physics.json` and `game/rules.json` do (per ADR 0009 multi-
file rule loader). Authoring convention: put tutorial rules in their
own file for clarity, but they're functionally just regular rules.

### New effect types

```jsonc
{"type": "show_overlay",
 "id": "tutorial_move",
 "title": "@strings.tutorial_move_title",
 "body": "@strings.tutorial_move_body",
 "highlight_tag": "player",
 "advance_action": "move_north",
 "advance_signal": null,
 "advance_after_seconds": null,
 "freeze_world": true,
 "skippable": true}

{"type": "dismiss_overlay", "id": "tutorial_move"}
```

**Overlay parameters:**

- `id` — unique identifier; used by `dismiss_overlay` to target this
  specific overlay
- `title` / `body` — text content (`@strings.X` references resolve
  per ADR 0009 Phase 2c)
- `highlight_tag` — optional. Engine renders a glow/circle around
  any entity matching this tag. Multiple tags = highlight all.
- `advance_action` — optional. The overlay auto-dismisses on this
  input action. Engine emits `overlay_advanced` signal with payload
  `{id: <overlay_id>, reason: "action"}`.
- `advance_signal` — optional. The overlay auto-dismisses when this
  named signal fires. Useful for "wait for player_killed_enemy".
- `advance_after_seconds` — optional. Auto-dismiss after N seconds.
  Useful for splash messages.
- `freeze_world` — default true. While shown, world tick is paused.
  Set false for "show this hint but let the game run."
- `skippable` — default true. If true, `escape` or `skip` action
  emits `overlay_advanced` with reason "skip".

### Tutorial sequence pattern

A tutorial is a chain of rules. Each step:

1. Triggered by entering a state (`world.tutorial_step == N`)
2. Emits `show_overlay` with appropriate `advance_*` config
3. The advance fires `overlay_advanced` signal
4. A second rule listens for `overlay_advanced{id: N}`, dismisses,
   and increments `tutorial_step`

Example (sokoban, abbreviated):

```jsonc
{
  "rules": [
    {
      "id": "tut_step_0_welcome",
      "trigger": {"type": "tick", "interval": 1},
      "query": {"tags_all": ["clock"], "state": {"tutorial_step": 0}},
      "effect": [
        {"type": "show_overlay",
         "id": "welcome",
         "title": "@strings.tut_welcome_title",
         "body": "@strings.tut_welcome_body",
         "advance_action": "ui_accept",
         "freeze_world": true},
        {"type": "state_set", "target": "self", "field": "tutorial_step", "value": 1}
      ]
    },
    {
      "id": "tut_step_1_move",
      "trigger": {"type": "signal", "name": "overlay_advanced"},
      "require": {"trigger_payload": {"id": "welcome"}},
      "effect": [
        {"type": "show_overlay",
         "id": "move_hint",
         "title": "@strings.tut_move_title",
         "body": "@strings.tut_move_body",
         "highlight_tag": "player",
         "advance_signal": "player_moved",
         "freeze_world": false}
      ]
    },
    {
      "id": "tut_step_1_done",
      "trigger": {"type": "signal", "name": "overlay_advanced"},
      "require": {"trigger_payload": {"id": "move_hint"}},
      "effect": [
        {"type": "state_add", "target": "level_clock", "field": "tutorial_step", "amount": 1}
      ]
    }
  ]
}
```

### Skip + replay

Skipping = a setting (`world.tutorial_enabled = 0`); rules in tutorial
file can include `"query": {"tags_all": ["clock"], "state":
{"tutorial_enabled": 1}}` so they're inert when off.

Replay = settings menu has a button: `{"on_click":
[{"type": "state_set", "target": "level_clock", "field": "tutorial_step", "value": 0}, {"type": "transition_screen", "target": "game"}]}`.
The tutorial chain re-fires from step 0.

### Engine work

1. `scripts/engine/overlay.gd` — new module managing the overlay
   stack. Handles:
   - Show: renders title + body + optional highlight + freezes world
     if requested
   - Dismiss: emits `overlay_advanced` signal with reason
   - Auto-advance on action / signal / timer
   - Stacking (multiple overlays can be shown; only top is
     interactive; freeze_world propagates from any in stack)

2. `effect_apply.gd` gains `show_overlay`, `dismiss_overlay`.

3. `game_shell.gd` extended to render overlays (above HUD, below
   screen-flow modals from ADR 0011).

4. Highlighting: renderer reads `world.highlighted_entity_ids` and
   draws a pulsing outline around each. Engine populates this list
   from active overlays' `highlight_tag` values.

5. Signal: engine emits `overlay_advanced` with payload
   `{id, reason}` (reason ∈ {"action", "signal", "timer", "skip",
   "manual"}).

### Backward compat

Existing demos work unchanged. Overlays are opt-in via the
`show_overlay` effect; if a game never emits one, no overlay UI is
shown.

## Consequences

**Enables:**
- Tutorial sequences as pure rules
- One-off hints ("Boss approaching!" with 3-second auto-dismiss)
- Modal dialogs ("Save complete" with manual dismiss)
- Highlighting for "where to go next" indicators
- Pause-during-hint vs hint-during-play (freeze_world flag)

**Constrains:**
- Overlay text styling is config-level only (no rich text, no inline
  images in v1). Most tutorials need plain text + maybe one image
  reference; sufficient.
- No automatic "step 3 of 8" indicator. Author can include it in the
  body text or as a separate label.
- No branching tutorials in v1 (you can't have step 2a vs 2b based
  on what the player did). Branches are just additional rules with
  different triggers; achievable but not first-class.

**Doesn't enable:**
- Voiceover during tutorials. Voice is an asset; emit a `play_sound`
  shell event alongside `show_overlay` if needed.
- Animated tutorials (cinematic camera moves, NPCs gesturing). Future
  cutscene primitive (separate ADR if/when needed).

## Alternatives considered

### A. Tutorial system in engine code

Reject: violates Invariant #1. Tutorials are content; engine ships
the primitive (overlay), content composes them.

### B. Use existing entity + label HUD config for tutorials

Could spawn "tutorial_message" entities and let them despawn after
N ticks. Works for one-shots; misses freeze_world, advance-on-action,
highlighting. Forced into awkward workarounds.

### C. Tutorial as a screen (per ADR 0011)

Could implement each step as a separate screen. Reject: the
"highlight while game continues" use case (freeze_world: false)
isn't natural in a screen architecture. Overlays are stack-based;
screens are slot-based. Different shapes.

### D. Mix of approaches (overlay for hints, screen for tutorial intro)

This is what we get for free. ADR 0011 ships screens; ADR 0012 ships
overlays. The author picks the right one per moment. Not really
"alternatives" — they coexist.

## References

- Invariant #1 (JSON-only content channel)
- ADR 0009 Phase 2c — `@strings.X` localized text references
- ADR 0011 — screens and overlays compose; pause screen is a screen,
  tutorial hint during play is an overlay
- Existing signal trigger system — overlay sequencing reuses it

## Tech-director review (2026-05-06, post-ADR-0021 framing)

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | tutorial.json is content |
| #2 No semantic effect types | ✓ | show_overlay / dismiss_overlay are mechanical |
| #5 Queries first-class | ✓ | highlight_tag uses tag query |
| #8 Engine = primitives + interpreter | ✓ | overlay primitive composes with Godot Control + ADR 0011 |
| #9 Phase ordering | ✓ | overlay show/dismiss buffer like other effects |

### Re-evaluation under ADR 0021

The OVERLAY mechanic (show modal text + advance condition) is
genuinely Yume-specific:
- The advance-condition state machine (action / signal / timer)
  is Yume's contribution
- Highlight-by-tag traversal is Yume-shape (uses entity dict +
  tag queries)
- Tutorial sequencing as rule chains is pure Yume-primitive
  composition

What it DOESN'T need to reimplement:
- Overlay rendering itself = Godot Control + CanvasLayer (same as
  ADR 0011's screen UI)
- Text rendering = Label
- Backdrop dim = ColorRect with semitransparent color
- Highlight visual = Sprite2D / shader-based outline (renderer-side,
  not engine-side)

### Required refactor (depends on ADR 0011 refactor)

The overlay's UI rendering should compose with ADR 0011's
"JSON-to-Godot-Control" pattern. Specifically:

- `show_overlay` effect creates a CanvasLayer + Control hierarchy
  from the overlay's title/body content (same engine helper as
  screens use)
- The advance-condition logic is engine code (state machine
  monitoring action/signal/timer)
- The highlight rendering uses existing renderer (renderer reads
  `world.highlighted_entity_ids`; renders outlines via shader or
  sprite)

If ADR 0011 lands as the Godot-Control-exposure capability, this
ADR's `show_overlay` is just "instantiate a tagged Control hierarchy
from this overlay config." Clean composition.

### Concerns

1. **Highlight visual style is hardcoded**. ADR mentions "engine
   pulses an outline." How? Shader? Sprite? Per ADR 0021 this
   should use Godot's `ShaderMaterial` or `Sprite2D` rather than
   custom rendering. Spec.

2. **Overlay stacking semantics**. Multiple overlays can be shown
   (e.g. story-cutscene overlay + tutorial overlay). Topmost handles
   input. Same as modal stack in ADR 0011 — refactor consistently.

3. **freeze_world: false case**. Overlay shown DURING gameplay
   (e.g. "press X to interact" hint while game continues). Engine
   must continue ticking; overlay just sits on top. Verify ADR 0011's
   modal stack supports this distinction.

4. **Multi-language support**. `@strings.X` references resolve at
   show-time. Godot's UI auto-handles this if Label.text is set via
   the resolved string. ✓ already in plan.

### Verdict

**Status: accept-with-conditions.**

Conditions:

1. **Depends on ADR 0011's refactor landing first** — overlay
   rendering reuses the JSON-to-Godot-Control mechanism.
2. **Spec highlight visual implementation** (recommend: ShaderMaterial
   on a Sprite2D positioned at entity world coords; pulse via Tween).
3. **Stack semantics consistent with ADR 0011's modal stack**.
4. **Test plan**: scenario tests for show/dismiss/advance/highlight.

The Yume-engine code IS justified here (advance-condition state
machine, sequencing logic). UI rendering uses Godot. Clean composition.

### Tier framing

T5 (gameplay experience / shell layer) — yes. Tutorials are
classic shell-layer onboarding UX.
