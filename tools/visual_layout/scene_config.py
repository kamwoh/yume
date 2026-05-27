"""scene_config.py — per-scene "variables" for the text-to-world pipeline.

Everything that differs between scenes (world scale, terrain amplitude,
biome display colours, lighting mood, player spawn) lives in ONE optional
file per game: `godot/data/<game>/scene_config.json`. Both compose_world
(map layer) and compose_shell (presentation layer) read it.

Precedence, lowest → highest:
  built-in default  <  scene_config.json  <  explicit CLI flag

So a CLI flag always wins (quick experiments), the config carries the
scene's settled values (reproducible, version-controlled per demo), and
the built-in default is the fallback when neither is set.

Schema (all keys optional):
{
  "world":   {"size_m": [140, 140], "target_house_m": 8.5, "rng_seed": 42},
  "terrain": {"height_scale": 10.0, "height_offset": -0.5,
              "noise_amount": 0.12, "blend_softness": 0.12},
  "water":   {"level": null},
  "biomes":  {"grass": "#79b048", "...": "#rrggbb"},   // display colour overrides
  "lighting": { ...partial or full override of compose_shell._lighting_block... },
  "player":  {"spawn": [0, null, 10]}   // null Y → auto-clearance from height_scale
}
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def load_scene_config(game_dir: Path) -> dict:
    """Return the parsed scene_config.json for a game dir, or {} if absent."""
    p = Path(game_dir) / "scene_config.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as e:
        raise SystemExit(f"[scene_config] {p} is not valid JSON: {e}")


def resolve(cli_value: Any, cfg: dict, *path: str, default: Any = None) -> Any:
    """Resolve one value by precedence: CLI > config[path] > default.

    `cli_value` is the argparse value; pass None for "not supplied" (so set
    the argparse default to None for any flag that participates here).
    `path` walks nested config keys, e.g. resolve(args.height_scale, cfg,
    "terrain", "height_scale", default=3.0).
    """
    if cli_value is not None:
        return cli_value
    node: Any = cfg
    for key in path:
        if isinstance(node, dict) and key in node:
            node = node[key]
        else:
            return default
    return node


def deep_merge(base: dict, override: dict) -> dict:
    """Recursively merge `override` onto a copy of `base` (override wins).
    Used to layer a scene_config lighting block over the built-in default."""
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out
