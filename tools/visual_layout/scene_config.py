"""scene_config.py — per-scene "variables" for the text-to-world pipeline.

Everything that differs between scenes (world scale, terrain amplitude,
biome display colours, lighting mood, player spawn) lives in ONE optional
file per game: `godot/data/<game>/scene_config.json`. Both compose_world
(map layer) and compose_shell (presentation layer) read it.

Precedence, lowest → highest:
  dataclass default  <  scene_config.json  <  explicit CLI flag

The dataclasses below ARE the built-in defaults — a missing config (or a
missing key) falls back to the field default; a present key overrides it;
a CLI flag (passed as non-None to `pick`) overrides everything.

JSON shape (every key optional; unknown keys like "_comment" ignored):
{
  "world":   {"size_m": [140, 140], "target_house_m": 8.5, "rng_seed": 42},
  "terrain": {"height_scale": 10.0, "height_offset": -0.5,
              "noise_amount": 0.12, "blend_softness": 0.12,
              "single_biome": false},  // true → clean grass-only ground
                                       //   (no multi-biome splatmap paints)
  "water":   {"level": null},
  "biomes":  {"grass": "#79b048"},
  "lighting": { ...partial/full override of compose_shell._lighting_block... },
  "player":  {"spawn": [0, null, 10]}   // null Y → auto terrain clearance
}
"""
from __future__ import annotations

import dataclasses
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class WorldConfig:
    size_m: list[float] | None = None      # None → derive from target_house_m
    target_house_m: float = 5.0
    rng_seed: int = 42


@dataclass
class TerrainConfig:
    height_scale: float = 3.0
    height_offset: float = -0.5
    noise_amount: float = 0.12
    blend_softness: float = 0.12
    # When true, the ground renders as a SINGLE grass biome (clean uniform
    # grass + the painterly slope-shading/detail/flowers) instead of the
    # multi-biome splatmap — no path/region coloring on the ground. The
    # water plane (a separate ADR-0059 surface) is unaffected.
    single_biome: bool = False
    # When set, the ground uses a SEPARATE shader that paints the floor
    # with this image (sampled as planar-UV albedo) instead of the biome
    # classifier. Intended for the hero-conditioned orthographic — it
    # bakes the hero's painterly grass/rocks/paths/water onto the floor
    # in one step. Path is relative to godot/data/<game>/ (e.g.
    # "assets/reference/orthographic.png"). Overrides single_biome.
    albedo_image: str | None = None


@dataclass
class WaterConfig:
    level: float | None = None             # None → derive from heightmap


@dataclass
class PlayerConfig:
    # [x, y, z]; a null/None Y means "auto terrain clearance" (compose_shell
    # drops the player just above the displaced ground).
    spawn: list = field(default_factory=lambda: [0.0, None, 10.0])


@dataclass
class SceneConfig:
    world: WorldConfig = field(default_factory=WorldConfig)
    terrain: TerrainConfig = field(default_factory=TerrainConfig)
    water: WaterConfig = field(default_factory=WaterConfig)
    player: PlayerConfig = field(default_factory=PlayerConfig)
    biomes: dict[str, str] = field(default_factory=dict)   # class → "#rrggbb"
    lighting: dict = field(default_factory=dict)            # _lighting_block override

    @classmethod
    def load(cls, game_dir: Path) -> "SceneConfig":
        """Parse <game_dir>/scene_config.json into a SceneConfig, or return
        all-defaults if the file is absent."""
        p = Path(game_dir) / "scene_config.json"
        if not p.exists():
            return cls()
        try:
            raw = json.loads(p.read_text())
        except json.JSONDecodeError as e:
            raise SystemExit(f"[scene_config] {p} is not valid JSON: {e}")
        return cls(
            world=_build(WorldConfig, raw.get("world")),
            terrain=_build(TerrainConfig, raw.get("terrain")),
            water=_build(WaterConfig, raw.get("water")),
            player=_build(PlayerConfig, raw.get("player")),
            biomes=raw.get("biomes", {}) or {},
            lighting=raw.get("lighting", {}) or {},
        )


def _build(cls, d: dict | None):
    """Construct a dataclass from a dict, ignoring keys that aren't fields
    (so a stray "_comment" or future key never crashes the loader)."""
    names = {f.name for f in dataclasses.fields(cls)}
    return cls(**{k: v for k, v in (d or {}).items() if k in names})


def pick(cli_value: Any, cfg_value: Any) -> Any:
    """CLI > config. Returns cli_value unless it's None (flag not supplied),
    in which case the config/default value wins."""
    return cli_value if cli_value is not None else cfg_value


def deep_merge(base: dict, override: dict) -> dict:
    """Recursively merge `override` onto a copy of `base` (override wins).
    Layers a scene_config lighting block over the built-in default."""
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out
