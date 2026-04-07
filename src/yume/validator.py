"""Post-generation validator — checks a Godot project for common issues before opening."""

from __future__ import annotations

import json
import re
from pathlib import Path
from dataclasses import dataclass, field


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return len(self.errors) == 0

    def summary(self) -> str:
        lines = []
        if self.errors:
            lines.append(f"  {len(self.errors)} error(s):")
            for e in self.errors:
                lines.append(f"    [ERR] {e}")
        if self.warnings:
            lines.append(f"  {len(self.warnings)} warning(s):")
            for w in self.warnings:
                lines.append(f"    [WARN] {w}")
        if not lines:
            lines.append("  All checks passed!")
        return "\n".join(lines)


def validate_project(project_root: Path) -> ValidationResult:
    """Run all validation checks on a generated Godot project."""
    result = ValidationResult()

    _check_required_files(project_root, result)
    _check_project_godot(project_root, result)
    _check_json_files(project_root, result)
    _check_gdscript_files(project_root, result)
    _check_scene_files(project_root, result)
    _check_references(project_root, result)

    return result


def _check_required_files(root: Path, result: ValidationResult) -> None:
    """Check all required files exist."""
    required = [
        "project.godot",
        "scenes/main.tscn",
        "scripts/player_controller.gd",
        "scripts/screen_fader.gd",
        "scripts/autoload/game_manager.gd",
        "scripts/autoload/location_manager.gd",
        "scripts/autoload/dialogue_manager.gd",
        "scripts/autoload/party_manager.gd",
        "scripts/autoload/inventory_manager.gd",
        "scripts/autoload/quest_manager.gd",
        "scripts/autoload/battle_manager.gd",
        "scripts/autoload/save_manager.gd",
        "scripts/autoload/ui_theme.gd",
        "scripts/ui/dialogue_ui.gd",
        "scripts/ui/hud.gd",
        "scripts/ui/menu.gd",
        "scripts/ui/battle_ui.gd",
        "scripts/ui/shop_ui.gd",
        "data/characters.json",
        "data/items.json",
        "data/enemies.json",
        "data/quests.json",
        "data/dialogues.json",
        "data/progression.json",
    ]
    for f in required:
        if not (root / f).exists():
            result.errors.append(f"Missing required file: {f}")


def _check_project_godot(root: Path, result: ValidationResult) -> None:
    """Check project.godot has required sections."""
    path = root / "project.godot"
    if not path.exists():
        return
    text = path.read_text()

    if "run/main_scene" not in text:
        result.errors.append("project.godot: missing run/main_scene")
    if "[autoload]" not in text:
        result.errors.append("project.godot: missing [autoload] section")

    # Check all autoloads point to existing files
    for line in text.split("\n"):
        if '="*res://' in line:
            match = re.search(r'"[*]res://(.+?)"', line)
            if match:
                script_path = match.group(1)
                if not (root / script_path).exists():
                    result.errors.append(f"project.godot: autoload references missing file: {script_path}")


def _check_json_files(root: Path, result: ValidationResult) -> None:
    """Check all JSON files are valid."""
    for json_file in root.rglob("*.json"):
        try:
            data = json.loads(json_file.read_text())
        except json.JSONDecodeError as e:
            result.errors.append(f"Invalid JSON: {json_file.relative_to(root)} — {e}")
            continue

        # Check location files have required fields
        if "locations" in str(json_file):
            if isinstance(data, dict):
                if "id" not in data:
                    result.warnings.append(f"Location missing 'id': {json_file.name}")
                if "connections" not in data and "exits" not in data:
                    result.warnings.append(f"Location missing connections/exits: {json_file.name}")


def _check_gdscript_files(root: Path, result: ValidationResult) -> None:
    """Check GDScript files for common issues."""
    for gd_file in root.rglob("*.gd"):
        text = gd_file.read_text()
        rel = gd_file.relative_to(root)

        # Check for duplicate var names in same function
        _check_duplicate_vars(text, rel, result)

        # Check for known bad patterns
        if "using UnityEngine" in text:
            result.errors.append(f"{rel}: Contains Unity code (using UnityEngine)")

        if "SpriteRenderer" in text and "scripts/autoload" not in str(rel):
            result.warnings.append(f"{rel}: References SpriteRenderer (use Renderer)")

        # Check extends is present
        lines = text.strip().split("\n")
        if lines and not lines[0].startswith("extends") and not lines[0].startswith("#"):
            result.warnings.append(f"{rel}: First line is not 'extends' — may not be a valid GDScript")

        # Check for empty files
        if len(text.strip()) < 10:
            result.warnings.append(f"{rel}: File appears empty")


def _check_duplicate_vars(text: str, filepath: Path, result: ValidationResult) -> None:
    """Check for duplicate var declarations at the same indent level in a function.

    GDScript allows re-declaring vars in different for/if blocks (new scope each),
    so we only flag duplicates at the SAME indent level within the same function.
    """
    current_func = None
    # Track vars by (func_name, indent_level)
    vars_by_indent: dict[str, dict[int, list[str]]] = {}

    for line_num, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip('\t'))

        # Track function boundaries
        if stripped.startswith("func "):
            func_match = re.match(r"func (\w+)", stripped)
            if func_match:
                current_func = func_match.group(1)
                vars_by_indent[current_func] = {}

        # Track var declarations — only flag at indent level 1 (direct function body)
        if current_func and stripped.startswith("var "):
            var_match = re.match(r"var (\w+)", stripped)
            if var_match and indent <= 1:
                var_name = var_match.group(1)
                level_vars = vars_by_indent.get(current_func, {}).setdefault(indent, [])
                if var_name in level_vars:
                    result.errors.append(
                        f"{filepath}:{line_num}: Duplicate var '{var_name}' in func {current_func}"
                    )
                else:
                    level_vars.append(var_name)


def _check_scene_files(root: Path, result: ValidationResult) -> None:
    """Check .tscn files reference existing scripts."""
    for tscn_file in root.rglob("*.tscn"):
        text = tscn_file.read_text()
        rel = tscn_file.relative_to(root)

        # Check ext_resource paths exist
        for match in re.finditer(r'path="res://(.+?)"', text):
            res_path = match.group(1)
            if not (root / res_path).exists():
                result.errors.append(f"{rel}: References missing resource: {res_path}")

        # Check load_steps matches actual resource count
        steps_match = re.search(r"load_steps=(\d+)", text)
        ext_count = len(re.findall(r"\[ext_resource", text))
        sub_count = len(re.findall(r"\[sub_resource", text))
        if steps_match:
            declared = int(steps_match.group(1))
            actual = ext_count + sub_count + 1  # +1 for scene itself
            if declared != actual:
                result.warnings.append(
                    f"{rel}: load_steps={declared} but found {ext_count} ext + {sub_count} sub resources (expected {actual})"
                )


def _check_references(root: Path, result: ValidationResult) -> None:
    """Check cross-references between data files."""
    data_dir = root / "data"
    if not data_dir.exists():
        return

    # Load all data
    try:
        characters = json.loads((data_dir / "characters.json").read_text())
        items = json.loads((data_dir / "items.json").read_text())
        enemies = json.loads((data_dir / "enemies.json").read_text())
        quests = json.loads((data_dir / "quests.json").read_text())
        progression = json.loads((data_dir / "progression.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return  # Already caught by other checks

    char_ids = {c["id"] for c in characters}
    item_ids = {i["id"] for i in items}
    enemy_ids = {e["id"] for e in enemies}
    quest_ids = {q["id"] for q in quests}

    # Check starting party references valid characters
    for cid in progression.get("starting_party", []):
        if cid not in char_ids:
            result.errors.append(f"Progression: starting_party references unknown character '{cid}'")

    # Check starting items reference valid items
    for iid in progression.get("starting_items", []):
        if iid not in item_ids:
            result.warnings.append(f"Progression: starting_items references unknown item '{iid}'")

    # Check quest rewards reference valid items
    for quest in quests:
        for reward in quest.get("rewards", []):
            if reward not in item_ids:
                result.warnings.append(f"Quest '{quest['id']}': reward references unknown item '{reward}'")
        prereq = quest.get("prerequisite")
        if prereq and prereq not in quest_ids:
            result.errors.append(f"Quest '{quest['id']}': prerequisite references unknown quest '{prereq}'")

    # Check location files reference valid connections
    loc_dir = data_dir / "locations"
    if loc_dir.exists():
        loc_ids = {f.stem for f in loc_dir.glob("*.json")}
        for loc_file in loc_dir.glob("*.json"):
            try:
                loc_data = json.loads(loc_file.read_text())
            except json.JSONDecodeError:
                continue
            for conn in loc_data.get("connections", []):
                if conn not in loc_ids:
                    result.errors.append(f"Location '{loc_file.stem}': connects to unknown location '{conn}'")
            for exit_data in loc_data.get("exits", []):
                target = exit_data.get("target", "")
                if target and target not in loc_ids:
                    result.errors.append(f"Location '{loc_file.stem}': exit to unknown location '{target}'")


# CLI entry point
if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("Usage: python validator.py <project_root>")
        sys.exit(1)

    root = Path(sys.argv[1])
    if not root.exists():
        print(f"Project not found: {root}")
        sys.exit(1)

    print(f"Validating: {root}")
    result = validate_project(root)
    print(result.summary())
    sys.exit(0 if result.ok else 1)
