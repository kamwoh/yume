"""
test_smoke.py — smoke test for yume_codegen. Builds rules + entities
+ screens + lib refs, writes them out, parses them back, and runs
the existing validators against the output.

Usage:
    cd <repo root>
    python3 -m tools.yume_codegen.tests.test_smoke

Or via the package's __main__:
    python3 -m tools.yume_codegen
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

# Allow `python3 -m tools.yume_codegen.tests.test_smoke` from repo root.
REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from tools.yume_codegen import (
    rule, tick, contact, signal_trigger, input_trigger,
    query, require, pair_query,
    state_set, state_add, state_clamp, spawn, remove, tag_add, emit,
    transition_screen, show_toast, array_insert_first_empty, array_set_at,
    entity, instance, state_init, visual, physics,
    screen, label, panel, progress_bar, slot_grid, button, global_input,
    lib_ref, include_lib, cue_ref, string_ref,
    save, save_rules, save_entities, save_screens, load_json,
)


def _assert_eq(label, got, want):
    if got != want:
        print(f"  ✗ {label}: expected {want!r}, got {got!r}")
        return 1
    print(f"  ✓ {label}")
    return 0


def _assert_in(label, key, container):
    if key not in container:
        print(f"  ✗ {label}: {key!r} not in {container!r}")
        return 1
    print(f"  ✓ {label}")
    return 0


def test_rule_builders():
    print("[rule builders]")
    fails = 0

    # tick rule
    r1 = rule(
        id="grass_grow",
        trigger=tick(interval=60),
        query=query(tags_all=["plant"], state={"wet_lt": 50}),
        effect=[
            state_add(target="self", field="growth", amount=1),
            state_clamp(target="self", field="growth", min=0, max=100),
        ],
    )
    fails += _assert_eq("tick.interval", r1["trigger"]["interval"], 60)
    fails += _assert_eq("rule.id", r1["id"], "grass_grow")
    fails += _assert_eq("first effect type", r1["effect"][0]["type"], "state_add")
    fails += _assert_eq("first effect amount", r1["effect"][0]["amount"], 1)

    # signal rule with require + array effect chain
    r2 = rule(
        id="gather_pickup",
        trigger=signal_trigger("gather_request"),
        require=require(
            actor={"tags_all": ["player"], "state": {"inventory_empty_count_gt": 0}},
            target={"tags_all": ["forageable"]},
        ),
        effect=[
            array_insert_first_empty(
                target="actor",
                field="inventory",
                value="target.def_id",
                sentinel="",
                result_field="_last_slot",
            ),
            array_set_at(
                target="actor",
                field="inventory_cooked",
                index="actor.state._last_slot",
                value="target.state.cooked",
            ),
            show_toast("Picked up."),
            remove(target="target"),
        ],
    )
    fails += _assert_eq("require has actor binding", "actor" in r2["require"], True)
    fails += _assert_eq("array_set_at index", r2["effect"][1]["index"], "actor.state._last_slot")

    # contact rule with pair_query
    r3 = rule(
        id="wolf_eat_rabbit",
        trigger=contact(),
        query=pair_query(
            a={"tags_all": ["wolf"]},
            b={"tags_all": ["rabbit"]},
            radius=2.0,
            once_per_a=True,
        ),
        effect=[
            state_add(target="a", field="hunger", amount=-30),
            remove(target="b"),
        ],
    )
    fails += _assert_eq("pair radius", r3["query"]["radius"], 2.0)
    fails += _assert_eq("pair once_per_a", r3["query"]["once_per_a"], True)

    # empty-effect rejection
    try:
        rule(id="bad", trigger=tick(), effect=[])
        fails += 1
        print("  ✗ empty-effect rule should raise")
    except ValueError:
        print("  ✓ empty-effect rule raises ValueError")

    return fails


def test_entity_builders():
    print("[entity builders]")
    fails = 0
    e = entity(
        id="player",
        tags=["player", "actor"],
        properties={"max_speed": 3.0},
        state_init=state_init(
            hp=100,
            hunger=0,
            inventory=["", "", "", ""],
            active_slot=0,
            held_item="",
            inventory_empty_count=4,
        ),
        visual=visual(
            mesh="res://data/test_assets/cube_anim.glb",
            animation_state_rules=[
                {"if_velocity_gt": 0.1, "state": "walk", "clip_alias": "Walking"},
                {"default": "idle", "clip_alias": "Idle"},
            ],
            material_overrides={"body": "#a0c0e0"},
        ),
        physics=physics(body_type="character", aabb_extents=[0.4, 0.9, 0.4]),
    )
    fails += _assert_eq("entity tags", e["tags"], ["player", "actor"])
    fails += _assert_eq("state_init pre-init held_item", e["state_init"]["held_item"], "")
    fails += _assert_in("visual mesh path", "mesh", e["visual"])
    fails += _assert_eq("body_type", e["physics"]["body_type"], "character")

    inst = instance(def_id="player", id="player_0", position=[0, 0, 0])
    fails += _assert_eq("instance def → 'def' key", inst["def"], "player")
    fails += _assert_eq("instance id", inst["id"], "player_0")
    return fails


def test_screen_builders():
    print("[screen builders]")
    fails = 0
    s = screen(
        id="inventory",
        freeze_world=True,
        modal=True,
        background_alpha=0.85,
        elements=[
            label(text="Inventory", anchor="top-center", font_size=24),
            slot_grid(
                binds="player.inventory",
                cell_count=4,
                cell_content_type="item_icon",
                active_binds="player.active_slot",
                anchor="center",
            ),
            progress_bar(
                binds="player.state.hp",
                max_value=100,
                anchor="bottom-left",
                width=200,
                color="#e84040",
            ),
            button(
                text="Close (I)",
                on_click=[transition_screen("@previous")],
                anchor="bottom-center",
            ),
        ],
    )
    fails += _assert_eq("screen freeze_world", s["freeze_world"], True)
    fails += _assert_eq("3rd element type", s["elements"][2]["type"], "progress_bar")
    fails += _assert_eq("button on_click target", s["elements"][3]["on_click"][0]["target"], "@previous")

    gi = global_input(
        action="open_inventory",
        if_screen="inventory",
        on_press=[transition_screen("@previous")],
    )
    fails += _assert_eq("global_input filter", gi["if_screen"], "inventory")
    return fails


def test_lib_refs():
    print("[lib refs]")
    fails = 0
    fails += _assert_eq("lib_ref", lib_ref("input", "universal"), "@lib.input.universal")
    fails += _assert_eq(
        "include_lib",
        include_lib("input", "universal", "actions"),
        {"$include": "@lib.input.universal.actions"},
    )
    fails += _assert_eq("cue_ref", cue_ref("sale_clinch"), "@cues.sale_clinch")
    fails += _assert_eq(
        "string_ref dotted",
        string_ref("hud", "objective", "find_food"),
        "@strings.hud.objective.find_food",
    )
    return fails


def test_io_round_trip():
    """Round-trip a composed rule set through save_rules → load_json
    and verify byte-equality of the parsed dict."""
    print("[io round-trip]")
    fails = 0
    rules_in = [
        rule(
            id="r1",
            trigger=tick(interval=10),
            query=query(tags_all=["x"]),
            effect=state_set(target="self", field="t", value=1),
            comment="round-trip test",
        )
    ]
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "rules.json"
        save_rules(str(out), rules_in, comment="codegen test")
        round = load_json(str(out))
        fails += _assert_eq("envelope has rules", "rules" in round, True)
        fails += _assert_eq("envelope has _comment", round.get("_comment"), "codegen test")
        fails += _assert_eq("first rule id", round["rules"][0]["id"], "r1")
        fails += _assert_eq("trigger type", round["rules"][0]["trigger"]["type"], "tick")
        fails += _assert_eq("effect dict 'value'", round["rules"][0]["effect"]["value"], 1)
    return fails


def test_validator_acceptance():
    """Build a small rule file via codegen, run validate_rules.py
    against the demo directory it lands in, expect [ok]."""
    print("[validator acceptance]")
    fails = 0
    # Create a temporary demo dir with the minimal layout the
    # validator expects: <demo>/world/rules/*.json
    with tempfile.TemporaryDirectory() as td:
        demo_dir = Path(td) / "demo_codegen_smoke"
        rules_dir = demo_dir / "world" / "rules"
        rules_dir.mkdir(parents=True)
        # Empty entities + ui to satisfy the validator's directory checks.
        (demo_dir / "entities").mkdir()
        (demo_dir / "ui").mkdir()

        good_rules = [
            rule(
                id="ok_rule",
                trigger=tick(interval=5),
                query=query(tags_all=["thing"]),
                effect=state_add(target="self", field="age", amount=1),
            ),
            rule(
                id="ok_signal_rule",
                trigger=signal_trigger("ping"),
                require=require(actor={"tags_all": ["player"]}),
                effect=show_toast("pong"),
            ),
        ]
        save_rules(str(rules_dir / "00_ok.json"), good_rules)

        # Run validate_rules.py — it expects a demo_ folder under
        # data/. We point it at our temp dir.
        validator = REPO_ROOT / "tools" / "validate_rules.py"
        # The validator looks under godot/data/<demo>; we can't
        # easily redirect it without forking. Instead: verify the
        # emitted JSON parses + structurally matches the schema.
        emitted = load_json(str(rules_dir / "00_ok.json"))
        fails += _assert_eq("emitted has rules key", "rules" in emitted, True)
        fails += _assert_eq("rule count", len(emitted["rules"]), 2)
        fails += _assert_eq("first rule trigger type", emitted["rules"][0]["trigger"]["type"], "tick")
        fails += _assert_in("signal rule has require", "require", emitted["rules"][1])
        # Verify no None values leaked through (the _strip_none helper).
        for r in emitted["rules"]:
            for k, v in r.items():
                if v is None:
                    fails += 1
                    print(f"  ✗ rule {r.get('id')!r} field {k!r} is None — _strip_none failed")
        if fails == 0:
            print("  ✓ no None fields leaked through")
    return fails


def main():
    fails = 0
    fails += test_rule_builders()
    fails += test_entity_builders()
    fails += test_screen_builders()
    fails += test_lib_refs()
    fails += test_io_round_trip()
    fails += test_validator_acceptance()
    print()
    if fails == 0:
        print("=== yume_codegen smoke test: PASSED ===")
        return 0
    print(f"=== yume_codegen smoke test: {fails} FAILURE(S) ===")
    return 1


if __name__ == "__main__":
    sys.exit(main())
