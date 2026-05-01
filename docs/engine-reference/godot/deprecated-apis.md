# Godot — deprecated / removed APIs to avoid

_Last updated: 2026-05-01_
_Pinned: Godot 4.6.1 (see VERSION.md)_

LLMs (Claude included) often produce code from training cutoffs that
predates Godot 4 changes. This list is the trip-wire — if you see any of
these in proposed code, **reject and use the replacement.**

## From Godot 3 (do NOT emit)

| Godot 3 API | Godot 4 replacement | Notes |
|---|---|---|
| `func _ready():` is fine, but... | `func _ready() -> void:` | Type returns explicitly |
| `Vector2(x, y)` | same | unchanged |
| `Engine.delta` | `delta` parameter to `_process` | global `delta` removed |
| `OS.get_ticks_msec()` | `Time.get_ticks_msec()` | `OS` slimmed |
| `var x = export(int) X` | `@export var x: int` | annotation syntax |
| `setget` | dedicated getter/setter properties via `:` | rare in Yume — avoid |
| `tool` keyword | `@tool` annotation | |
| `signal foo(arg)` (untyped) | `signal foo(arg: int)` | typed signals preferred |
| `is Object` blanket check | specific class check | `is Object` always true now |
| `KinematicBody2D.move_and_slide(velocity, ...)` | `CharacterBody2D` + `velocity` member | KinematicBody renamed |
| `RigidBody2D.linear_velocity = v` (in `_process`) | use `_physics_process` | physics rules tightened |
| `connect("foo", self, "_on_foo")` | `foo.connect(_on_foo)` | typed signal API |
| `yield(timer, "timeout")` | `await timer.timeout` | coroutine syntax |
| `preload("res://...")` returning Script-as-Class | `class_name` on the script | global registration |

## Removed concepts

- **`Reference` class** → renamed to `RefCounted`. `extends Reference`
  doesn't compile.
- **`PoolStringArray` etc.** → `PackedStringArray`, `PackedFloat32Array`,
  `PackedByteArray`, etc.
- **`ECMAScript` module** → removed (was 3.x experimental).
- **`bbcode_text` getter on `RichTextLabel`** → just `text` with
  `bbcode_enabled = true`.

## Common LLM mistakes against Godot 4.6 specifically

1. **`PrimitiveMesh.size` direction.** `BoxMesh.size` is Vector3, not float.
   `SphereMesh.radius` + `SphereMesh.height` (separate fields, not a
   single `size`).

2. **`Camera3D.transform` syntax.** Use `Transform3D(basis, origin)` —
   never `Transform.LOOKING_AT(target, up)` (that wasn't a thing).
   Looking-at via:
   ```gdscript
   camera.look_at(Vector3(0, 0, 0), Vector3.UP)
   ```

3. **`@export_dir`, `@export_file("*.gd")`, `@export_node_path`** are
   real annotations in 4.6 — use them, don't guess at attribute syntax.

4. **`Input` actions** must be defined in `project.godot` `[input]` section
   OR registered via code with `InputMap.add_action(name)` +
   `InputMap.action_add_event(name, event)`. Polling an undefined action
   silently returns false.

5. **`Expression.parse(formula, input_names)`** — input_names is
   `PackedStringArray`, not `Array[String]`. Even though they look the
   same in many contexts, this one needs the explicit type:
   ```gdscript
   var names := PackedStringArray(["x", "y"])
   ```

6. **`File` class is gone.** Use `FileAccess.open(path, FileAccess.READ)`
   which returns `FileAccess` (auto-closes when ref-counted out of scope).

7. **`JSON.parse(text)` returns `Variant`** but the API shape changed.
   Use `JSON.parse_string(text)` for the simple case; older
   `JSON.parse()` returns a `Dictionary` with an error code (Godot 3
   pattern, deprecated).

## When you see suspicious API in code

Before merging:
1. Check it against this list
2. Check VERSION.md still pins 4.6.1
3. Run a quick smoke: `godot --headless --path <proj> <scene> --quit-after 60`

If the code segfaults or throws "no method", the API is wrong for 4.6.

## Things that look deprecated but ARE supported in 4.6

- `class_name` (works)
- `Color("#fff")` constructor (works, returns Color)
- `match` statement (works, but no falsethrough)
- `range(n)` (works)
- `String.split` / `String.replace` / `String.path_join` (work)
- `for i in range(N - 1, -1, -1):` reverse iteration (works)
- `func _draw():` for Node2D custom drawing (works)
- `Vector2.distance_to`, `distance_squared_to` (work)
