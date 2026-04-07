"""Configuration management — paths, settings."""

from __future__ import annotations

import os
from pathlib import Path

from pydantic import BaseModel, Field


# Default to Windows Godot projects dir if available (WSL), else ~/yume-output
_WINDOWS_GODOT_DIR = Path("/mnt/c/Users/kamwoh/Documents/Projects/Godot")
_DEFAULT_OUTPUT_DIR = _WINDOWS_GODOT_DIR if _WINDOWS_GODOT_DIR.exists() else Path.home() / "yume-output"


class YumeConfig(BaseModel):
    """Runtime configuration loaded from env vars and CLI flags."""

    # Paths
    output_dir: Path = Field(default=_DEFAULT_OUTPUT_DIR, description="Where generated Unity projects go")
    lessons_dir: Path = Field(default=Path.home() / ".yume" / "lessons", description="Lesson knowledge base")

    # Unity
    unity_version: str = Field(default="6000.0", description="Target Unity version")

    # Generation
    model: str = Field(default="", description="Claude model override (empty = use default)")
    max_retries: int = Field(default=3, description="Max retries on validation failure")


def load_config(**overrides: object) -> YumeConfig:
    """Load config from environment variables, with optional CLI overrides."""
    env_values: dict[str, object] = {}

    if path := os.environ.get("YUME_OUTPUT_DIR"):
        env_values["output_dir"] = Path(path)
    if model := os.environ.get("YUME_MODEL"):
        env_values["model"] = model

    # CLI overrides take precedence
    merged = {**env_values, **{k: v for k, v in overrides.items() if v is not None}}
    return YumeConfig(**merged)
