"""Lesson consultation — query lessons during generation to avoid known issues."""

from __future__ import annotations

from pathlib import Path

from yume.lessons.store import LessonStore


def consult_lessons(
    lessons_dir: Path,
    archetype: str,
    system: str,
) -> list[str]:
    """Query the lesson store for prevention rules relevant to a generation step.

    Returns a list of prevention rules that should be applied.
    """
    store = LessonStore(lessons_dir)
    lessons = store.query(archetype=archetype, system=system)

    rules = []
    for lesson in lessons:
        rules.append(
            f"[Lesson: {lesson.id}] {lesson.prevention_rule} "
            f"(Root cause: {lesson.root_cause})"
        )
    return rules


def format_lessons_for_prompt(lessons_dir: Path, archetype: str, system: str) -> str:
    """Format relevant lessons as context to inject into LLM prompts.

    Returns empty string if no relevant lessons exist.
    """
    rules = consult_lessons(lessons_dir, archetype, system)
    if not rules:
        return ""

    header = "# Known Issues & Prevention Rules\nApply these rules during generation:\n\n"
    body = "\n".join(f"- {rule}" for rule in rules)
    return header + body + "\n"
