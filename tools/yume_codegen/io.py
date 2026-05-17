"""
io.py — write composed dicts out as JSON; load JSON for round-tripping.

Two write modes:
    - save(path, value): generic dict → JSON file, pretty-printed
    - save_rules(path, [rules]): wraps in {"rules": [...]} envelope
    - save_entities(path, [defs], [instances]): the entities/<f>.json
      shape with definitions + initial_instances
    - save_screens(path, screens=[...], starting=..., globals=[...]):
      the screens.json shape

Why pretty-print: the JSON is hand-readable by authors AND by the
LLM doing future edits. Compact JSON saves bytes but makes diffs
unreadable.
"""

import json
from pathlib import Path


def save(path: str, value, *, indent: int = 2) -> int:
    """Write `value` as JSON to `path`. Returns byte count written.

    Creates parent directories if absent. Pretty-prints with 2-space
    indent by default — matches the rest of Yume's checked-in JSON
    so diffs stay clean.
    """
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, indent=indent, ensure_ascii=False)
    p.write_text(text + "\n", encoding="utf-8")
    return len(text) + 1


def save_rules(
    path: str,
    rules: list[dict],
    *,
    comment: str | None = None,
    indent: int = 2,
) -> int:
    """Write rules to a world/rules/*.json file (ADR 0009 split).

    Envelope:
        {
          "_comment": "<optional>",
          "rules": [<rule_dict>...]
        }
    """
    envelope: dict = {}
    if comment is not None:
        envelope["_comment"] = comment
    envelope["rules"] = rules
    return save(path, envelope, indent=indent)


def save_entities(
    path: str,
    definitions: list[dict] | None = None,
    initial_instances: list[dict] | None = None,
    initial_relations: list[dict] | None = None,
    *,
    comment: str | None = None,
    indent: int = 2,
) -> int:
    """Write to data/<game>/entities/<file>.json.

    Envelope:
        {
          "_comment": "<optional>",
          "definitions": [<entity_def>...],
          "initial_instances": [<inst>...],
          "initial_relations": [<rel>...]   (optional)
        }
    """
    envelope: dict = {}
    if comment is not None:
        envelope["_comment"] = comment
    if definitions is not None:
        envelope["definitions"] = definitions
    if initial_instances is not None:
        envelope["initial_instances"] = initial_instances
    if initial_relations:
        envelope["initial_relations"] = initial_relations
    return save(path, envelope, indent=indent)


def save_screens(
    path: str,
    screens: list[dict],
    *,
    starting_screen: str = "",
    global_inputs: list[dict] | None = None,
    comment: str | None = None,
    indent: int = 2,
) -> int:
    """Write to data/<game>/screens.json.

    Envelope:
        {
          "_comment": "<optional>",
          "starting_screen": "<id>" | "",
          "screens": [<screen_dict>...],
          "global_inputs": [<global_input_dict>...]   (optional)
        }
    """
    envelope: dict = {}
    if comment is not None:
        envelope["_comment"] = comment
    envelope["starting_screen"] = starting_screen
    envelope["screens"] = screens
    if global_inputs:
        envelope["global_inputs"] = global_inputs
    return save(path, envelope, indent=indent)


def load_json(path: str):
    """Round-trip helper — load a JSON file back into a dict. Use
    this if you want to merge codegen output with hand-authored
    sections, e.g.:

        existing = load_json("...rules.json")
        existing["rules"].extend(my_codegen_rules)
        save("...rules.json", existing)
    """
    return json.loads(Path(path).read_text(encoding="utf-8"))
