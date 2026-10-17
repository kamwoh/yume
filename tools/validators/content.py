"""content.py — the shared content loader for validators (batch G, 2026-10-16).

Validators must check the same rules that the engine runs. Before this
module, each validator walked the game folder its own way. Some missed
`world/rules/*.json`, some missed `levels/*/rules/`, and only
validate_rules.py knew about `$include`. A rule that one validator saw was
invisible to the next.

This module mirrors the engine:

- `rule_files(game_dir)` returns the files that WorldBoot and
  LevelTransitionCoordinator load: `world/rules`, `game/goals`,
  `tutorial.json` and `levels/<n>/rules`. Each of the folder-or-file
  pairs follows `WorldLoader.load_rules_files_for`: the folder form wins,
  and its files load in name order.
- `LibResolver` ports `libs/lib_resolver.gd` (ADR 0027): `@lib.X.Y`
  strings, `{"$extends": ...}` merges and `{"$include": ...}` array
  splices, from `godot/data/lib/**.json`.
- `iter_rules(game_dir)` yields `(path, rule)` for every rule after lib
  resolution. A rule from a bundle carries `_origin`.
- `asset_file(path, game_dir)` ports `util/asset_path.gd` (ADR 0087): it
  turns a host-neutral asset path into the file it names.
- `SHADER_NAMES` and `shader_file(mesh, game_dir)` port
  `util/shader_lib.gd` (ADR 0089).
"""

from __future__ import annotations

import copy
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DATA = REPO / "godot" / "data"
MAX_DEPTH = 8


# ADR 0087 asset paths. Keep these the same as util/asset_path.gd.
LIB_PREFIX = "@lib/"
ASSET_EXTENSIONS = (
    ".glb", ".gltf", ".png", ".jpg", ".jpeg", ".webp", ".svg",
    ".exr", ".hdr", ".ogg", ".wav", ".mp3",
)


def is_asset(value) -> bool:
    """True when `value` is a string that names an asset file."""
    return isinstance(value, str) and value.lower().endswith(ASSET_EXTENSIONS)


def asset_problem(path: str) -> str:
    """Why `path` is not a host-neutral asset path, or "" when it is one."""
    if "://" in path:
        return "it has a scheme"
    if path.startswith("/"):
        return "it starts with /"
    if ".." in path.split("/"):
        return "it has a .. segment"
    return ""


def asset_file(path: str, game_dir: Path | None) -> Path | None:
    """The file that a host-neutral asset path names. None when the path is
    not neutral, or when a relative path has no game folder."""
    path = path.strip()
    if not path or asset_problem(path):
        return None
    if path.startswith(LIB_PREFIX):
        return DATA / "lib" / path[len(LIB_PREFIX):]
    return Path(game_dir) / path if game_dir is not None else None


# ADR 0089 named shaders. util/shader_lib.gd is the source.
_SHADER_LIB = (REPO / "godot" / "scripts" / "engine" / "util" / "shader_lib.gd").read_text(encoding="utf-8")
SHADER_NAMES = tuple(re.findall(r'"(\w+)"', re.search(r"const NAMES: Array = \[(.*?)\]", _SHADER_LIB, re.DOTALL).group(1)))
INTERPRETER_PARAMS = tuple(re.findall(r'"(\w+)"', re.search(r"const INTERPRETER_PARAMS: Array = \[(.*?)\]", _SHADER_LIB, re.DOTALL).group(1)))
GRAPH_OUTPUT = re.search(r'const GRAPH_OUTPUT := "([^"]+)"', _SHADER_LIB).group(1)


def shader_params(name: str) -> set[str]:
    """The uniform names of the library shader `name`."""
    src = (DATA / "lib" / "shaders" / f"{name}.gdshader").read_text(encoding="utf-8")
    return set(re.findall(r"^\s*uniform\s+\w+\s+(\w+)", src, re.MULTILINE))


def shader_file(block: dict, game_dir: Path) -> Path | None:
    """The Godot shader file that a `shader` / `shader_dag` block runs, or
    None when the block names no shader or an unknown name."""
    if "shader_dag" in block:
        return Path(game_dir) / GRAPH_OUTPUT
    name = str(block.get("shader", "")).strip()
    return DATA / "lib" / "shaders" / f"{name}.gdshader" if name in SHADER_NAMES else None


def load_json(path: Path):
    """Parse a JSON file. Return None when it is missing or broken."""
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _files_for(path: Path) -> list[Path]:
    """WorldLoader.load_rules_files_for: the folder form wins over the file."""
    folder = path.with_suffix("")
    if folder.is_dir():
        return sorted(p for p in folder.glob("*.json") if p.is_file())
    return [path] if path.is_file() else []


def rule_files(game_dir: Path) -> list[Path]:
    game_dir = Path(game_dir)
    out = _files_for(game_dir / "world" / "rules.json")
    out += _files_for(game_dir / "game" / "goals.json")
    if (game_dir / "tutorial.json").is_file():
        out.append(game_dir / "tutorial.json")
    levels = game_dir / "levels"
    if levels.is_dir():
        for lvl in sorted(p for p in levels.iterdir() if p.is_dir()):
            out += _files_for(lvl / "rules.json")
    return out


class LibResolver:
    """Python port of libs/lib_resolver.gd. An unresolved ref stays in
    place, as in the engine. validate_lib_refs.py reports it."""

    def __init__(self, lib_root: Path = DATA / "lib"):
        self.cache: dict[str, object] = {}
        if lib_root.is_dir():
            for p in sorted(lib_root.rglob("*.json")):
                rel = p.relative_to(lib_root)
                if p.name == "manifest.json" or any(part.startswith(".") for part in rel.parts):
                    continue
                data = load_json(p)
                if data is not None:
                    self.cache[".".join(rel.with_suffix("").parts)] = data

    def resolve(self, value, depth: int = 0, visited: tuple = ()):
        if depth > MAX_DEPTH:
            return value
        if isinstance(value, str):
            return self._ref(value, depth, visited) if value.startswith("@lib.") else value
        if isinstance(value, dict):
            if "$extends" in value:
                return self._extends(value, depth, visited)
            return {str(k): self.resolve(v, depth, visited) for k, v in value.items()}
        if isinstance(value, list):
            out = []
            for item in value:
                if isinstance(item, dict) and "$include" in item:
                    refs = item["$include"] if isinstance(item["$include"], list) else [item["$include"]]
                    for r in refs:
                        got = self.resolve(r, depth + 1, visited)
                        if isinstance(got, list):
                            out += [self.resolve(e, depth + 1, visited) for e in got]
                else:
                    out.append(self.resolve(item, depth, visited))
            return out
        return value

    def _ref(self, ref: str, depth: int, visited: tuple):
        if ref in visited:
            return None
        parts = ref[len("@lib."):].split(".")
        for cut in range(len(parts), 0, -1):
            key = ".".join(parts[:cut])
            if key in self.cache:
                val = self.cache[key]
                for part in parts[cut:]:
                    if not isinstance(val, dict) or part not in val:
                        return ref
                    val = val[part]
                got = self.resolve(copy.deepcopy(val), depth + 1, visited + (ref,))
                if isinstance(got, dict):
                    got["_origin"] = ref
                return got
        return ref

    def _extends(self, d: dict, depth: int, visited: tuple):
        base = self.resolve(d["$extends"], depth + 1, visited)
        if not isinstance(base, dict):
            return d
        merged = copy.deepcopy(base)
        for k, v in d.items():
            if k != "$extends":
                merged[str(k)] = self.resolve(v, depth + 1, visited)
        merged["_origin"] = f"$extends:{d['$extends']}"
        return merged


_RESOLVER: LibResolver | None = None


def resolver() -> LibResolver:
    global _RESOLVER
    if _RESOLVER is None:
        _RESOLVER = LibResolver()
    return _RESOLVER


def iter_rules(game_dir: Path):
    """Yield (path, rule) for every rule the engine loads, after lib
    resolution. A file that fails to parse yields nothing here.
    validate_rules.py reports parse errors."""
    for path in rule_files(game_dir):
        doc = load_json(path)
        if not isinstance(doc, dict):
            continue
        rules = resolver().resolve(doc.get("rules", []))
        if not isinstance(rules, list):
            continue
        for rule in rules:
            if isinstance(rule, dict):
                yield path, rule


def iter_effects(rule: dict):
    """Yield (index, effect) for a rule's `effect`, as a dict or a list."""
    effects = rule.get("effect", [])
    if isinstance(effects, dict):
        effects = [effects]
    if isinstance(effects, list):
        for i, eff in enumerate(effects):
            if isinstance(eff, dict):
                yield i, eff


def game_dirs(args: list[str]) -> list[Path]:
    """The demo folders a validator checks: the named one, or all."""
    names = [a for a in args if not a.startswith("--")]
    if names:
        return [DATA / names[0]]
    return sorted(p for p in DATA.glob("demo_*") if p.is_dir())


def load_resolved(path: Path):
    """A JSON file with its @lib refs resolved, or None when it is
    missing or broken."""
    doc = load_json(path)
    return None if doc is None else resolver().resolve(doc)


def staged_files(game_dir: Path) -> list[Path]:
    """`game/*_staged.json` authoring files, which some checks also scan."""
    return sorted((Path(game_dir) / "game").glob("*_staged.json"))
