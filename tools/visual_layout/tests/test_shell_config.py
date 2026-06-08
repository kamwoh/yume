"""Tests for the compose_shell jump/gravity generation knob (2026-06-08).

scene_config.json's "shell" block sets the INITIAL jump feel written into
the scaffolded shell, instead of compose_shell hard-coding 7.0 / 18.0.
Defaults must stay 7.0 / 18.0 (no behavior change for existing scaffolds).

Run: python3 -m pytest tools/visual_layout/tests/test_shell_config.py
"""
import json
import tempfile
from pathlib import Path

from tools.visual_layout import scene_config as scfg
from tools.visual_layout import compose_shell as cs


def _emitted(cfg):
    g = cs._player_def(gravity=cfg.shell.gravity)[
        "definitions"][0]["state_init"]["gravity"]
    imp = cs._jump_rules(jump_impulse=cfg.shell.jump_impulse)[
        "rules"][0]["effect"][0]["value"]
    return g, imp


def test_defaults_unchanged():
    cfg = scfg.SceneConfig.load(Path(tempfile.mkdtemp()))  # no scene_config.json
    assert (cfg.shell.jump_impulse, cfg.shell.gravity) == (7.0, 18.0)
    assert _emitted(cfg) == (18.0, 7.0)


def test_full_override():
    d = Path(tempfile.mkdtemp())
    (d / "scene_config.json").write_text(
        json.dumps({"shell": {"jump_impulse": 11.0, "gravity": 9.0}}))
    cfg = scfg.SceneConfig.load(d)
    assert (cfg.shell.jump_impulse, cfg.shell.gravity) == (11.0, 9.0)
    assert _emitted(cfg) == (9.0, 11.0)


def test_partial_override_keeps_other_default():
    d = Path(tempfile.mkdtemp())
    (d / "scene_config.json").write_text(json.dumps({"shell": {"gravity": 6.0}}))
    cfg = scfg.SceneConfig.load(d)
    assert cfg.shell.jump_impulse == 7.0   # untouched default
    assert cfg.shell.gravity == 6.0


def test_unknown_shell_key_ignored():
    d = Path(tempfile.mkdtemp())
    (d / "scene_config.json").write_text(
        json.dumps({"shell": {"gravity": 5.0, "_comment": "x", "bogus": 1}}))
    cfg = scfg.SceneConfig.load(d)
    assert cfg.shell.gravity == 5.0
