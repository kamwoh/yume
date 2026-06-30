"""Environment resolution for the Infinigen backend (ADR 0074).

Infinigen is a HEAVY external authoring dependency (its own Python 3.11 +
`bpy` + git submodules) — it lives OUTSIDE Yume's venv and runtime, like
the Tripo asset-gen backend. Two env vars point at it; absent → the
caller degrades gracefully (no-op + warning), never crashes.

    YUME_INFINIGEN_PYTHON   the infinigen venv's python (3.11 + bpy)
    YUME_INFINIGEN_REPO     the infinigen source repo (cwd for generation)
"""
from __future__ import annotations

import os
from pathlib import Path


class InfinigenUnavailable(RuntimeError):
    pass


def infinigen_python() -> Path:
    p = os.environ.get("YUME_INFINIGEN_PYTHON", "")
    if not p:
        raise InfinigenUnavailable(
            "YUME_INFINIGEN_PYTHON is unset. Point it at the infinigen venv's "
            "python (3.11 + bpy), e.g.\n"
            "  export YUME_INFINIGEN_PYTHON=$HOME/infinigen311/bin/python"
        )
    path = Path(p)
    if not path.exists():
        raise InfinigenUnavailable(f"YUME_INFINIGEN_PYTHON does not exist: {path}")
    return path


def infinigen_repo() -> Path:
    p = os.environ.get("YUME_INFINIGEN_REPO", "")
    if not p:
        raise InfinigenUnavailable(
            "YUME_INFINIGEN_REPO is unset. Point it at the infinigen source repo, e.g.\n"
            "  export YUME_INFINIGEN_REPO=/path/to/infinigen"
        )
    path = Path(p)
    if not (path / "infinigen_examples").exists():
        raise InfinigenUnavailable(
            f"YUME_INFINIGEN_REPO does not look like an infinigen repo: {path}"
        )
    return path


# Default collider derivation (ADR 0072): upright / stalk-shaped props
# (trees, cacti, plants) get a trunk-footprint "base" collider; solid props
# (rocks, shells, creatures, fruit) get a full wrap. Keyword heuristic so it
# covers the whole catalog, not a hand-listed set.
_BASE_COLLIDER_KEYWORDS = (
    "Tree", "Bush", "Branch", "Cactus", "Mushroom", "Flower", "Fern", "Palm",
    "Plant", "Monocot", "Dandelion", "Grass", "Reed", "Wheat", "Maize",
    "Veratrum", "Tussock", "Agave", "Banana", "Succulent", "Seaweed", "Kelp",
)


def default_collider(factory: str) -> str:
    return "base" if any(k in factory for k in _BASE_COLLIDER_KEYWORDS) else "full"


# Foliage factories take the impostor-BILLBOARD path (ADR 0074): Infinigen
# leaves are ~14K faces each and shatter under decimation, so the generator
# bakes one leaf cluster to an alpha card and instances it. Everything else
# takes the solid decimate+bake path.
FOLIAGE_KEYWORDS = ("Tree", "Bush", "Palm", "Coconut")


def is_foliage(factory: str) -> bool:
    return any(k in factory for k in FOLIAGE_KEYWORDS)


# Curated standalone NATURE factories worth surfacing in --help. Not
# exhaustive (the resolver accepts any factory name); these are the
# obviously-useful, known-to-spawn-standalone ones. Internal PART factories
# (CrabClawFactory, MushroomCapFactory, ...BaseFactory) are intentionally
# excluded — they need a parent factory's context.
RECOMMENDED_NATURE = {
    "rocks": ["BoulderFactory", "BoulderPileFactory", "BlenderRockFactory"],
    "trees": ["TreeFactory", "BushFactory", "PalmTreeFactory", "CoconutTreeFactory"],
    "plants": ["CactusFactory", "FernFactory", "SnakePlantFactory",
               "SpiderPlantFactory", "SucculentFactory", "FlowerFactory"],
    "fungi/misc": ["MushroomFactory", "PineconeFactory", "FruitFactory"],
    "creatures": ["BirdFactory", "FishFactory", "FrogFactory", "SnakeFactory",
                  "LizardFactory", "BeetleFactory", "DragonflyFactory", "CrabFactory"],
    "aquatic": ["CoralFactory", "MolluskFactory", "JellyfishFactory", "UrchinFactory"],
    "sky": ["CloudFactory"],
}
