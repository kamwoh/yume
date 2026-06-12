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
  "Bergman winter", "hand-painted-anime summer")
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
    "saturation": 1.05             // 1.0-1.1 = stylized-realistic;
                                   // >1.2 reads candy/cartoon (2026-06-12,
                                   // autorace anti-cartoon pass)
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

## Render + shadows + LUT + probes + entity lights (ADR 0071/0072, 2026-06-12)

The autorace graphics pass (2026-06-11/12) exposed a second
vocabulary tier. All of it is JSON — AUTHOR it; do not report these
as engine gaps:

### Top-level `render` block (sibling of `lighting` in scene.json)

```jsonc
"render": {
  "msaa_3d": "2x",            // disabled | 2x | 4x | 8x — the ONLY AA
                              // gl_compatibility runs (hardware MSAA)
  "screen_space_aa": "fxaa",  // disabled | fxaa | smaa — Forward+/Mobile
                              // ONLY: BOTH variants warn + no-op in
                              // gl_compatibility (empirical 2026-06-12)
  "use_taa": false,           // Forward+ only — SILENT no-op elsewhere
  "scaling_3d_mode": "fsr",   // bilinear | fsr | fsr2 (fsr2: Forward+ only)
  "scaling_3d_scale": 0.75    // the cheapest perf lever on iGPU hardware
}
```

### `lighting.directional_light.shadow`

```jsonc
"shadow": {"mode": "2_splits",  // orthogonal | 2_splits | 4_splits
           "blur": 1.4, "max_distance": 130, "atlas_size": 4096}
```

4_splits is Godot's SLOWEST default — `2_splits` halves shadow cost
with little visible loss at game cameras. Bound `max_distance` to the
dressed area.

### `lighting.adjustments.color_correction` — SHARP TOOL

`{"texture": "<path>.tres"}` or `{"gradient": ["#0a0c14", "#7e6a4a",
"#fff3dc"]}`. Godot samples the LUT in LINEAR domain: stops authored
as an sRGB-diagonal compress the visible range into the dark end and
crush the frame to near-black — empirical 2026-06-12, autorace's
first warm-film gradient did exactly this. Author stops against
linear luminance (dense at the low end), VERIFY WITH A CAPTURE, and
prefer ACES tonemap + brightness/contrast/saturation for film looks
(autorace ships its look that way).

### `lighting.reflection_probes`

```jsonc
"reflection_probes": [{"position": [0, 8, 0], "size": [140, 30, 110],
                       "intensity": 1.0, "update_mode": "once"}]
```

In gl_compatibility there is NO SSR — a baked probe (`"once"`,
near-free at runtime) is the ONLY way metallic materials reflect
anything (empirical: autorace car paint reflected flat ambient until
a probe landed). `"always"` is the expensive variant.

### Per-entity lights (`visual.light`, ADR 0072)

Entity defs carry their own omni/spot lights: `{type, color, energy,
range, position (local offset), shadow (default false — the
expensive half), angle + direction for spot}`. Lights follow their
entity — carried lanterns and headlights come free. The per-def
block is asset-designer's (see its § Micro-lights, incl. the
mandatory `primitives[].emission` pairing); YOU own the scene's
light budget + mood: gl_compatibility caps per-mesh light influence
(~8 omni) — dozens of scattered lamps fine, hundreds not.

### Time-of-day is a lighting STAGE

`directional_light.binds_to: "world.time_of_day"` + a pin in
`world/state.json` (`{"state": {"time_of_day": 15.7}}`) stages the
whole scene: golden hour (~15.7) for drama; dusk/night (19+) makes
entity lights carry the scene (autorace races at 15.7). Ambient is
ANIMATED by time-of-day (night lerps ambient toward ~0) — don't
fight it with the ambient knob; move the clock instead.

## Lighting design discipline (2026-06-12 — distilled from industry references: the Level Design Book lighting chapter + Unity/Unreal lighting manuals)

The blocks above are the HOW. This section is the WHY/WHERE — decide
these before touching any number.

### Lighting has three jobs — know which one each light does

1. **Worldbuilding** — fixtures suggest era + setting (a sodium street
   lamp vs a brazier tells the player when/where they are).
2. **Spatial organization** — contrast (warm/cool, bright/dim) divides
   one space into readable sub-regions without walls.
3. **Wayfinding** — illumination HIERARCHY guides the player: the
   important exit is brighter and more focused than secondary spaces;
   a dark far wall reads "closet/backdoor, not the way forward."

A light that does none of the three is decoration debt — cut it or
give it a job.

### Motivated lights (the fixture rule)

A "motivated" light has a VISIBLE plausible source. In Yume terms this
is the ADR 0072 pairing taken further: every `visual.light` wants a
fixture mesh (lamppost, fire pit, window), and every glowing fixture
wants its light. One fixture may legitimately need several engine
lights to sell the effect (film practice: 11+ sources per fixture);
the reverse — a pool of light with no source in frame — reads
artificial and should be reserved for gameplay-clarity exceptions
(objective glow), used knowingly.

### The four-pass authoring order

Do passes in this order, and do pass 1 EARLY (blockout stage, before
asset polish — lighting is structure, not garnish):

1. **Global** — sun (`directional_light` + time_of_day pin), ambient,
   sky, fog. Get the world readable end-to-end first.
2. **Wayfinding** — lights along the critical path; entrances/exits
   by hierarchy (primary route brightest).
3. **Gameplay** — tactical emphasis: objective markers, threat
   silhouettes, puzzle elements, checkpoint/finish gates.
4. **Detail/mood** — accents and atmosphere LAST, with restraint:
   over-tweaking pass 4 destroys passes 1-3.

### Placement vocabulary (the D6 strategies)

Six reusable placement patterns for `visual.light` work — name the
pattern in lighting-design.md so intent survives review:

| Pattern | Use |
|---|---|
| Focal point | one lit object (statue, podium, boss door) |
| Focal frame | light frames a view/threshold (gate, archway) |
| Path | linear chain of lights guiding movement (track lamps, corridor) |
| Area | general wash for a sub-region (camp, plaza) |
| Area + focal | a zone with one emphasized element inside |
| Area + path | a zone a lit route passes through |

Three-point lighting (key/fill/rim) belongs to FIXED-camera moments
only — title screens, hero captures, cinematic beats — it assumes a
known camera and falls apart under free 3D navigation.

### Type-choice cheat (2×2: global/local × omni/directional)

|  | Omnidirectional | Directional |
|---|---|---|
| **Global** | `lighting.ambient` | `lighting.directional_light` (sun/moon) |
| **Local** | `visual.light` omni (bulb, fire, ember) | `visual.light` spot (flashlight, headlight, stage beam) |

Falloff physics worth knowing: point/omni intensity falls with the
inverse square of distance (double the range ≠ double the reach);
spot cones get a soft penumbra edge that WIDENS with the angle —
tight angles read "beam," wide angles read "wash." Area lights and
baked lightmaps/GI are NOT exposed (and Godot's gl_compatibility
wouldn't run them) — emulate area-light softness with an emissive
`prim_unit_banner` quad + a low-energy omni.

### Cost ladder (Yume's mobility table)

Industry engines rank static-baked < stationary < movable. Yume's
equivalents, cheapest first:

1. Emissive primitive only (free — material property; blooms with glow)
2. `visual.light`, shadow OFF (cheap; budget ~8 omni influencing any
   one mesh in gl_compatibility)
3. `reflection_probes` update_mode "once" (one-time bake, ~free after)
4. `visual.light`, shadow ON (per-light shadow maps — the expensive
   half; reserve for ONE hero light per scene on iGPU targets)
5. Sun shadow quality (`shadow.mode` 4_splits) — already the slowest
   default; 2_splits halves it

### The albedo brightness rule

Indirect/ambient illumination can only bounce what albedo gives it:
keep diffuse textures/colors in the **50-100% brightness range**
unless deliberately void-black. Dark albedos + low ambient = a scene
that NO amount of light energy rescues (the bounce is multiplying
against near-zero). Symptom: "I keep raising energy and it's still
black." Fix the albedo, not the light.

## How to tune (5-step recipe)

### Step 1 — Identify mood from GDD

The GDD's "Aesthetics target" (per MDA framework) drives the palette:

- **Challenge** (combat / survival) → cooler, harder shadows; ambient
  energy low; sun pure white-blue at noon.
- **Discovery / Wonder** → high ambient energy (everywhere readable);
  warm sun; saturated horizon. Hand-painted-anime direction.
- **Submission / Slice-of-life** → balanced, painterly. Warm noon,
  cool night, soft transitions. Cozy farming-sim direction.
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
| Hand-painted anime | `#ffffe0` | `#ffd060` | `#506890` |

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
- ❌ ~~Edit per-entity light sources. fire_pit_glow follows a tag; if
  the game needs OTHER glowing things, propose a primitive expansion~~
  **Outdated as of 2026-06-12** — per-entity lights exist
  (`visual.light`, ADR 0072). The per-def block is asset-designer's;
  you own the scene-level light budget + mood coordination (see
  § Render + shadows + LUT + probes + entity lights).
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
- **"Raising energy doesn't help" black scenes**: albedo too dark —
  see § The albedo brightness rule. Bounce/ambient multiplies against
  the diffuse color; near-black albedo stays near-black under any
  light energy. Fix the texture/color, not the light.
- **Unmotivated light pools**: a bright spot with no visible fixture
  reads as a rendering bug to players. Pair every `visual.light` with
  fixture geometry (or consciously accept the artifice for gameplay
  clarity — objective glows).

## Reference files

- `godot/scripts/engine/lighting_director.gd` — the engine contract
- `docs/adr/0025-day-night-cycle.md` — design rationale
- `godot/data/demo_merchant/scene.json` — mature lighting block
  (multi-season + fire_pit_glow + ProceduralSky)
- `godot/data/demo_doomarena3d/scene.json` — minimal lighting
  (single mood, harsh shadows)
