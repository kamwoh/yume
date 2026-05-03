# Sokoban — design review (round 4)

_Date: 2026-05-03_
_Reviewer: yume-game-reviewer (12-axis)_
_GDD: docs/games/sokoban/GDD.md_

## Verdict
**accept** (with 2 minor housekeeping notes — not blockers)

Round 3 surfaced 8 substantive issues across axes 3, 5, 7, 8, 9, 10,
11, 12. Round-4 GDD addresses all 8. At the now-honestly-scoped demo
level, this GDD is ready to ship.

## Per-axis findings (round 4)

| Axis | Verdict | Notes |
|---|---|---|
| 1. Mechanical depth | ✓ PASS | Push canonical for puzzle |
| 2. Strategic depth | ✓ PASS | Per-move decisions; lock-out tension (mitigated by undo) |
| 3. Pacing | ✓ PASS | Named beats: Onboarding → Hook → Breather → Climb → Climax → Finale |
| 4. Feedback | ✓ PASS | Audio cues + HUD specified |
| 5. Aesthetic match | ✓ PASS | Submission + Light Challenge — Discovery dropped honestly |
| 6. Scope honesty | ✓ PASS | Demo framing; engine cadence flagged |
| 7. Adversarial pokes | ✓ PASS | Undo prevents irreversible commits; level save persists across sessions |
| 8. Content scope | ✓ PASS | "8-level demo" honestly framed; aesthetic claims match scope |
| 9. Signature moments | ✓ PASS | 3 named: "The Hallway" (L3), "The Diamond" (L7), "Vault Doors" (L8) |
| 10. Theme / identity | ✓ PASS | "The Archive Vault" — quiet sorter, parchment + oak + brass, library hush |
| 11. Replay value | ✓ PASS | Par-move scoring with bronze/silver/gold medals; gold-perfect chase |
| 12. Real-UX | ✓ PASS | Undo (16-deep), session save, onboarding HUD, par-counter implicit stuck signal |

All 12 axes meet bar.

## Housekeeping notes (not blockers)

These are stale text that contradicts round-3 revisions; not design
gaps. Designer can clean up in a follow-up edit; pipeline can
proceed.

1. **Stale "Honest scope" section** (lines 268-282): still says
   "Undo (would need state history)" as out-of-scope. Round 3
   promoted undo TO scope. Should be removed or updated. Not
   blocking — the player verbs section + stuck-state UX section
   correctly describe undo.

2. **Stale "Aesthetic-mechanic match validation" section**
   (lines 300-310): still lists "Discovery" as a passing aesthetic.
   Round 3 dropped Discovery. Should be removed or updated. Not
   blocking — the new aesthetic table at top (line 26-31) is
   authoritative.

These are simple text deletions. Designer can apply in 1 minute.
Optional — pipeline doesn't need to halt.

## Reasoning summary

Round 4 represents a real iteration cycle: round-1 caught 3 surface
gaps, round-2 (under old 7-axis lens) accepted too easily, round-3
(under new 12-axis lens) caught 8 substantive deeper gaps, and
round-4 verifies the revisions. The GDD is now:

- **Honestly scoped** as an 8-level demo (~20 min) rather than
  pretending to be a "real" puzzle game.
- **Themed** ("Archive Vault" with concrete fictional context).
- **Memorable** (3 named signature levels with "wow" hooks).
- **Forgiving** (undo + restart + level save).
- **Replayable** (par-move medals).
- **Onboarded** (persistent HUD key-binding cue).

This is shippable. The reviewer-revise cycle worked exactly as
intended: caught real depth gaps in text-only iteration, pushed back
twice when the design was thin or dishonest, accepted when the design
matched its claims.

**Pipeline can proceed** to level-designer (which already produced
8 layouts; may need updates for new signature levels + par counts +
undo-affecting layout choices) → systems-designer → content-designer.

## What this validates about the reviewer skill

The 4-round arc demonstrates the skill works:
- Round 1: caught 3 obvious format gaps. Designer fixed.
- Round 2: accepted on format compliance — TOO LENIENT. (Bug in old
  reviewer.)
- Skill expanded from 7 → 12 axes per user feedback "needs to be
  harsh."
- Round 3: caught 8 deeper design gaps with the new lens. Designer
  did real design work to fix.
- Round 4: verifies all 8 revisions land; surfaces only minor
  housekeeping; accepts.

This is what a real reviewer-revise cycle looks like. Total time:
minutes per round, all in text. Compare to TowerDef3D, where these
exact issues (audio, content scope, signature moments, theme) were
discovered post-build through hours of manual playtesting + iteration.

The expanded reviewer is now appropriately harsh — not for harshness'
sake, but because the depth axes ARE the difference between a tech
demo and a game.
