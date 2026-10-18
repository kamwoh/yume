#!/usr/bin/env python3
"""validate_host_neutral.py — game JSON names assets in host-neutral form.

ADR 0086 makes the JSON a host-neutral spec. ADR 0087 (phase 1) sets the
asset path form: a path relative to the game folder ("assets/meshes/x.glb")
or to the shared library ("@lib/meshes/rock.glb"). ADR 0089 (phase 3)
names a library shader by name ("sky_clouds").

Checks, for each JSON file:
1. No string contains `res://` or `user://`.
2. No asset reference has a scheme, a leading `/` or a `..` segment.
3. Each asset reference names a file that exists.
4. No string names a Godot file: `.tscn`, `.gdshader` or `.tres`.
5. Each `shader` value is a name in `content.SHADER_NAMES`.
6. Each `shader_params` key next to a named shader is a parameter of that
   shader, and not one that the interpreter sets.

ADR 0090 (phase 4) closes four vocabularies:
7. Input actions (`ui/input.json`, `data/lib/input*`) name keys from
   `InputKeys.KEYS` and mouse buttons from `InputKeys.MOUSE_BUTTONS`. A
   `set_input_mapping` effect names a key from the same list.
8. A `set_audio_bus_volume` effect names a channel: master, music or sfx.
9. A game's `scene.json` uses only the `lighting` and `render` fields in
   `LightingDirector.FIELDS`.
10. A `physics` block, after `$extends`, uses only the fields in
   `PhysicsBodyBuilder.FIELDS`, a body type from `BODY_TYPES` and layer
   names from `@lib.physics.layers` (or "all").

An asset reference is a string that ends with an extension in
`content.ASSET_EXTENSIONS`.
The validator skips two kinds of JSON that the engine does not read:
- files and folders whose name starts with "." or "_", which hold tool
  state or backups (`.assetgen_ledger.json`, `_snapshots/`),
- files under a game's `assets/` folder, which are asset data that the
  authoring tools write (`assets/layouts/*.layout.json`).
`content.py` holds the path rules. They mirror
`godot/scripts/engine/util/asset_path.gd`.

Scope:
    validate_host_neutral.py              # tracked JSON under godot/data/
    validate_host_neutral.py demo_x       # every JSON file in that game
    validate_host_neutral.py lib          # every JSON file in data/lib

Empirical case 2026-10-17: 201 `res://` references in 38 files. 15 of
them pointed into another demo's folder, and 16 named files that did not
exist.

Empirical case 2026-10-18: sokoban's music slider set a "Music" bus that
the engine never made, so it did nothing. Ten scenes set
`lighting.ambient.color` and `energy`, which the engine never read.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from content import (  # noqa: E402
    AUDIO_CHANNELS, BODY_TYPES, DATA, INTERPRETER_PARAMS, KEY_NAMES, LAYER_NAMES, MOUSE_BUTTONS,
    PHYSICS_FIELDS, REPO, SHADER_NAMES, asset_file, asset_problem, is_asset, resolver, shader_params,
    unknown_scene_fields,
)

GODOT_FILES = (".tscn", ".gdshader", ".tres")

# Keys whose value names a file that the run WRITES, not an asset it reads.
OUTPUT_KEYS = {"screenshot"}


def _strings(node, key=""):
    """Yield (key, string) for every string value in a JSON tree."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from _strings(v, str(k))
    elif isinstance(node, list):
        for v in node:
            yield from _strings(v, key)
    elif isinstance(node, str):
        yield key, node


def _shader_blocks(node):
    """Yield every dict that names a library shader."""
    if isinstance(node, dict):
        if node.get("shader") in SHADER_NAMES:
            yield node
        for v in node.values():
            yield from _shader_blocks(v)
    elif isinstance(node, list):
        for v in node:
            yield from _shader_blocks(v)


def _dicts(node):
    """Yield every dict in a JSON tree."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from _dicts(v)
    elif isinstance(node, list):
        for v in node:
            yield from _dicts(v)


def _names(value) -> list:
    return value if isinstance(value, list) else [value]


def _is_binding(s) -> bool:
    """A formula binding such as `value` or `self.state.key`, not a literal."""
    return isinstance(s, str) and s[:1].islower() and s.replace(".", "_").replace("_", "a").isalnum()


def check_vocabularies(f: Path, doc) -> list[str]:
    """ADR 0090 checks 7-10."""
    rel = f.relative_to(DATA).as_posix()
    where = f.relative_to(REPO)
    out = []
    if "input" in rel:
        for action in _dicts(resolver().resolve(doc)):
            if "name" not in action:
                continue
            for field in ("key", "keys"):
                for k in _names(action.get(field, [])):
                    if k not in KEY_NAMES:
                        out.append(f"{where}: action '{action['name']}' {field}: '{k}' is not a key "
                                   f"name. See the api manifest, Input keys (ADR 0090).")
            for field in ("mouse_button", "mouse_buttons"):
                for b in _names(action.get(field, [])):
                    if b not in MOUSE_BUTTONS:
                        out.append(f"{where}: action '{action['name']}' {field}: '{b}' is not a "
                                   f"mouse button. The names are: {', '.join(MOUSE_BUTTONS)} (ADR 0090).")
    for eff in _dicts(doc):
        if eff.get("type") == "set_input_mapping":
            k = eff.get("key")
            if isinstance(k, str) and not _is_binding(k) and k not in KEY_NAMES:
                out.append(f"{where}: set_input_mapping key: '{k}' is not a key name. See the api "
                           f"manifest, Input keys (ADR 0090).")
        elif eff.get("type") == "set_audio_bus_volume":
            bus = eff.get("bus", "master")
            if bus not in AUDIO_CHANNELS:
                out.append(f"{where}: set_audio_bus_volume bus: '{bus}' is not an audio channel. "
                           f"The channels are: {', '.join(AUDIO_CHANNELS)} (ADR 0090).")
    parts = f.relative_to(DATA).parts
    if len(parts) == 2 and parts[1] == "scene.json" and isinstance(doc, dict):
        for field in unknown_scene_fields(doc):
            out.append(f"{where}: {field}: scene.json has no such field. See the api manifest, "
                       f"Lighting fields (ADR 0090).")
    # lib/manifest.json indexes the library. Its "physics" key is a file list.
    for holder in _dicts(doc) if rel != "lib/manifest.json" else ():
        phys = holder.get("physics")
        if not isinstance(phys, dict):
            continue
        phys = resolver().resolve(phys)
        if not isinstance(phys, dict):
            continue
        for k in phys:
            if not str(k).startswith(("_", "$")) and k not in PHYSICS_FIELDS:
                out.append(f"{where}: physics.{k}: a physics block has no such field (ADR 0090).")
        if "body_type" in phys and phys["body_type"] not in BODY_TYPES:
            out.append(f"{where}: physics.body_type: '{phys['body_type']}' is not a body type. "
                       f"The types are: {', '.join(BODY_TYPES)} (ADR 0090).")
        for field in ("collision_layer", "collision_mask"):
            if field not in phys or phys[field] == "all":
                continue
            for name in _names(phys[field]):
                if name not in LAYER_NAMES:
                    out.append(f"{where}: physics.{field}: '{name}' is not a layer name. "
                               f"See @lib.physics.layers (ADR 0090).")
    return out


def _game_dir(f: Path) -> Path | None:
    """The demo folder that owns `f`, or None for data/lib and loose files."""
    rel = f.relative_to(DATA).parts
    return DATA / rel[0] if len(rel) > 1 and rel[0].startswith("demo_") else None


def in_scope(f: Path) -> bool:
    parts = f.relative_to(DATA).parts
    if parts[0].startswith("demo_") and len(parts) > 2 and parts[1] == "assets":
        return False
    return not any(p.startswith((".", "_")) for p in parts)


def check_file(f: Path) -> list[str]:
    try:
        doc = json.loads(f.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return []  # other validators own JSON-shape errors
    game_dir = _game_dir(f)
    out = check_vocabularies(f, doc)
    for block in _shader_blocks(doc):
        name = block["shader"]
        allowed = shader_params(name)
        params = block.get("shader_params", {})
        for k in params if isinstance(params, dict) else ():
            if k.startswith("_"):
                continue
            if k in INTERPRETER_PARAMS:
                out.append(f"{f.relative_to(REPO)}: shader_params.{k}: the interpreter "
                           f"sets '{k}'. Delete it (ADR 0089).")
            elif k not in allowed:
                out.append(f"{f.relative_to(REPO)}: shader_params.{k}: '{name}' has no "
                           f"parameter '{k}'. See the api manifest, Shaders (ADR 0089).")
    for key, s in _strings(doc):
        where = f"{f.relative_to(REPO)}: {key}"
        if "res://" in s or "user://" in s:
            out.append(f"{where}: '{s}' is a Godot path. Write it relative to "
                       f"the game folder, or as @lib/<path> (ADR 0087).")
            continue
        if s.endswith(GODOT_FILES) and " " not in s:
            out.append(f"{where}: '{s}' names a Godot file. The spec must not "
                       f"name one (ADR 0086 rule 3). Name a library shader, "
                       f"or write a shader_dag (ADR 0089).")
            continue
        if key == "shader" and s not in SHADER_NAMES:
            out.append(f"{where}: '{s}' is not a shader name. The names are: "
                       f"{', '.join(SHADER_NAMES)} (ADR 0089).")
            continue
        if not is_asset(s) or key in OUTPUT_KEYS or " " in s:
            continue
        why = asset_problem(s)
        if why:
            out.append(f"{where}: '{s}' is not a neutral asset path: {why}.")
            continue
        target = asset_file(s, game_dir)
        if target is None:
            out.append(f"{where}: '{s}' is relative, but data/lib has no game "
                       f"folder. Write @lib/<path>.")
        elif not target.is_file():
            out.append(f"{where}: '{s}' names a file that does not exist "
                       f"({target.relative_to(REPO)}).")
    return out


def tracked_json() -> list[Path]:
    res = subprocess.run(
        ["git", "ls-files", "godot/data/*.json", "godot/data/**/*.json"],
        cwd=REPO, capture_output=True, text=True, check=True)
    return [REPO / p for p in sorted(set(res.stdout.split()))]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("game", nargs="?", default=None,
                    help="demo_<name>, <name> or lib. Omit to check tracked JSON.")
    ap.add_argument("--strict", action="store_true", help="exit 1 on any finding")
    args = ap.parse_args()

    if args.game is None:
        files = tracked_json()
    else:
        name = args.game
        if name != "lib" and not name.startswith("demo_"):
            name = f"demo_{name}"
        root = DATA / name
        if not root.is_dir():
            print(f"[validate_host_neutral] skip: no folder {root.relative_to(REPO)}")
            return 0
        files = sorted(root.rglob("*.json"))

    files = [f for f in files if in_scope(f)]
    findings = [m for f in files for m in check_file(f)]
    if not findings:
        print(f"[validate_host_neutral] OK: {len(files)} JSON files use "
              f"host-neutral paths, shaders and vocabularies")
        return 0
    print(f"[validate_host_neutral] {len(findings)} findings:")
    for m in findings:
        print(f"  [ERROR] {m}")
    return 1 if args.strict else 0


if __name__ == "__main__":
    sys.exit(main())
