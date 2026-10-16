# ADR 0087 — Asset paths relative to the game folder

_Date: 2026-10-17_
_Status: accepted 2026-10-17_

_Implements: ADR 0086 phase 1_

## Context

ADR 0086 makes the JSON a host-neutral spec. Today an asset reference
is a Godot resource path:

```json
"mesh": "res://data/demo_aldenmere/assets/meshes/hero.glb"
```

The audit on 2026-10-17 found 201 such references in 38 files:

- 147 point into the game's own folder.
- 23 point into the shared library, `data/lib/`.
- 15 point into another demo's folder.
- 16 point to `res://audio/aldenmere/`, which does not exist.

A second interpreter cannot read `res://`. A reference into another
game also breaks when that game moves, and a host must then ship both
games.

The owner approved two choices on 2026-10-17: relative paths with an
`@lib/` prefix, and no references outside the game's own folder.

## Decision

### 1. The path form

An asset reference is a string value that ends with an asset file
extension. The extensions are `.glb`, `.gltf`, `.png`, `.jpg`, `.jpeg`, `.webp`, `.svg`,
`.exr`, `.hdr`, `.ogg`, `.wav`, `.mp3`, `.gdshader` or `.tres`. It
has one of two forms:

| Form | Example | Resolves to |
|---|---|---|
| Relative | `"assets/meshes/hero.glb"` | The game folder (`data/demo_<name>/`) |
| Library | `"@lib/shaders/toon.gdshader"` | The shared library (`data/lib/`) |

A path is always relative to the game folder, also in a level or a
variant file. A path must not contain `..`, a scheme (`res://`,
`user://`, `http://`) or a leading `/`.

`.json` files are not asset references. The JSON loaders find them by
folder convention or by `$include`.

### 2. One resolver

The Godot interpreter resolves every asset reference in one function,
`AssetPath.resolve()`. It returns a `res://` path for Godot. The world
sets the game folder when it loads. A `res://` value, `..` or a scheme
gives the error `asset_path.not_neutral` and loads nothing.

Engine code may still use `res://` for its own files, for example the
built-in grass shader. Only values from game JSON go through the
resolver.

### 3. A gate

`tools/validators/validate_host_neutral.py` checks every JSON file in
each game folder and in `data/lib/`:

1. No string contains `res://` or `user://`.
2. No asset reference contains `..` or starts with `/`.
3. Each asset reference resolves to a file that exists.
4. No asset reference ends with `.tscn`.

The pre-commit hook and CI run it in strict mode.

### 4. Migration

A one-time script rewrites every game:

- `res://data/<own game>/x` becomes `x`.
- `res://data/lib/x` becomes `@lib/x`.
- `res://data/<other game>/x`: the script copies the file into the
  same relative place in this game, then writes the relative path. It
  deletes nothing.
- A reference to a file that does not exist stays broken, and the
  validator reports it.

The tools that write paths (`yume_assetgen`, `compose_world`,
`compose_shell`, `yume_codegen`, `yume_shadergen`, `yume_infinigen`)
write the new form. The validators that read paths use the same
resolution. The skills teach the new form.

## Consequences

- An LLM writes shorter paths, and it cannot write a path that only
  Godot understands.
- Each game folder stands alone. A web export or a second interpreter
  needs only that folder plus `data/lib/`.
- Shared assets now exist as copies in each game that uses them.
- `.gdshader` and `.tres` files stay allowed until ADR 0086 phase 3.
  Phase 1 changes only how a game points to them.

## Alternatives considered

- **An asset table with ids.** Each new asset needs an entry in a
  second file, which adds a sync error for the LLM. Rejected.
- **URI schemes (`game://`, `lib://`).** The same as relative paths,
  with more characters. Rejected.
- **Allow `../demo_x/...`.** No copies, but games depend on each other.
  Rejected.
