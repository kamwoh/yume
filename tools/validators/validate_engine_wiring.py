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

Usage:
    python3 tools/validators/validate_engine_wiring.py
    python3 tools/validators/validate_engine_wiring.py --strict   # exit 1

Takes no game argument — it validates the engine. run_all.py passes a game
name to every validator, so extra positional args are ignored.
"""

import re
import sys
from pathlib import Path

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

    if not errors:
        print(
            f"[validate_engine_wiring] ok — {len(triggers)} trigger(s) dispatched, "
            f"{len(fields)} rule field(s) consumed"
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
