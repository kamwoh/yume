# Godot 4.6 GDScript — best practices for Yume

_Last updated: 2026-05-01_

Concise reference for the GDScript idioms used across Yume's engine.
**These are observed, working patterns** — battle-tested across 2200 LOC
and 169 unit tests. Deviating from them tends to surface as type-inference
errors at compile.

## Class declarations

```gdscript
extends RefCounted              # for non-Node helpers (Rule, QueryLib, ...)
class_name MyHelper

# OR
extends Node                     # for orchestrators (World — must be plain
class_name World                 # Node post-W1.14 to be renderer-agnostic)

# OR
extends Node2D                   # for 2D-positioned children (Sprite2D
class_name EntitySprite2D        # renderer)

# OR
extends Node3D                   # for 3D-positioned children
class_name EntityMesh3D
```

`class_name` registers the class globally — accessible without preload
once Godot has scanned the project. Run `--editor --quit` once after
adding a new class to force the scan.

## Static factories vs instance constructors

Use static `create()` for builders that take typed args:

```gdscript
static func create(def: Dictionary, inst_id: String, overrides: Dictionary = {}) -> Entity:
    var e := Entity.new()
    e.def_id = str(def.get("id", ""))
    # ...
    return e
```

Avoid relying on `_init()` for object setup unless you control all
construction paths.

## Type inference (`:=`) — what fails

```gdscript
var x := dict.get("k")          # FAILS — Variant return, can't infer
var x: Variant = dict.get("k")  # OK

var x := dict[k]                # FAILS — same reason
var x = dict[k]                 # OK — untyped is fine

var x := str(thing)             # OK — str() returns String

for k in some_dict:             # k is Variant
    var key := str(k)           # OK if str()'d explicitly
    var key: String = k          # FAILS if static checker can't prove k is String
```

When in doubt, use explicit type or omit the type entirely.

## Dictionary iteration

```gdscript
var d := {"a": 1, "b": 2}
for k in d:                  # k is Variant (key)
    var v = d[k]              # untyped
for k in d.keys():           # same
for kv in d.values():        # iterate values directly
```

## Variant type-checks

```gdscript
if v is float or v is int or v is bool: ...
if v is Array or v is Dictionary or v is Vector2 or v is Vector3: ...
if v is String: ...
if v is Entity: ...           # works for class_name'd RefCounted/Node
```

GDScript's static checker may complain about `is Node2D` checks on
explicitly-typed `Entity` variables. Workaround:

```gdscript
var e_var: Variant = e
expect(not (e_var is Node2D), "...")  # checker accepts Variant base
```

## Expression (formula evaluation)

```gdscript
var expr := Expression.new()
var input_names: PackedStringArray = PackedStringArray(["x", "y"])
var err := expr.parse("x + y * 2", input_names)
if err != OK:
    push_error("parse: " + expr.get_error_text())
var result = expr.execute([5.0, 3.0])
if expr.has_execute_failed():
    push_error("execute failed")
```

Built-in math: `sin`, `cos`, `tan`, `sqrt`, `pow`, `abs`, `floor`, `ceil`,
`round`, `clamp`, `min`, `max`, `lerp`, `randf`. No registration needed.

**Don't** trust user-supplied formula strings without an AST whitelist —
`Expression` parses full GDScript syntax. (Whitelist is W4.5, deferred.)

## Signals

```gdscript
signal tick(tick_count: int)
signal relation_added(type: String, from_id: String, to_id: String)

# Connect:
clock.tick.connect(_on_tick)

# Emit:
relation_added.emit(type, from_id, to_id)

# Check before connect:
if rs.has_signal("relation_added"):
    rs.relation_added.connect(_on_relation_added)
```

## Input polling

```gdscript
# In _process(delta):
if Input.is_action_pressed("move_north"):    # held
    ...
if Input.is_action_just_pressed("attack"):    # press-edge
    ...
```

Yume's World splits `input_actions_hold` (movement) and
`input_actions_press` (fire/attack) — different polling semantics.

## RegEx

```gdscript
var regex := RegEx.new()
regex.compile("\\b\\w+")
var m = regex.search(text)        # one match
var ms = regex.search_all(text)   # all matches

# Iterate matches:
for i in range(ms.size()):
    var match = ms[i]
    var s := match.get_string()
    var start := match.get_start()
    var end := match.get_end()
```

## File loading

```gdscript
if not FileAccess.file_exists(path):
    push_warning("missing: " + path)
    return
var f := FileAccess.open(path, FileAccess.READ)
var data = JSON.parse_string(f.get_as_text())
if not (data is Dictionary):
    push_error("invalid JSON: " + path)
    return
```

## Resources / scenes

```gdscript
if ResourceLoader.exists(sprite_path):
    var tex := load(sprite_path)
    if tex is Texture2D: ...
```

## Scene tree mutations during iteration

`queue_free()` defers removal. Safe to call during iteration. The Node
disappears at end of frame.

`add_child()` is immediate. Safe during _ready/_process.

## Headless run convention

```bash
godot --headless --path <project> <scene_path> --quit-after <frames>
```

`--quit-after N` is **frames**, not seconds. At default 60 fps, 600 frames
≈ 10 seconds.

## What NOT to do

- **Don't `extends Object`** — use `RefCounted` for helpers, `Node` for
  scene tree members. `Object` doesn't reference-count; leaks.
- **Don't pre-allocate Dictionaries inside loops** — iterate, mutate
  in place. Garbage collector handles cleanup.
- **Don't use `pass` as a placeholder** — empty function body is fine.
  `pass` is for empty match arms.
- **Don't `await` in tick loop** — tick is synchronous. Async work is
  Tier 4 (LLM brain).
