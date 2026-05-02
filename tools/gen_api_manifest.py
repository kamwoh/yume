"""Generate Yume's engine API manifest from GDScript source.

Tier 2.6c — replaces hand-edited tool registries in agent prompts. Run on
demand or as a CI step; the manifest is the source of truth for what
verbs the engine supports. Adding a primitive (new effect type, new query
operator) automatically updates the manifest.

Usage:
    python tools/gen_api_manifest.py

Outputs:
    docs/engine-reference/api-manifest.json   — machine-readable, agent input
    docs/engine-reference/api-manifest.md     — human-readable companion

Design: regex over GDScript source. The patterns rely on the engine's
formatting conventions (constant arrays, match arms, const declarations).
A sanity check at the end fails loudly if expected vocabulary is missing,
so source-format drift is caught early instead of silently dropping items.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENGINE_DIR = REPO / "archetypes" / "core" / "templates" / "godot" / "scripts" / "engine"
OUTPUT_DIR = REPO / "docs" / "engine-reference"
JSON_OUT = OUTPUT_DIR / "api-manifest.json"
MD_OUT = OUTPUT_DIR / "api-manifest.md"


@dataclass
class Manifest:
    version: str = "1"
    generated_at: str = ""
    generated_from: str = ""
    primitives: list[str] = field(default_factory=list)
    deferred_primitives: list[str] = field(default_factory=list)
    triggers: list[str] = field(default_factory=list)
    effects: list[dict] = field(default_factory=list)
    query_clauses: list[str] = field(default_factory=list)
    query_operator_suffixes: list[str] = field(default_factory=list)
    formula_entity_roles: list[str] = field(default_factory=list)
    formula_math_helpers: list[str] = field(default_factory=list)
    error_codes: list[dict] = field(default_factory=list)
    reserved_state_fields: list[str] = field(default_factory=list)
    invariants_count: int = 8


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_string_array(text: str, const_name: str) -> list[str]:
    """Extract entries from `const NAME: Array = [ "a", "b", ... ]`."""
    pattern = rf"const\s+{re.escape(const_name)}\s*:\s*Array\s*=\s*\[(.*?)\]"
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        return []
    return re.findall(r'"([^"]+)"', m.group(1))


def parse_effects(text: str) -> list[dict]:
    """Find the `match type:` block in effect_apply.gd and extract arm names."""
    block = re.search(r"match\s+type:\s*\n((?:\t+.*\n)+)", text)
    if not block:
        return []
    arms = re.findall(r'^\t+"([a-z_]+)"\s*:', block.group(1), re.MULTILINE)
    return [{"type": name, "source": "effect_apply.gd"} for name in arms]


def parse_query_clauses(text: str) -> list[str]:
    """Find `spec.has("clause")` calls in query.gd's matches() / run()."""
    clauses = re.findall(r'spec\.has\("([a-z_]+)"\)', text)
    seen: dict[str, None] = {}
    for c in clauses:
        seen[c] = None
    return list(seen.keys())


def parse_error_codes(text: str) -> list[dict]:
    """Pull `const NAME := "code.value"` declarations from engine_error.gd."""
    out: list[dict] = []
    for m in re.finditer(r'^const\s+([A-Z_]+)\s*:?=\s*"([a-z_.]+)"', text, re.MULTILINE):
        out.append({"constant": m.group(1), "code": m.group(2)})
    return out


def parse_formula_helpers(text: str) -> list[str]:
    """Read the math-helpers list from formula.gd's doc comment."""
    m = re.search(r"Godot's Expression supports\s*`([^`]+)`(?:.*?`([^`]+)`)*", text)
    if not m:
        return []
    helpers = re.findall(r"`([a-z_]+)`", text[: text.index("Math helpers") + 2000] if "Math helpers" in text else text)
    seen: dict[str, None] = {}
    for h in helpers:
        if h.replace("_", "").isalpha() and len(h) <= 10:
            seen[h] = None
    return list(seen.keys())[:20]


def parse_formula_roles(text: str) -> list[str]:
    """Doc-listed entity roles in formula.gd."""
    block = re.search(r"## Bindings supported.*?##\s*\n", text, re.DOTALL)
    if not block:
        return ["self", "target", "a", "b", "source", "world"]
    found = re.findall(r"\b(self|target|a|b|source|from|to|world)\.", block.group(0))
    seen: dict[str, None] = {}
    for f in found:
        seen[f] = None
    return list(seen.keys())


def build_manifest() -> Manifest:
    rule_src = read(ENGINE_DIR / "rule.gd")
    effect_src = read(ENGINE_DIR / "effect_apply.gd")
    query_src = read(ENGINE_DIR / "query.gd")
    formula_src = read(ENGINE_DIR / "formula.gd")
    err_src = read(ENGINE_DIR / "engine_error.gd")

    m = Manifest(
        generated_at=datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
        generated_from=str(ENGINE_DIR.relative_to(REPO)),
        primitives=["Entity", "Tag", "Rule", "Trigger", "Effect", "Query", "Relation"],
        deferred_primitives=["Plan", "Knowledge"],
        triggers=parse_string_array(rule_src, "VALID_TRIGGERS"),
        effects=parse_effects(effect_src),
        query_clauses=parse_query_clauses(query_src),
        query_operator_suffixes=parse_string_array(query_src, "OPERATOR_SUFFIXES"),
        formula_entity_roles=parse_formula_roles(formula_src),
        formula_math_helpers=[
            "sin", "cos", "tan", "sqrt", "pow", "abs", "floor", "ceil",
            "round", "clamp", "min", "max", "lerp", "randf",
        ],
        error_codes=parse_error_codes(err_src),
        reserved_state_fields=["position", "velocity", "age"],
    )
    return m


def sanity_check(m: Manifest) -> list[str]:
    """Fail loudly if regex parsing dropped expected vocabulary. Catches
    source-format drift before agents read a half-empty manifest."""
    problems: list[str] = []
    expected_triggers = {"tick", "contact", "signal", "input", "spawn", "despawn"}
    if not expected_triggers.issubset(set(m.triggers)):
        problems.append(f"triggers missing expected items; got {m.triggers}")
    expected_effects = {"state_set", "spawn", "remove", "transform", "relate", "tag_add", "emit"}
    got_effects = {e["type"] for e in m.effects}
    if not expected_effects.issubset(got_effects):
        problems.append(f"effects missing expected items; got {sorted(got_effects)}")
    expected_clauses = {"tags_all", "properties", "state"}
    if not expected_clauses.issubset(set(m.query_clauses)):
        problems.append(f"query_clauses missing expected items; got {m.query_clauses}")
    if len(m.error_codes) < 20:
        problems.append(f"error_codes count too low: {len(m.error_codes)} (expected 20+)")
    if "_eq" not in m.query_operator_suffixes:
        problems.append("query_operator_suffixes missing _eq")
    return problems


def render_markdown(m: Manifest) -> str:
    lines: list[str] = [
        "# Yume Engine API Manifest",
        "",
        "**Auto-generated** by `tools/gen_api_manifest.py` — do not hand-edit.",
        f"_Generated: {m.generated_at}_",
        f"_Source: `{m.generated_from}`_",
        "",
        "This manifest is the canonical list of what verbs the engine supports.",
        "Agents (`yume-content-designer`, `yume-systems-designer`, `yume-tech-director`)",
        "should reference this file instead of hand-edited markdown.",
        "",
        "## Primitives (7)",
        "",
        ", ".join(f"`{p}`" for p in m.primitives),
        "",
        f"**Deferred** (Tier 3): {', '.join(f'`{p}`' for p in m.deferred_primitives)}",
        "",
        "## Triggers",
        "",
        "Valid `rule.trigger.type` strings:",
        "",
        ", ".join(f"`{t}`" for t in m.triggers),
        "",
        "## Effect types",
        "",
        f"{len(m.effects)} effect types (used as `rule.effect[].type`):",
        "",
    ]
    for e in m.effects:
        lines.append(f"- `{e['type']}` — `{e['source']}`")
    lines += [
        "",
        "## Query clauses",
        "",
        "Top-level keys allowed in a `query` spec:",
        "",
        ", ".join(f"`{c}`" for c in m.query_clauses),
        "",
        "### Operator suffixes",
        "",
        "Used in `state` / `properties` filters (e.g. `\"hp_lt\": 50`):",
        "",
        ", ".join(f"`{s}`" for s in m.query_operator_suffixes),
        "",
        "## Formula bindings",
        "",
        "**Entity roles** (use as `<role>.state.<field>`):",
        "",
        ", ".join(f"`{r}`" for r in m.formula_entity_roles),
        "",
        "**Math helpers** (Godot Expression built-ins):",
        "",
        ", ".join(f"`{h}`" for h in m.formula_math_helpers),
        "",
        "**Formula syntax notes** (Godot 4.6.1 quirks):",
        "",
        "- Ternary: **Python-style** `a if cond else b`. C-style `cond ? a : b` does NOT parse.",
        "- Bitwise `<<`, `&`, `|` — supported.",
        "- Vector2 / Vector3 / Array subscript `v[0]` — supported.",
        "- Vector2 / Vector3 component access `v.x`, `v.y`, `v.z` — supported via path resolver.",
        "- Empirically verified during harvestcore QA (2026-05-02).",
        "",
        "## Error codes (Tier 2.6a)",
        "",
        f"{len(m.error_codes)} stable codes for matching in retry loops:",
        "",
        "| Code | Constant |",
        "|---|---|",
    ]
    for c in m.error_codes:
        lines.append(f"| `{c['code']}` | `EngineError.{c['constant']}` |")
    lines += [
        "",
        "## Reserved state fields",
        "",
        "Fields the engine reads by name (everything else is content vocabulary):",
        "",
        ", ".join(f"`{f}`" for f in m.reserved_state_fields),
        "",
        f"## Invariants",
        "",
        f"{m.invariants_count} contract invariants — see `docs/30_framework_primitives.md`.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    m = build_manifest()
    problems = sanity_check(m)
    if problems:
        print("Sanity check failed:", file=sys.stderr)
        for p in problems:
            print("  -", p, file=sys.stderr)
        return 1

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    JSON_OUT.write_text(json.dumps(m.__dict__, indent=2) + "\n", encoding="utf-8")
    MD_OUT.write_text(render_markdown(m), encoding="utf-8")
    print(f"Wrote {JSON_OUT.relative_to(REPO)}")
    print(f"Wrote {MD_OUT.relative_to(REPO)}")
    print(f"  triggers: {len(m.triggers)}")
    print(f"  effects: {len(m.effects)}")
    print(f"  query_clauses: {len(m.query_clauses)}")
    print(f"  query_operator_suffixes: {len(m.query_operator_suffixes)}")
    print(f"  error_codes: {len(m.error_codes)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
