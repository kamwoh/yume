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
- `KEY_NAMES`, `MOUSE_BUTTONS`, `AUDIO_CHANNELS`, `SCENE_FIELDS`,
  `BODY_TYPES`, `PHYSICS_FIELDS` and `LAYER_NAMES` read the ADR 0090
  vocabularies from the engine files that own them.
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


# ADR 0090 vocabularies. The engine files are the source.
_ENGINE = REPO / "godot" / "scripts" / "engine"


def _gd(rel: str) -> str:
    return (_ENGINE / rel).read_text(encoding="utf-8")


def _gd_block(src: str, const: str) -> str:
    """The text of a GDScript `const NAME := {...}` or `[...]` value."""
    m = re.search(rf"const {const}(?::\s*\w+)?\s*:?=\s*", src)
    start = m.end()
    opener = src[start]
    closer = {"{": "}", "[": "]"}[opener]
    depth = 0
    for i in range(start, len(src)):
        depth += {opener: 1, closer: -1}.get(src[i], 0)
        if depth == 0:
            return src[start:i + 1]
    raise ValueError(f"unclosed const {const}")


def _gd_keys(src: str, const: str) -> tuple[str, ...]:
    """The string keys of a GDScript dict const, in order."""
    return tuple(re.findall(r'"([^"]+)"\s*:', _gd_block(src, const)))


def _gd_strings(src: str, const: str) -> tuple[str, ...]:
    """The strings of a GDScript array const, in order."""
    return tuple(re.findall(r'"([^"]+)"', _gd_block(src, const)))


_INPUT_KEYS = _gd("io/input_keys.gd")
KEY_NAMES = _gd_keys(_INPUT_KEYS, "KEYS")
MOUSE_BUTTONS = _gd_keys(_INPUT_KEYS, "MOUSE_BUTTONS")
AUDIO_CHANNELS = _gd_keys(_gd("io/audio_channels.gd"), "CHANNELS")
_LIGHTING = _gd("directors/lighting_director.gd")
SCENE_FIELDS: dict[str, list[str]] = json.loads(_gd_block(_LIGHTING, "FIELDS"))
SCENE_HOST_HINTS = _gd_strings(_LIGHTING, "HOST_HINTS")
_PHYSICS = _gd("coordinators/physics_body_builder.gd")
BODY_TYPES = _gd_strings(_PHYSICS, "BODY_TYPES")
PHYSICS_FIELDS = _gd_strings(_PHYSICS, "FIELDS")
_ARTICULATED = _gd("coordinators/articulated_body.gd")
JOINT_TYPES = _gd_strings(_ARTICULATED, "JOINT_TYPES")
LINK_FIELDS = _gd_strings(_ARTICULATED, "LINK_FIELDS")
JOINT_FIELDS = _gd_strings(_ARTICULATED, "JOINT_FIELDS")
MOTOR_FIELDS = _gd_strings(_ARTICULATED, "MOTOR_FIELDS")
SHAPE_AXES = _gd_strings(_ARTICULATED, "SHAPE_AXES")
_SENSORS = _gd("coordinators/sensor_array.gd")
SENSOR_TYPES = _gd_strings(_SENSORS, "SENSOR_TYPES")
SENSOR_FIELDS = _gd_strings(_SENSORS, "SENSOR_FIELDS")
CAMERA_HEADINGS = _gd_strings(_gd("ui/widgets/camera_director.gd"), "HEADING_SOURCES")
LAYER_NAMES = tuple(json.loads((DATA / "lib" / "physics" / "layers.json").read_text(encoding="utf-8"))["layers"])


def articulation_problems(phys: dict) -> list[str]:
    """Port of ArticulatedBody._check plus the ADR 0091 field lists: the
    problems of an articulated `physics` block, as "field: problem"."""
    links = phys.get("links")
    if not isinstance(links, dict) or not links:
        return ["links: an articulated body needs a 'links' object"]
    out = []
    root = phys.get("root")
    if root not in links:
        out.append(f"root: '{root}' is not a link")
    for name, link in links.items():
        if not isinstance(link, dict):
            out.append(f"links.{name}: a link is an object")
            continue
        out += [f"links.{name}.{k}: a link has no such field" for k in link
                if not str(k).startswith("_") and k not in LINK_FIELDS]
        shape = link.get("shape", {})
        if isinstance(shape, dict) and shape.get("axis", "y") not in SHAPE_AXES:
            out.append(f"links.{name}.shape.axis: '{shape['axis']}' is not one of {', '.join(SHAPE_AXES)}")
    parent_of: dict = {}
    for i, j in enumerate(phys.get("joints", [])):
        where = f"joints[{i}]"
        if not isinstance(j, dict):
            out.append(f"{where}: a joint is an object")
            continue
        out += [f"{where}.{k}: a joint has no such field" for k in j
                if not str(k).startswith("_") and k not in JOINT_FIELDS]
        jt = j.get("type")
        if jt not in JOINT_TYPES:
            out.append(f"{where}.type: '{jt}' is not a joint type. The types are: {', '.join(JOINT_TYPES)}")
        for k in ("axis", "limit", "motor", "report"):
            if k in j and jt != "hinge":
                out.append(f"{where}.{k}: only a hinge joint has '{k}'")
        if isinstance(j.get("motor"), dict):
            out += [f"{where}.motor.{k}: a motor has no such field" for k in j["motor"]
                    if not str(k).startswith("_") and k not in MOTOR_FIELDS]
        p, c = j.get("parent"), j.get("child")
        if p not in links or c not in links:
            out.append(f"{where}: parent '{p}' and child '{c}' must both be links")
        elif c == root or c in parent_of:
            out.append(f"{where}: link '{c}' has more than one parent")
        else:
            parent_of[c] = p
    for name in links:
        seen, cur = set(), name
        while cur != root and cur in parent_of and cur not in seen:
            seen.add(cur)
            cur = parent_of[cur]
        if cur != root and root in links:
            out.append(f"links.{name}: the link does not connect to the root")
    return out


def sensor_problems(sensors, phys) -> list[str]:
    """The ADR 0092 problems of a def's `sensors` list, as "field: problem".
    `phys` is the def's resolved physics block (or None)."""
    if not isinstance(sensors, list):
        return ["sensors: the field is a list"]
    links = phys.get("links", {}) if isinstance(phys, dict) and phys.get("body_type") == "articulated" else {}
    out = []
    for i, s in enumerate(sensors):
        where = f"sensors[{i}]"
        if not isinstance(s, dict):
            out.append(f"{where}: a sensor is an object")
            continue
        out += [f"{where}.{k}: a sensor has no such field" for k in s
                if not str(k).startswith("_") and k not in SENSOR_FIELDS]
        if s.get("type") not in SENSOR_TYPES:
            out.append(f"{where}.type: '{s.get('type')}' is not a sensor type. The types are: {', '.join(SENSOR_TYPES)}")
        if not s.get("report"):
            out.append(f"{where}.report: a sensor needs a report name")
        for k in ("rays", "fov"):
            if k in s and s.get("type") != "lidar":
                out.append(f"{where}.{k}: only a lidar has '{k}'")
        if "link" in s and s["link"] not in links:
            out.append(f"{where}.link: '{s['link']}' is not a link of an articulated body")
        mask = s.get("collision_mask", "all")
        if mask != "all":
            for name in mask if isinstance(mask, list) else [mask]:
                if name not in LAYER_NAMES:
                    out.append(f"{where}.collision_mask: '{name}' is not a layer name")
    return out


def unknown_scene_fields(scene: dict) -> list[str]:
    """Port of LightingDirector.unknown_fields: dotted paths of the
    `lighting` and `render` fields that SCENE_FIELDS does not list."""
    out = []
    for path, allowed in SCENE_FIELDS.items():
        is_list = path.endswith("[]")
        node = scene
        for part in path.removesuffix("[]").split("."):
            node = node.get(part) if isinstance(node, dict) else None
        blocks = node if is_list and isinstance(node, list) else [node] if not is_list and isinstance(node, dict) else []
        for block in blocks:
            if isinstance(block, dict):
                out += [f"{path}.{k}" for k in block if not str(k).startswith("_") and k not in allowed]
    return out


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
