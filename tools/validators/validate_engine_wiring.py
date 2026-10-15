#!/usr/bin/env python3
"""
Static validator for ENGINE-INTERNAL wiring: vocabulary the engine
advertises but does not actually implement.

Unlike every other validator here, this one checks the ENGINE, not game
content. It exists because two dead entries shipped and survived
undetected — both invisible to content validators, because the content was
correct and the engine simply ignored it.

  (1) DEAD TRIGGER. `"scheduled"` sat in Rule.VALID_TRIGGERS with no
      matching `rules_by_trigger.get("scheduled")` anywhere in
      phase_scheduler.gd. A rule declaring it registered cleanly, passed
      Rule.validate_all, passed every validator, and NEVER FIRED, with
      zero diagnostics. Found 2026-08-16 while designing ADR 0078; it had
      been dead since the trigger list was written.

  (2) DEAD RULE FIELD. `Rule.scope` was parsed in from_dict and read by
      nothing. An author setting it got silence. Found in the same audit;
      ADR 0079 gives it meaning.

Both are the same failure class: the vocabulary promises a verb the
interpreter doesn't implement. Content can't detect it, tests don't cover
it (nobody writes a test for a feature they think exists), and the symptom
is silence.

Checks:
  A. Every entry in Rule.VALID_TRIGGERS has a dispatcher in
     phase_scheduler.gd — i.e. `rules_by_trigger.get("<trigger>"` appears,
     OR the trigger is dispatched by name through the lifecycle path.
  B. Every field assigned in Rule.from_dict is read somewhere in
     scripts/engine outside rule.gd itself.
  C. ADR 0085 vocabulary allowlist (2026-10-16). Each effect type in
     effect_apply.gd, each director that world_boot.gd mounts and each
     formula root in formula_context is in engine_vocabulary.json, and
     the reverse. Each entry names an ADR whose status is accepted and
     whose text names the item, or it is "legacy". The legacy set can
     only shrink.

     Empirical case: 16 genre effects (declare_war, learn_from_master,
     ...) and 5 directors shipped under ADRs that stayed "proposed", and
     no demo ever used them. The no-genre-leak grep missed them, because
     it is a blocklist of other names. ADR 0085 deleted them.

Usage:
    python3 tools/validators/validate_engine_wiring.py
    python3 tools/validators/validate_engine_wiring.py --strict   # exit 1

Takes no game argument — it validates the engine. run_all.py passes a game
name to every validator, so extra positional args are ignored.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gen_api_manifest import parse_effects  # noqa: E402

# Triggers dispatched by NAME through _dispatch_lifecycle_inline rather than
# by a literal rules_by_trigger.get("<name>") call.
LIFECYCLE_DISPATCHED = {"spawn", "despawn"}

# Rule fields consumed via reflection / serialisation rather than a direct
# `rule.<field>` read. Keep this list short and justified.
REFLECTION_READ: dict[str, str] = {
    "id": "read everywhere, including by get_rule_by_id and error payloads",
    "trigger": "read via trigger_type() / trigger_param()",
    "effects": "read by _fire_effects",
    "before_hints": "read by runs_after during topo sort",
    "after_hints": "read by runs_after during topo sort",
}


# Items from before ADR 0085 that no accepted ADR names. Frozen: an item
# can leave this set (give it an ADR, or delete it), but a new one cannot
# join, so every new vocabulary item needs an accepted ADR.
LEGACY_BASELINE = frozenset({
    "LightingDirector", "NameplateRenderer", "ScreenSmokeRunner", "SettingsManager",
    "array_count_matching", "array_insert_first_empty", "array_set_at",
    "from_sq", "refresh_screen", "scene_change", "screen_fade", "state_mul",
    "to_sq", "velocity_lerp",
})


def engine_vocabulary(engine: Path) -> dict[str, list[str]]:
    """The effect types, auto-mounted directors and formula roots that the
    engine has today, read from its sources."""
    effects = [e["type"] for e in parse_effects((engine / "core" / "effect_apply.gd").read_text())]
    boot = (engine / "coordinators" / "world_boot.gd").read_text()
    block = boot[boot.index("const _DEFAULT_DIRECTORS"):]
    directors = re.findall(r'\["(\w+)", "res://', block[:block.index("]\n\n")])
    res = (engine / "core" / "effects" / "effect_resolution.gd").read_text()
    fc = res[res.index("static func formula_context"):]
    fc = fc[:fc.index("\nstatic func", 10)]
    roles = re.search(r"entity_roles: Array\[String\] = \[(.*?)\]", fc, re.S).group(1)
    roots = set(re.findall(r'out\["(\w+)"\]', fc)) | set(re.findall(r'"(\w+)"', roles))
    return {"effects": effects, "directors": directors, "formula_roots": sorted(roots)}


def _accepted(status: str) -> bool:
    st = status.replace("*", "").strip().lower()
    return st.startswith(("accepted", "accept-with", "accept with"))


def check_vocabulary(repo: Path, engine: Path) -> list[str]:
    errors: list[str] = []
    allow = json.loads((repo / "tools" / "validators" / "engine_vocabulary.json").read_text())
    have = engine_vocabulary(engine)
    for kind, items in have.items():
        listed = allow.get(kind, {})
        for item in items:
            if item not in listed:
                errors.append(
                    f"{kind}: `{item}` is in the engine but not in engine_vocabulary.json. "
                    f"Add it with the accepted ADR that names it (ADR 0085)."
                )
        for item, adr in listed.items():
            if item not in items:
                errors.append(f"{kind}: engine_vocabulary.json lists `{item}`, which the engine no longer has.")
                continue
            if adr == "legacy":
                if item not in LEGACY_BASELINE:
                    errors.append(
                        f"{kind}: `{item}` is a new legacy entry. New vocabulary needs an accepted ADR."
                    )
                continue
            files = sorted((repo / "docs" / "adr").glob(f"{adr}-*.md"))
            if not files:
                errors.append(f"{kind}: `{item}` names ADR {adr}, which has no file in docs/adr/.")
                continue
            text = files[0].read_text()
            m = re.search(r"^_?\**Status:?\**:?\s*(.*)$", text, re.M)
            if not m or not _accepted(m.group(1)):
                errors.append(f"{kind}: `{item}` names ADR {adr}, whose status is not accepted.")
            if not re.search(r"[`\"']" + re.escape(item) + r"[`\"'(]", text):
                errors.append(f"{kind}: `{item}` names ADR {adr}, but that ADR does not name it.")
    return errors


def main() -> int:
    strict = "--strict" in sys.argv
    repo = Path(__file__).resolve().parent.parent.parent
    engine = repo / "godot" / "scripts" / "engine"
    rule_gd = engine / "core" / "rule.gd"
    sched_gd = engine / "core" / "phase_scheduler.gd"

    if not rule_gd.is_file() or not sched_gd.is_file():
        print("[validate_engine_wiring] engine sources not found — skipping")
        return 0

    rule_src = rule_gd.read_text()
    sched_src = sched_gd.read_text()
    errors: list[str] = []

    # ---------- A. every VALID_TRIGGERS entry has a dispatcher ----------
    m = re.search(r"const VALID_TRIGGERS[^=]*=\s*\[(.*?)\]", rule_src, re.S)
    if not m:
        errors.append("could not locate Rule.VALID_TRIGGERS — parser needs updating")
        triggers = []
    else:
        triggers = re.findall(r'"([a-z_]+)"', m.group(1))

    for t in triggers:
        if t in LIFECYCLE_DISPATCHED:
            continue
        if f'rules_by_trigger.get("{t}"' in sched_src:
            continue
        errors.append(
            f'trigger "{t}" is in Rule.VALID_TRIGGERS but phase_scheduler.gd '
            f'never reads rules_by_trigger.get("{t}") — rules using it '
            f"register, validate, and NEVER FIRE, with no diagnostic. Either "
            f"implement the dispatcher or remove it from VALID_TRIGGERS."
        )

    # ---------- B. every field from_dict assigns is read somewhere ----------
    fd = re.search(r"static func from_dict\(.*?\n(?=\n\n|\nstatic |\nfunc )", rule_src, re.S)
    fields = sorted(set(re.findall(r"^\tr\.([a-z_]+)\s*=", fd.group(0), re.M))) if fd else []

    other_sources = []
    for p in engine.rglob("*.gd"):
        if p.name == "rule.gd" or "/tests/" in p.as_posix():
            continue
        other_sources.append(p.read_text())
    blob = "\n".join(other_sources)

    for f in fields:
        if f in REFLECTION_READ:
            continue
        if re.search(rf"\.{re.escape(f)}\b", blob):
            continue
        errors.append(
            f"Rule.from_dict assigns `{f}` but nothing in scripts/engine "
            f"outside rule.gd ever reads `.{f}` — authors setting it get "
            f"silence. Either consume it or delete it."
        )

    # ---------- C. ADR 0085 vocabulary allowlist ----------
    errors += check_vocabulary(repo, engine)

    if not errors:
        print(
            f"[validate_engine_wiring] ok — {len(triggers)} trigger(s) dispatched, "
            f"{len(fields)} rule field(s) consumed, vocabulary matches the allowlist"
        )
        return 0

    print(f"[validate_engine_wiring] FAIL — {len(errors)} dead-vocabulary issue(s):")
    for e in errors:
        print(f"  {e}")
    print(
        "\nThis validator checks the ENGINE, not content. A dead entry here is "
        "invisible to every content validator: the JSON is correct and the "
        "engine silently ignores it."
    )
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
