# ADR 0071 — JSON exposure: render/viewport block, color-correction LUT, shadow tuning, reflection probes

_Date: 2026-06-12_
_Status: accepted_

## Context

The graphics pass on the autorace demo (2026-06-11) exhausted what
`scene.json` could express. Godot offers a tier of cheap, high-impact
presentation options that Yume had no JSON vocabulary for:

- **Viewport anti-aliasing + scaling** (MSAA, FXAA/SMAA, TAA, render
  scale, FSR) — at 960×540 in gl_compatibility, edge aliasing is the
  single most visible quality gap, and render-scale is the cheapest
  performance lever on iGPU-class hardware.
- **Color-correction LUT** (`Environment.adjustment_color_correction`)
  — the "filmic filter" beyond brightness/contrast/saturation; ~free
  on every renderer.
- **Directional shadow tuning** (`directional_shadow_mode`,
  `shadow_blur`, `directional_shadow_max_distance`, atlas size) — the
  default 4-split mode is the slowest option; games should be able to
  trade shadow quality for frame rate in data.
- **ReflectionProbe** — in gl_compatibility there is no SSR, so a
  metallic car reflects only flat ambient; one baked probe
  (UPDATE_ONCE, near-free at runtime) feeds real reflections.

Per ADR 0021, each is exposed 1:1 — no new rendering concepts, just
JSON names for Godot properties.

## Decision

LightingDirector (the scene.json presentation owner) grows four
config surfaces, all applied once at boot:

1. **Top-level `render` block** (sibling of `lighting`):

```jsonc
"render": {
  "msaa_3d": "2x",              // disabled | 2x | 4x | 8x
  "screen_space_aa": "smaa",    // disabled | fxaa | smaa
  "use_taa": false,              // Forward+ only (no-op elsewhere)
  "scaling_3d_mode": "fsr",     // bilinear | fsr | fsr2 | nearest
  "scaling_3d_scale": 0.75,
  "fsr_sharpness": 0.2
}
```

2. **`lighting.adjustments.color_correction`** — either a texture path
   (`.tres` GradientTexture1D / Texture3D) or a JSON-native gradient
   (hex stops, evenly spaced, built into a GradientTexture1D at boot):

```jsonc
"adjustments": { "color_correction": { "gradient": ["#0a0c14", "#7e6a4a", "#fff3dc"] } }
```

3. **`lighting.directional_light.shadow`**:

```jsonc
"shadow": { "mode": "2_splits",   // orthogonal | 2_splits | 4_splits
            "blur": 1.5, "max_distance": 120, "atlas_size": 4096 }
```

4. **`lighting.reflection_probes`** — array of baked probes:

```jsonc
"reflection_probes": [
  { "position": [0, 6, 0], "size": [140, 24, 110],
    "intensity": 1.0, "box_projection": false,
    "update_mode": "once" }    // once | always (always = expensive)
]
```

String→enum mappings live in static helpers (`msaa_from_string`,
`screen_space_aa_from_string`, `scaling_mode_from_string`,
`shadow_mode_from_string`, `gradient_texture_from_stops`) so they are
unit-testable headless without a viewport.

## Consequences

- The whole cheap-quality tier is now content: a game can ship MSAA +
  SMAA + a film LUT + tuned shadows + a car-paint probe without
  touching engine code or .tscn files.
- Renderer-tier no-ops are Godot's own semantics (TAA/FSR2 silently
  inert outside Forward+); the ADR's tables in the engine reference
  document which knob works where (see godot-api feature matrix).
- Unknown keys warn; valid-but-heavy values (msaa 8x, update_mode
  "always") are the author's informed choice — cost notes live in the
  comments, not in validation.
- **LUT gotcha (empirical 2026-06-12)**: Godot samples
  `adjustment_color_correction` in LINEAR domain. A gradient whose
  stops are authored as an sRGB-diagonal compresses most of the
  visible range into its dark end and crushes the frame to
  near-black (autorace's first warm-film gradient did exactly this).
  Author stops against linear luminance (dense at the low end), or
  supply a proper `.tres` LUT — and verify with a capture. The
  capability ships; the autorace demo carries its film look via
  ACES + BCS instead.
- 2D scenes simply omit the blocks (existing LightingDirector no-op
  convention).

## Alternatives considered

- **Project-settings exposure** (project.godot edits at sync time):
  rejected — per-game .tscn/project mutation is what WorldBoot's
  director pattern exists to avoid.
- **A separate RenderDirector node**: rejected — LightingDirector
  already owns scene.json presentation (Sun, WorldEnvironment); a
  second boot-time reader of the same file adds mount order questions
  for no isolation benefit.
- **Full CameraAttributes (DOF, auto-exposure) exposure**: deferred —
  unsupported in gl_compatibility (the shipping renderer), so there is
  no way to visually verify the mapping today. Future ADR when a
  Forward+ target exists.
