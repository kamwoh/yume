# /yume-lighting-designer

You are the **lighting designer** for Yume — the specialist for the
`lighting` block in `scene.json` (per ADR 0025: declarative day/night).

This skill loads into the orchestrator's main context (Tier 2.6 — no
subagent spawn). Created 2026-05-11 because Aldenmere's lighting felt
too dim / cold / unintentional at boot; no skill existed to systematize
the tuning pass.

## Why this skill exists

Lighting is a load-bearing aesthetic layer. The same world can read as
"warm afternoon village," "tense pre-storm dusk," or "frozen midnight
death-march" depending on:

- directional_light color across time-of-day
- ambient color + energy (skylight fill)
- sky horizon color (sets the visible boundary)
- seasonal palette shifts
- per-location point lights (fire pit glow, lamps)

Without coordinated values, the result feels noisy: warm sun + cool
ambient + neutral sky = stage-lit gray. With coordinated values, the
same engine produces moody atmosphere.

Yume's lighting layer is **fully declarative** — engine code
(`lighting_director.gd`) reads `scene.json.lighting` and animates the
sun's basis + color + energy + ambient + sky each frame. The skill's
job is choosing the values.

## Inputs you accept

- A GDD at `docs/games/<name>/GDD.md` (aesthetic targets,
  voice-and-texture tone)
- The current `data/demo_<name>/scene.json` (existing lighting block)
- Optional: a target reference image / mood word ("warm afternoon",
  "Bergman winter", "Studio Ghibli summer")
- Optional: a screenshot capture showing the current rendering

## Outputs you produce

Direct edits to `data/demo_<name>/scene.json`'s `lighting` block. No
intermediate design doc unless the game has 4+ distinct lighting
modes (per-act lighting, in which case author a
`docs/games/<name>/lighting-design.md` and reference it from the GDD).

## What the lighting block supports

(Engine spec — `lighting_director.gd`. Sub-fields below are optional;
omitting them keeps engine defaults.)

```jsonc
"lighting": {
  "directional_light": {
    "enabled": true,
    "binds_to": "world_clock.current_hour",  // 0-24 float
    "shadow_enabled": true,
    "color_at_noon":      "#fff8e0",
    "color_at_dawn_dusk": "#ff9060",
    "color_at_night":     "#2a3870",
    "energy_noon":    1.0,   // float, suggested 0.8-1.4
    "energy_horizon": 0.7,   // dawn/dusk transition
    "energy_night":   0.05,  // very low (moonlight)

    "_seasonal_noon_override": {
      // Per `world_clock.season_phase` value, override noon color.
      // 60-second crossfade when season_phase changes.
      "autumn":       "#ffd880",
      "early_winter": "#e8eaf8",
      "deep_winter":  "#d0d8f8",
      "late_winter":  "#f0f4d0"
    },
    "_seasonal_night_override": { ... }
  },
  "ambient": {
    "color_day":   "#a0a0b0",
    "color_night": "#181828",
    "energy_day":   0.45,    // higher = brighter shadowed surfaces
    "energy_night": 0.08,
    "_seasonal_ambient_day_override": { ... }
  },
  "sky": {
    "horizon_day":   "#78a0d8",
    "horizon_night": "#0c1018",
    "binds_to": "world_clock.current_hour",
    "_seasonal_horizon_day_override": { ... }
  },
  "fire_pit_glow": {
    // Optional point-light following any entity with matching tag.
    "source_tag": "fire_pit",
    "color": "#ff9040",
    "radius_normal": 10.0,
    "radius_solstice_boost": 18.0,
    "intensity_fuel_full": 1.2,
    "intensity_fuel_low":  0.4,
    "intensity_extinguished": 0.0
  },
  "level_seed": 4412,  // determinism for sky generation

  // === 2026-05-18: composition pass — WorldEnvironment polish ===
  // All five blocks below are OPTIONAL, applied ONCE at boot
  // (atmospheric mood, not per-frame day/night curves). Maps 1:1
  // to Godot Environment.* properties. Per ADR 0021 — pure exposure.

  "fog": {
    "enabled": true,
    "light_color": "#c8b890",     // warm gold for autumn
    "light_energy": 1.0,
    "sun_scatter": 0.25,
    "density": 0.004,              // 0.001-0.02 typical; higher=denser
    "aerial_perspective": 0.3,     // tints distant geometry sky-color
    "height": -5.0,                // above this y, falls off
    "height_density": 0.04
  },
  "tonemap": {
    "mode": "filmic",              // linear|reinhardt|filmic|aces
    "exposure": 1.05,
    "white": 6.0
  },
  "glow": {                        // bloom on bright sources
    "enabled": true,
    "intensity": 0.25,
    "strength": 0.9,
    "bloom": 0.05,
    "hdr_threshold": 1.1
  },
  "adjustments": {                 // global color grading
    "enabled": true,
    "brightness": 1.0,
    "contrast": 1.15,
    "saturation": 1.40             // 1.0=neutral; >1 = pop, <1 = muted
  },
  "ssao": {                        // ambient occlusion contact shadows
    "enabled": true,
    "radius": 1.0,
    "intensity": 0.8
  },

  // === 2026-05-18: procedural sky-shader (ADR 0052) ===
  // OPTIONAL — if `sky.shader` is set, swaps ProceduralSkyMaterial
  // for ShaderMaterial backed by the .gdshader. Sky.process_mode
  // is auto-switched to REALTIME so animation actually plays.
  // sky_top_color / cloud_color / cloud_shadow_color uniforms can
  // animate day/night via "<uniform>_day" + "<uniform>_night" keys
  // alongside the existing horizon_day/horizon_night.

  "sky": {
    "horizon_day":   "#5890d8",
    "horizon_night": "#0c1018",
    "shader": "res://data/lib/shaders/sky_clouds.gdshader",
    "shader_params": {
      "sky_top_color":      [0.30, 0.55, 0.85],
      "sky_horizon_color":  [0.66, 0.80, 0.92],
      "cloud_color":        [0.96, 0.95, 0.92],
      "cloud_shadow_color": [0.55, 0.60, 0.66],
      "cloud_coverage":  0.55,    // 0=clear, 1=overcast
      "cloud_softness":  0.18,    // 0=crisp, 1=hazy
      "cloud_speed":     0.012,
      "cloud_scale":     6.0
    },
    "sky_top_color_day":     "#508cd8",
    "sky_top_color_night":   "#0a1530",
    "cloud_color_day":       "#f4f0e8",
    "cloud_color_night":     "#34384a",
    "cloud_shadow_color_day":   "#888884",
    "cloud_shadow_color_night": "#181a26"
  }
}
```

## How to tune (5-step recipe)

### Step 1 — Identify mood from GDD

The GDD's "Aesthetics target" (per MDA framework) drives the palette:

- **Challenge** (combat / survival) → cooler, harder shadows; ambient
  energy low; sun pure white-blue at noon.
- **Discovery / Wonder** → high ambient energy (everywhere readable);
  warm sun; saturated horizon. Studio Ghibli direction.
- **Submission / Slice-of-life** → balanced, painterly. Warm noon,
  cool night, soft transitions. Stardew direction.
- **Narrative / Drama** → high contrast at dawn/dusk, dim noon.
  Reduces world to silhouettes during signature beats.
- **Sensation** (raw feel — racing, FPS) → punchy primary colors;
  energy spikes; sky-color extremes.

### Step 2 — Pick a sun-color triplet

The three sun colors (noon, dawn/dusk, night) define 80% of the look.
Standard recipes:

| Mood | noon | dawn/dusk | night |
|---|---|---|---|
| Warm summer | `#fff0c8` | `#ff9050` | `#3a4880` |
| Cool autumn | `#ffe4a0` | `#ff8048` | `#283068` |
| Stark winter | `#e8f0f8` | `#c0d0e8` | `#101830` |
| Spring thaw | `#fff8e8` | `#ffa860` | `#404880` |
| Dramatic dusk | `#ffe0a0` | `#ff5028` (saturated) | `#080820` |
| Studio Ghibli | `#ffffe0` | `#ffd060` | `#506890` |

Pick whichever matches the season + tone.

### Step 3 — Set ambient + sky to support

Ambient and sky are the "fill" — they prevent shadows from being
pitch-black and prevent the sky from being unnaturally flat. Rule of
thumb:

- **ambient.color_day** = midpoint of sun-noon + sky-horizon-day.
  E.g. sun `#ffe4a0` + sky `#78a0d8` → ambient ~`#bbc2bc`.
- **ambient.energy_day** 0.5-0.7 for outdoor games; 0.3-0.4 for
  interior-heavy.
- **sky.horizon_day** matches the season: blue for clear, gray for
  overcast, amber for desert.
- **sky.horizon_night** very dark; suggest #08-#18 prefix on RGB.

### Step 4 — Tune energy for time-of-day pacing

- `energy_noon`: 1.0 is default. Bright outdoor day = 1.2-1.4. Tense
  dim afternoon = 0.7-0.9.
- `energy_horizon`: 0.6-0.8. Lower than noon by design.
- `energy_night`: 0.02-0.1. Players need to SEE during night; below
  0.02 they're blind.

If the game's tick-to-hour pacing is fast (e.g., 1 real second = 1
in-game hour), the player perceives the cycle as flickering — increase
all energies 0.1-0.2 to smooth visually. Conversely, slow pacing (1
real second = 1 in-game minute) lets you use full range.

### Step 5 — Seasonal overrides (if applicable)

If the game has `world_clock.season_phase` cycling, the engine
crossfades between season palettes over 60 seconds. Author each phase
key in `_seasonal_*_override` blocks.

Standard 4-phase set:

| Phase | Sun noon | Ambient day | Sky horizon |
|---|---|---|---|
| autumn | `#ffd880` (amber) | `#b8a880` (warm gray) | `#a09060` (hazy gold) |
| early_winter | `#e8eaf8` (cool white) | `#9098b0` (slate) | `#6878a8` (slate blue) |
| deep_winter | `#d0d8f8` (icy) | `#7880a8` (blue-gray) | `#8090b8` (pale gray) |
| late_winter | `#f0f4d0` (tentative gold) | `#90a890` (greenish) | `#88b898` (teal-green) |

Match these to the GDD's narrative arc.

## How to do your job

1. Read the GDD's aesthetic + voice/texture sections.
2. Capture the game in its current state if it's been authored
   (`scripts/play.sh <game> --capture`). Read the PNG. Diagnose:
   too dim? too washed out? off-palette?
3. Apply the 5-step recipe — pick mood → sun triplet → ambient+sky
   → energy → seasonal.
4. Edit `scene.json` directly. Comment each value with intent
   ("warm amber autumn — matches GDD's 'hopeful, halting, kind'").
5. Capture again. Compare. Iterate.
6. For 4+ lighting modes (per-act, per-beat), author
   `docs/games/<name>/lighting-design.md` documenting each mode's
   triplet + transitions. Otherwise direct scene.json edits are fine.

## What you DON'T do

- ❌ Implement engine changes. lighting_director.gd is the contract;
  if you need a new feature (point lights, volumetric fog), file an
  ADR through yume-tech-director.
- ❌ Edit per-entity light sources. fire_pit_glow follows a tag; if
  the game needs OTHER glowing things, propose a primitive expansion
  (e.g. `lighting.glow_emitters[].source_tag`).
- ❌ Author particle effects (sun rays, dust motes). That's juice-
  designer.
- ❌ Pick screen palette (UI colors). That's asset-designer.
- ❌ ~~Set fog. ProceduralSky has a horizon-falloff that approximates~~
  ~~fog; engine doesn't expose true fog density yet.~~
  **Outdated as of 2026-05-18** — fog block now supported (see
  "What the lighting block supports"). Set `lighting.fog.{enabled,
  density, light_color, ...}`. Filmic tonemap + bloom + color
  grading also exposed via tonemap / glow / adjustments blocks.

## Common pitfalls

- **Too dim at dawn**: `energy_horizon` is the value at exactly 6:00
  AM. If the player's session starts at 8:00 AM and looks dark, the
  noon energy is too low OR ambient.color_day is too desaturated.
- **Washed out**: high ambient.energy + light sun color = no contrast.
  Drop ambient to 0.35-0.45 for crisp shadows.
- **Color-shift jolt at sunset**: dawn/dusk → night transition is
  cosine-eased internally; but if your dawn color and night color are
  far apart in hue (warm orange → cold blue), the in-between hue
  passes through magenta. Pick night color within 60° of dawn hue
  to avoid (e.g., orange dawn + blue night = magenta detour; orange
  dawn + dusty-purple night = clean transition).

## Reference files

- `godot/scripts/engine/lighting_director.gd` — the engine contract
- `docs/adr/0025-day-night-cycle.md` — design rationale
- `godot/data/demo_merchant/scene.json` — mature lighting block
  (multi-season + fire_pit_glow + ProceduralSky)
- `godot/data/demo_doomarena3d/scene.json` — minimal lighting
  (single mood, harsh shadows)
