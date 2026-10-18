# ADR 0094 — Camera heading: follow the mouse look or the body heading

_Date: 2026-10-18_
_Status: accepted 2026-10-18_

_Related: ADR 0027 (camera presets), ADR 0086 (host-neutral spec), ADR 0091 (articulated bodies)_

## Context

The `third_person_3d` and `first_person_3d` cameras aim along
`state.facing`. The mouse writes `state.facing`, so the camera is a
mouse-look camera.

A robot or a vehicle has a different heading. Physics writes it to
`state.yaw` (ADR 0091 readback). No rule writes `state.facing` for a
robot. So a chase camera on the rover stayed behind the spawn heading,
and the robot turned away from it.

The gap stayed hidden because each rover capture used the orthographic
`iso_top_down` preset. The owner asked on 2026-10-18 why every 3D check
used an orthographic view. The first perspective capture found this
gap. It also found the missing sky in the rover demo. The owner
approved the `heading` field on 2026-10-18.

## Decision

A `third_person_3d` or `first_person_3d` camera block takes a
`heading` field.

| Value | The camera aims along |
|---|---|
| `facing` (default) | `state.facing`, the mouse look |
| `yaw` | `state.yaw`, the body heading that physics or a rule writes |

```json
"camera": {
  "$extends": "@lib.cameras.third_person_default",
  "follow_tag": "rover",
  "heading": "yaw",
  "distance": 1.4, "height": 0.55, "eye_height": 0.12, "use_pitch": false
}
```

The third-person crosshair ray uses the same heading. The mouse still
writes `state.facing` and `state.pitch`, so `use_pitch` works with both
values.

### The Godot interpreter

`CameraDirector.heading_of` reads the field. The engine reports
`camera.unknown_heading` once for a value that is not in the list, and
then uses `facing`.

### Enforcement

- `CameraDirector.HEADING_SOURCES` is a closed list.
  `validate_host_neutral.py` check 13 reads it and checks the resolved
  camera block of each `scene.json`.
- `test_camera_heading` in `test_runner.gd` drives a third-person camera
  with `heading: "yaw"` and checks that it sits behind the yaw and looks
  along it.
- `test_host_neutral.py` has 2 new cases.
- `gen_api_manifest.py` prints the list (§Camera heading).
- `.claude/rules/visual-qa.md` baseline criterion 11: the visual check of
  a 3D game includes one perspective frame at the game's own scale.

## Consequences

**Enables:**
- Chase cameras for robots, cars, boats and other vehicles.
- An onboard first-person view of a robot.

**Costs:**
- One more camera field. A new heading source needs an ADR.

**Known gaps:**
- The third-person camera collision ray starts 1 m above the target,
  and it keeps at least 1.2 m of distance after a hit. These values fit
  a human, not a small robot.
- A scene cannot switch between two camera blocks with one key. The
  `camera_mode` override changes only the mode and keeps the other
  fields.

## Alternatives considered

- **Use `state.yaw` when `state.facing` is absent.** No new field, but
  an entity with both fields gets a camera that is hard to predict.
- **A rule that copies `state.yaw` to `state.facing` each tick.** It
  works in JSON, but each vehicle game must know the trick, and the
  mouse then fights the rule.
