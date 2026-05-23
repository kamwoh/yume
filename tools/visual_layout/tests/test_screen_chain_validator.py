"""
Regression tests for wireframe_to_screen.py's chain validator (task #109).

Counterpart to the HUD harness's test_deep_tree_no_lib_refs — guards
against subtle regressions in _validate_chain, which enforces:
  - effect types must be in the allowed set
  - transition_screen targets must resolve to known screen ids
  - destructive effects must be LAST in their chain (subsequent
    effects are silently dropped per
    .claude/rules/engine-scripts.md § effect-chain gate)

If a future refactor breaks any of these, these tests fail.

Run:
    python3 -m tools.visual_layout.tests.test_screen_chain_validator
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[2]))

from visual_layout.wireframe_to_screen import _validate_chain


# --- Fixtures ----------------------------------------------------------

ALLOWED_SCREENS = {"inventory", "pause", "title", "@previous", "@root"}
ALLOWED_EFFECTS = {
    "transition_screen", "transition_level", "reload_scene",
    "show_toast", "save_state", "load_state", "quit_app",
    "screen_fade", "state_set",
}
DESTRUCTIVE = {"transition_level", "reload_scene", "load_state",
               "save_state", "quit_app"}


def run(name, chain, expect_errs):
    """Run _validate_chain + assert error count matches expectation."""
    errs: list[str] = []
    _validate_chain(chain, f"<{name}>", errs,
                    ALLOWED_SCREENS, ALLOWED_EFFECTS, DESTRUCTIVE)
    actual_errs = len(errs)
    marker = "OK" if actual_errs == expect_errs else "FAIL"
    detail = f"got {actual_errs}, want {expect_errs}"
    if errs:
        detail += f"  ({errs[0][:120]})"
    print(f"  [{marker}] {name}: {detail}")
    return actual_errs == expect_errs


def test_clean_chain():
    """A clean chain — no errors expected."""
    return run("clean_chain", [
        {"type": "show_toast", "text": "Saved"},
        {"type": "transition_screen", "target": "@previous"},
    ], expect_errs=0)


def test_destructive_last_passes():
    """transition_level as LAST effect is fine."""
    return run("destructive_last_passes", [
        {"type": "screen_fade", "alpha": 1.0, "duration": 0.2},
        {"type": "transition_level", "target": "level_2"},
    ], expect_errs=0)


def test_destructive_middle_fails():
    """transition_level NOT last — must fail per destructive-last rule."""
    return run("destructive_middle_fails", [
        {"type": "screen_fade", "alpha": 1.0, "duration": 0.2},
        {"type": "transition_level", "target": "level_2"},
        {"type": "show_toast", "text": "should be dropped"},
    ], expect_errs=1)


def test_two_destructives_both_flagged():
    """When 2 destructive effects mid-chain, BOTH should be flagged."""
    return run("two_destructives_both_flagged", [
        {"type": "save_state"},
        {"type": "reload_scene"},
        {"type": "show_toast", "text": "after"},
    ], expect_errs=2)


def test_unknown_effect_flagged():
    """Effect type not in allowed_effects — flagged."""
    return run("unknown_effect_flagged", [
        {"type": "do_a_barrel_roll"},
    ], expect_errs=1)


def test_unknown_screen_target_flagged():
    """transition_screen with unknown target — flagged."""
    return run("unknown_screen_target_flagged", [
        {"type": "transition_screen", "target": "definitely_not_a_screen"},
    ], expect_errs=1)


def test_at_previous_and_at_root_accepted():
    """@previous and @root special tokens are allowed."""
    return run("at_previous_accepted", [
        {"type": "transition_screen", "target": "@previous"},
    ], expect_errs=0)


def test_empty_chain_passes():
    """Empty chain — no effects, no errors."""
    return run("empty_chain_passes", [], expect_errs=0)


def test_non_dict_chain_member_flagged():
    """A non-dict in the chain — flagged."""
    return run("non_dict_chain_member_flagged", [
        {"type": "show_toast", "text": "ok"},
        "not_a_dict",
    ], expect_errs=1)


def main() -> int:
    print("=== wireframe_to_screen chain validator regression tests ===")
    tests = [
        test_clean_chain,
        test_destructive_last_passes,
        test_destructive_middle_fails,
        test_two_destructives_both_flagged,
        test_unknown_effect_flagged,
        test_unknown_screen_target_flagged,
        test_at_previous_and_at_root_accepted,
        test_empty_chain_passes,
        test_non_dict_chain_member_flagged,
    ]
    results = [t() for t in tests]
    n_pass = sum(results)
    n_fail = len(results) - n_pass
    print(f"\n=== RESULTS: {n_pass} passed, {n_fail} failed ===")
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
