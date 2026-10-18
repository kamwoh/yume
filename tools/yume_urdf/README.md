# yume_urdf — import a URDF robot as a Yume articulated body

URDF is the robot description format of ROS. A URDF robot is a tree of
links and joints, which is the model of an articulated body (ADR 0091).
This tool writes the def JSON. The JSON stays canonical, so you can edit
the output by hand (ADR 0051, ADR 0093).

```bash
python -m tools.yume_urdf robot.urdf --friction caster=0 --layer vehicle \
  --spawn=-3.3,0,3.3 --out godot/data/demo_<name>/entities/robot.json
```

| Option | Meaning |
|---|---|
| `--id ID` | The def id. The default is the robot name. |
| `--friction LINK=V` | The friction of one link. URDF has no friction. Use `caster=0` for a sliding caster. |
| `--layer NAME` | A collision layer from `@lib.physics.layers`. Repeat it for more layers. |
| `--spawn X,Y,Z` | Also write one initial instance at this position. |
| `--out FILE` | The output file. Without it, the tool prints to stdout. |

## What changes

- **Axes.** ROS is Z-up with X forward and Y left. Yume is Y-up with -Z
  forward. A ROS vector (x, y, z) becomes (-y, z, -x). This is a proper
  rotation, so a hinge keeps its right-hand rule.
- **Frames.** A Yume link frame has the root orientation. The tool folds
  each joint `rpy` into the positions, joint axes and shapes below it.
  A box must end axis-aligned, and a cylinder must end along x, y or z.
  Other rotations stop the import with an error.
- **Motors.** URDF has no motors. Each `continuous` or `revolute` joint
  gets a motor that reads `self.state.<joint>_cmd` (rad/s). Its
  `max_torque` is `<limit effort>`. The joint reports as `<joint>`, so
  rules read `<joint>_angle` and `<joint>_speed`.
- **Mass.** `<inertial><mass>` becomes the link mass. A link with no
  inertial gets 0.001 kg. The inertia tensor is not used.
- **Visuals.** A link `<material>` color draws the link shape.

## Not supported

- `prismatic`, `planar` and `floating` joints. The spec has no slider.
  The import stops with an error.
- Mesh geometry (`.stl`, `.dae`). The link gets no shape, and the tool
  prints a warning.
- More than one collision shape for each link. The tool uses the first.
- Gazebo and `ros2_control` tags.

## Example

`examples/diffbot.urdf` is a two-wheel robot whose wheel joints roll
-90 degrees, as many ROS files do. `tests/test_urdf.py` checks its
conversion and the error cases:

```bash
python -m tools.yume_urdf.tests.test_urdf
```
