"""Lesson CRUD operations — store, retrieve, and manage lessons."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml
from rich.console import Console

console = Console()


@dataclass
class Lesson:
    """A single lesson learned during game generation or debugging."""

    id: str
    archetype: str  # e.g., "rpg"
    system: str  # e.g., "combat", "dialogue", "unity"
    problem: str
    root_cause: str
    fix: str
    prevention_rule: str
    tags: list[str]

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "archetype": self.archetype,
            "system": self.system,
            "problem": self.problem,
            "root_cause": self.root_cause,
            "fix": self.fix,
            "prevention_rule": self.prevention_rule,
            "tags": self.tags,
        }

    @classmethod
    def from_dict(cls, data: dict) -> Lesson:
        return cls(**data)


class LessonStore:
    """File-based lesson storage — YAML files organized by archetype/system."""

    def __init__(self, lessons_dir: Path):
        self._dir = lessons_dir
        self._dir.mkdir(parents=True, exist_ok=True)

    def save(self, lesson: Lesson) -> Path:
        """Save a lesson to disk."""
        dir_path = self._dir / lesson.archetype / lesson.system
        dir_path.mkdir(parents=True, exist_ok=True)

        file_path = dir_path / f"{lesson.id}.yaml"
        file_path.write_text(yaml.dump(lesson.to_dict(), default_flow_style=False, sort_keys=False))
        return file_path

    def get(self, lesson_id: str) -> Lesson | None:
        """Find a lesson by ID (searches all files)."""
        for path in self._dir.rglob("*.yaml"):
            data = yaml.safe_load(path.read_text())
            if data and data.get("id") == lesson_id:
                return Lesson.from_dict(data)
        return None

    def list_all(self) -> list[Lesson]:
        """List all lessons."""
        lessons = []
        for path in sorted(self._dir.rglob("*.yaml")):
            data = yaml.safe_load(path.read_text())
            if data:
                try:
                    lessons.append(Lesson.from_dict(data))
                except (TypeError, KeyError):
                    continue
        return lessons

    def query(self, archetype: str | None = None, system: str | None = None, tags: list[str] | None = None) -> list[Lesson]:
        """Query lessons by archetype, system, or tags."""
        results = []
        for lesson in self.list_all():
            if archetype and lesson.archetype != archetype:
                continue
            if system and lesson.system != system:
                continue
            if tags and not any(t in lesson.tags for t in tags):
                continue
            results.append(lesson)
        return results

    def delete(self, lesson_id: str) -> bool:
        """Delete a lesson by ID."""
        for path in self._dir.rglob("*.yaml"):
            data = yaml.safe_load(path.read_text())
            if data and data.get("id") == lesson_id:
                path.unlink()
                return True
        return False
