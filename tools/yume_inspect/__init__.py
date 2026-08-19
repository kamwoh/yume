"""tools.yume_inspect — make Yume's invisible coupling visible.

    python3 -m tools.yume_inspect <game> [-o out.html]

WHY THIS EXISTS
---------------
Yume is a rule system over shared mutable state, so rules are not connected to
each other by edges the author draws. They are connected by two things that
appear NOWHERE in the JSON as a relationship:

  * a SIGNAL name, written in one rule's `emit` and read in another's trigger
  * a STATE FIELD, written by one rule's effect and read by another's query,
    another's formula, or a screen's binding

Both couplings are real, load-bearing, and invisible. Every defect in the
2026-08 build sessions was a broken edge in that graph, not faulty logic:

  | symptom                        | broken edge                              |
  | flat `emit` payload            | signal fired with no readable consumer   |
  | rule never fired               | `require` named a binding its trigger    |
  |                                | does not populate                        |
  | 16 walls faced the wrong way   | wrote `state.facing`, renderer reads yaw |
  | whole career ladder inert      | `target=world` wrote a key with no reader|
  | player vanished on a delve     | `persistent_tags` had no reader          |
  | a cleared floor paid 0 coin    | return payload unreadable by the caller  |

The 33 validators already compute slices of this graph — they just compress the
answer to pass/fail. This tool renders the graph itself, so a human can see the
shape instead of being told a boolean. It is READ-ONLY and derives everything
from the same files the engine loads; there is no second source of truth to
drift.

Deliberately NOT an authoring canvas. Execution order in Yume comes from the
phase scheduler plus `before`/`after`, not from drawn wires, so a node canvas
would either misrepresent the semantics or reimplement the scheduler.
"""
