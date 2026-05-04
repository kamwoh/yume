# DoomArena3D — level design (v3.0 multi-chamber)

_Date: 2026-05-04_
_Designer: yume-level-designer_
_GDD: docs/games/doomarena3d/GDD.md (v3.0)_
_Supersedes: v2 (single-arena Foundry layout) — v3.0 wraps Foundry as the middle chamber and adds Outer (onboarding) and Core (boss-arena finale) per ADR 0006 multi-level architecture_

## Campaign overview

3 sequential containment chambers played in order via `progression.json`. Persistent player loadout (HP/ammo/score/weapon) carries between chambers; everything else (clock, walls, monsters, pickups) is destroyed and reloaded at each transition.

| Chamber | Bounds | Cover density | Beat | Clear |
|---|---|---|---|---|
| **Outer Containment** | 28×28m (±14) | Low (4 pillars) | Onboarding — learn movement + plasma | `player.score >= 5` |
| **The Foundry** *(signature)* | 44×44m (±22) | High (divider + 8 pillars + 4 machinery) | Tactical — full enemy mix, ranger pillar-flanking | `player.score >= 20` |
| **Core Containment** *(finale)* | 44×44m (±22) | Sparse (3 pillars only) | Climax — boss-rocket showdown | boss `hp <= 0` |

All chambers share: ground primitive Y-clamp at Y=0 (engine), 6m visual ceiling, first-person camera FOV 78° eye-height 1.6m, perimeter walls block_motion (ADR 0004), 3D-AABB bullet collision (bullets above wall height clear walls).

---

# Chamber 1 — Outer Containment

_28×28m onboarding arena. Imp-only spawns at 1.5s. Score=5 clears._

## Map dimensions

- World units: 28m × 28m (XZ), bounds ±14
- Spawn ring radius: 11m (just inside walls)
- Pickup spawn: ±11 in XZ
- Player start: (0, 0, 0)

## Spatial pattern rationale

**Single open chamber, symmetric quadrant cover**. The smallest of the three chambers — the player has nowhere to hide for long, learns the look-fire-pivot loop without geometric complexity getting in the way. Four pillars in a symmetric NE/NW/SE/SW pattern at ±5 give simple "circle the obstacle to avoid imp swarm" affordance — every pillar is a viable hiding spot, no zone-by-zone tactical depth yet (that's chamber 2's job).

Theme: outer perimeter of Containment Chamber 7 — first room past the airlock. Sparse so the player can scan all corners.

## Placements

### Perimeter walls (4)

28m wide each, AABB matches mesh exactly.

| Wall | Position | Mesh | Rationale |
|---|---|---|---|
| `wall_outer_n` | (0, 0, +14) | wall_panel_ns_28 | +Z bound |
| `wall_outer_s` | (0, 0, -14) | wall_panel_ns_28 | -Z bound |
| `wall_outer_e` | (+14, 0, 0) | wall_panel_ew_28 | +X bound |
| `wall_outer_w` | (-14, 0, 0) | wall_panel_ew_28 | -X bound |

### Pillars (4 — symmetric quadrants)

| Pillar | Position | Rationale |
|---|---|---|
| `pillar_outer_NE` | (+5, 0, +5) | NE quadrant — first cover the player encounters facing forward-right |
| `pillar_outer_NW` | (-5, 0, +5) | NW quadrant — mirrors NE |
| `pillar_outer_SE` | (+5, 0, -5) | SE quadrant — directly in front-right of player start (facing=0 = -Z) |
| `pillar_outer_SW` | (-5, 0, -5) | SW quadrant — directly front-left |

All pillars: 1m × 3m × 1m, blocks_motion + aabb_extents [0.5, 1.5, 0.5].

### Floor + clock

| Element | Position | Notes |
|---|---|---|
| `floor_outer` | (0, 0, 0) | Reuses universal floor_grate mesh (44×44 visual — extends past walls; player can't see the overshoot) |
| `clock_outer` | (0, 0, 0) | Per-chamber clock instance, invisible. Destroyed at transition; replaced by clock_foundry. |

## Pacing

- Imp travel time (radius 11, speed 3.5 m/s): ~3.1s spawn → player. Fast enough that player MUST move continuously.
- Time-to-clear estimate: 5 kills × ~2.5s/kill avg = 12-15s. Quick onboarding stage.
- Choke density: low (no choke points). Open arena.

## Validation against aesthetic

- **Challenge**: low. By design — chamber 1 is teaching mode, not stress test. Player learns aim + reload + pillar-circling without composition pressure.
- **Sensation**: full hits + sparks + screen-shake feedback applies the same as later chambers.
- **Submission**: short trance loop within the chamber — repetitive imp swarm, simple geometry. Player gets into the rhythm before chamber 2 raises stakes.

---

# Chamber 2 — The Foundry *(signature)*

_44×44m tactical arena with chamber divider. Full enemy mix at 2s/4s/6s. Score=20 clears._

This is the v2.6 layout from the prior level-design — preserved as the campaign's mid-game signature beat.

## Map dimensions

- World units: 44 m × 44 m (XZ), 6 m visual ceiling
- Visible bounds: ±22 m on X and Z (perimeter walls)
- Spawn ring radius: 18 m (just inside walls)
- Pickup spawn: ±18 in XZ (square spread, 36×36)
- Player start: persisted from prior chamber; engine doesn't reset position so player starts wherever they finished chamber 1

## Spatial pattern rationale

**Two-zone closed arena with chamber divider** (the signature pattern that drove v2.5 reviewer's "make geometry first-class" mandate). Partial interior wall at z=0 splits the arena into Forward Zone (z<0) and Back Zone (z>0), with passages on left/right (gaps at x∈[-6,+6] center + x∈[±14,±22] sides). 8 pillars clustered into front-row + back-row patterns per zone, plus 4 industrial machinery crates (1.5m³ box cover) per zone for theme reinforcement and additional cover density.

Containment Chamber 7 fiction supports the design: divider = "inner containment partition," forward zone = "incoming processing," back zone = "core containment." Industrial machinery = "ore-processing equipment" / "fallen pipework."

## Placements

### Perimeter walls (4)

| Wall | Position | Mesh | Rationale |
|---|---|---|---|
| `wall_foundry_n` | (0, 0, +22) | wall_panel_ns | +Z bound |
| `wall_foundry_s` | (0, 0, -22) | wall_panel_ns | -Z bound |
| `wall_foundry_e` | (+22, 0, 0) | wall_panel_ew | +X bound |
| `wall_foundry_w` | (-22, 0, 0) | wall_panel_ew | -X bound |

### Chamber divider (2 segments)

Partial wall at z=0 with 12m central gap (x ∈ [-6, +6]) + 8m-wide side passages (x ∈ [±14, ±22]). Three passage points: center + 2 side.

| Element | Position | Mesh | Rationale |
|---|---|---|---|
| `divider_foundry_w` | (-14, 0, 0) | wall_panel_short_ns | West half of divider |
| `divider_foundry_e` | (+14, 0, 0) | wall_panel_short_ns | East half of divider |

### Pillars (8 — 4 forward zone, 4 back zone)

Asymmetric within each zone so each pillar is recognizable.

| Pillar | Position | Zone | Rationale |
|---|---|---|---|
| `pillar_foundry_FL1` | (-9, 0, -6)   | Forward, left-mid | First cover walking forward-left from center |
| `pillar_foundry_FL2` | (-6, 0, -15)  | Forward, left-far | Far-left flanking lane |
| `pillar_foundry_FR1` | (+11, 0, -8)  | Forward, right-mid | Mirrors FL1, asymmetric depth |
| `pillar_foundry_FR2` | (+8, 0, -16)  | Forward, right-far | Mirrors FL2 |
| `pillar_foundry_BC1` | (-13, 0, +4)  | Back, near-divider west | First back-zone cover after divider |
| `pillar_foundry_BC2` | (+11, 0, +6)  | Back, near-divider east | Asymmetric counterpart to BC1 |
| `pillar_foundry_BL`  | (-6, 0, +13)  | Back, left | Frames back-left |
| `pillar_foundry_BR`  | (+8, 0, +15)  | Back, right | Frames back-right |

### Industrial machinery (4 — 2 forward, 2 back)

Larger cover pieces — thicker boxy form with rust + warning-stripe banding. 1.5m × 1.5m × 1.5m, blocks_motion.

| Element | Position | Zone | Rationale |
|---|---|---|---|
| `machinery_foundry_FL` | (-15, 0, -10) | Forward, far-west | West flank cover |
| `machinery_foundry_FR` | (+15, 0, -12) | Forward, far-east | East flank, offset Z for asymmetry |
| `machinery_foundry_BL` | (-15, 0, +10) | Back, far-west | Channels player to center for back-zone navigation |
| `machinery_foundry_BR` | (+13, 0, +12) | Back, far-east | Pairs with BL |

### Floor + clock

| Element | Position | Notes |
|---|---|---|
| `floor_foundry` | (0, 0, 0) | Reuses floor_grate mesh |
| `clock_foundry` | (0, 0, 0) | Per-chamber instance |

## Pacing

- Imp travel time (radius 18, speed 3.5 m/s): ~5.1s spawn → contact. Back-zone spawns longer due to divider.
- Demon travel time (radius 18, speed 2.5 m/s): ~7.2s direct, ~9-10s via divider.
- Ranger walk-in (radius 18 → 6, speed 2 m/s): ~6s. Rangers spawning in back zone stop at far side of divider and fire through gap — "hold the line" tactical moment.
- Time-to-clear estimate: 15 kills (5 to 20) × ~3s/kill avg = ~45s.
- Choke density: high (3 passage points + 8 pillars + 4 machinery). Player can choose route per run.

## Validation against aesthetic

- **Challenge**: 8 pillars + 4 machinery + 3 passage points create REAL tactical decisions. Where to retreat? Which side of divider? Geometry is a first-class strategic axis.
- **Sensation**: bullets sparking off pillars read as impacts. Cover-rich firefights feel visceral.
- **Submission**: 12+ landmarks → spatial memory builds across runs.

---

# Chamber 3 — Core Containment *(finale)*

_44×44m open boss arena with sparse cover. Boss pre-spawned at (0, 0, +16). Boss-kill clears._

## Map dimensions

- World units: 44 m × 44 m (XZ)
- Bounds: ±22 (same perimeter as Foundry)
- Spawn ring radius: 16 m (supplemental imps)
- Pickup spawn: ±16 in XZ
- Boss spawn: pre-placed at (0, 0, +16) — back-center

## Spatial pattern rationale

**Open arena with sparse asymmetric cover**. Inverse of Foundry's high-density layout. The Foundry taught the player to USE cover; the Core takes most of it away to force a direct confrontation. Three pillars at non-mirroring positions give SOME kiting cover but not enough to camp behind — player must engage the boss in the open.

Boss is **pre-spawned in initial_instances** (not via rule). When chamber loads, the boss already stands at (0, 0, +16) — visible at chamber-entry, no spawn-rule latency. The `core_boss_intro` rule fires once on first contact tick to play boss_roar + flash + shake — the dramatic intro beat.

Theme: deepest containment chamber — the breach point. Industrial machinery is gone (the boss tore it apart). Sparse pillars are the structural bones of the chamber that survived.

## Placements

### Perimeter walls (4)

Same as Foundry — reuses wall_ns + wall_ew defs.

| Wall | Position | Mesh |
|---|---|---|
| `wall_core_n` | (0, 0, +22) | wall_panel_ns |
| `wall_core_s` | (0, 0, -22) | wall_panel_ns |
| `wall_core_e` | (+22, 0, 0) | wall_panel_ew |
| `wall_core_w` | (-22, 0, 0) | wall_panel_ew |

### Pillars (3 — sparse asymmetric)

| Pillar | Position | Rationale |
|---|---|---|
| `pillar_core_L` | (-9, 0, -2)  | Left-of-center, slight forward — lateral cover for kiting boss |
| `pillar_core_R` | (+10, 0, 0)  | Right-of-center on z=0 — asymmetric counter to L |
| `pillar_core_F` | (0, 0, -10)  | Forward-of-player — early cover when boss is closing in |

### Boss (pre-spawned)

| Element | Position | Notes |
|---|---|---|
| `boss_core` | (0, 0, +16) | The Industrial Mover. 10 HP. Speed 1.5 m/s. Visible at chamber-entry — no score-trigger, no random spawn. `core_boss_intro` rule plays the dramatic cue when player first contacts the clock. |

### Floor + clock

| Element | Position | Notes |
|---|---|---|
| `floor_core` | (0, 0, 0) | Reuses floor_grate mesh |
| `clock_core` | (0, 0, 0) | Per-chamber instance |

## Pacing

- Boss travel time (from 0,0,+16 to 0,0,0, speed 1.5 m/s): ~10.7s. Slow ominous approach — deliberate, frames as tank-fight not zergling-rush.
- Supplemental imp interval: 4s (slower than Foundry's 2s) — boss is the focus, imps are distraction.
- Time-to-clear estimate: boss has 10 HP. Plasma (1 dmg/shot) = 10 hits ≈ 10-15s of sustained fire. Rocket (3 dmg) = 4 hits but cooldown 15 ticks ≈ 12s of rocket-only fire. Realistic kill time: 15-30s with mixed weapons + dodging.
- Choke density: low (3 pillars only). Player has nowhere to permanently hide — forces engagement.

## Validation against aesthetic

- **Challenge**: peaks here. No safe spots; boss + supplemental imps + low cover = the campaign's stress test.
- **Sensation**: boss intro = roar + flash + shake. Boss death = win sound + slow-mo + flash. Big spectacle bookends.
- **Submission**: trance-state loop during the boss fight — fire, dodge, reposition behind one of three pillars, repeat. Climax of the campaign's rhythm.

---

# Cross-chamber notes

## What's shared

- Ground primitive (Y=0 clamp for creatures, projectile despawn below) — engine-level, not per-chamber
- Universal floor_grate mesh (44×44m) — extends past chamber 1's walls but invisible there
- Wall meshes: wall_panel_ns / wall_panel_ew (44m) for chambers 2+3; wall_panel_ns_28 / wall_panel_ew_28 (28m) for chamber 1
- All entity defs (player, monsters, bullets, pickups, particles) — defined at root, instances per chamber

## What's per-chamber

- Walls (def varies: outer uses 28m walls, foundry+core use 44m walls + foundry adds dividers)
- Pillars (different counts + positions)
- Machinery (foundry only)
- Floor INSTANCE (visible mesh placed per chamber, def reused)
- Clock INSTANCE (state resets each chamber: elapsed=0, spawn_timer=1.5)
- Spawn rules (cadence + ring radius differ per chamber → live in `levels/<chamber>/world_rules.json`)
- Clear rule (different threshold per chamber)

## Risks / known issues

1. **Line-of-sight gap**: engine doesn't ray-test for AI sightline. Rangers fire at any player within radius 8 regardless of pillar/wall between them. Pillars + walls block ranger BULLETS (ADR 0004 + 0005), so cover protects the player even if AI targeting is omniscient. Future work: `raycast_hit`-based AI sightline. Tracked as future ADR.
2. **Player position carries between chambers**: persistent tag means HP/ammo/score persist, but ALSO means position persists. Player who stands at (-13, 0, +4) at end of chamber 1 starts chamber 2 at (-13, 0, +4). Usually fine; could be unfun if player ends chamber 1 stuck against a wall that doesn't exist in chamber 2 (e.g. behind chamber 1's small ±14 wall position is inside chamber 2's open area at ±14 — player just keeps going). Not currently a bug but worth watching.
3. **Floor visual extends past chamber 1 walls**: floor_grate is 44×44m; chamber 1 is 28×28m. Player can't reach the overshoot (walls block) but it's visible past the walls. Polish-time fix: per-chamber floor with right size, OR a floor_grate_28 mesh.
4. **No bullets-kill-walls visual**: bullet hitting wall just despawns silently. Future polish: spark on wall-impact for feedback.

## Validation across all chambers

- **Challenge curve**: Low (Outer) → High (Foundry) → Peak (Core). Monotonic difficulty progression.
- **Sensation curve**: equal across (same juice systems), peaks at boss intro + boss death moments.
- **Submission curve**: Outer = quick rhythm, Foundry = sustained tactical trance, Core = climactic boss-fight rhythm.
- **Identity coherence**: all 3 chambers use Containment Chamber 7 industrial-derelict palette. Outer = sparse perimeter, Foundry = busy mid-section, Core = ravaged inner sanctum. Theme tightens with progression.

---

**Summary**:
- 3 chambers totaling ~90-120s of play across the campaign
- Outer (28×28m, 4 pillars symmetric) — onboarding
- Foundry (44×44m, divider + 8 pillars + 4 machinery) — tactical signature
- Core (44×44m, 3 sparse pillars + boss) — climax
- Persistent player carries HP/ammo/score; everything else per-chamber
- Aesthetic match: Challenge curve rises across chambers; Sensation steady; Submission per-chamber-internal
