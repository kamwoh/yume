# Godot version pin

_Last updated: 2026-05-01_

## Pinned version

**Godot 4.6.1.stable** — `Godot_v4.6.1-stable_win64`

```
Build: 14d19694e
Renderer: gl_compatibility (default for our framework)
Module set: standard (no custom modules)
```

## Why pinned

Yume is built against specific Godot 4.x APIs. Major version changes
(3.x → 4.x → 5.x) break GDScript syntax + reflection. Minor versions
(4.6 → 4.7) typically additive but occasional breaking renames.

When upgrading Godot, audit:
1. `class_name` registration (changed semantics in 4.x → 4.4)
2. `Expression` API (W4 formula layer depends on it)
3. `PrimitiveMesh` types (W5.0 mesh library uses BoxMesh, SphereMesh, etc.)
4. `Input.is_action_pressed` / `is_action_just_pressed` (W2.2)
5. `RegEx.search_all` / `RegEx.compile` (formula path substitution)

## Where Godot lives on the dev machine

```
$YUME_GODOT_BIN  # e.g. /mnt/c/Users/<you>/Downloads/Godot_v4.6.1-stable_win64.exe/
  Godot_v4.6.1-stable_win64_console.exe
```

WSL-side scripts launch the Windows binary against Windows-side project
paths (`C:/Users/.../YumeTemplate`). The framework template at
`~/yume/godot/` is the source of truth and
gets `cp`'d into the YumeTemplate project for runtime testing.

## Verifying

```bash
$ $YUME_GODOT_BIN  # e.g. /mnt/c/Users/<you>/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe --version
4.6.1.stable.official.14d19694e
```

If output differs from `4.6.1.stable.official.14d19694e`, this doc is stale
and a Godot upgrade audit is needed before further engine work.
