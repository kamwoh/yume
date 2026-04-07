"""Yume CLI — game development framework tools."""

from __future__ import annotations

from pathlib import Path

import typer
from rich.console import Console

from yume import __version__

app = typer.Typer(
    name="yume",
    help="Yume (夢) — Game development framework. React for RPGs.",
    no_args_is_help=True,
)
console = Console()


def version_callback(value: bool) -> None:
    if value:
        console.print(f"yume {__version__}")
        raise typer.Exit()


@app.callback()
def main(
    version: bool = typer.Option(False, "--version", "-v", callback=version_callback, is_eager=True),
) -> None:
    """Yume (夢) — Game development framework. React for RPGs."""


@app.command()
def init(
    project_name: str = typer.Argument(..., help="Name of the new game project"),
    archetype: str = typer.Option("rpg", "--type", "-t", help="Game archetype (rpg)"),
    output: Path | None = typer.Option(None, "--output", "-o", help="Parent directory for the project"),
) -> None:
    """Scaffold a new game project from Yume templates."""
    import shutil

    target = (output or Path.cwd()) / project_name
    if target.exists():
        console.print(f"[red]Error:[/red] {target} already exists.")
        raise typer.Exit(1)

    # Find template directory
    yume_root = Path(__file__).parent.parent.parent  # src/yume/cli.py → yume/
    template_dir = yume_root / "archetypes" / archetype / "templates" / "godot"

    if not template_dir.exists():
        console.print(f"[red]Error:[/red] Archetype '{archetype}' not found at {template_dir}")
        raise typer.Exit(1)

    # Copy template
    console.print(f"  Creating [cyan]{project_name}[/cyan] from {archetype} archetype...")
    shutil.copytree(template_dir, target)

    # Create data directory with example data
    data_dir = target / "data"
    data_dir.mkdir(exist_ok=True)
    (data_dir / "locations").mkdir(exist_ok=True)

    example_data = yume_root / "archetypes" / archetype / "data" / "examples" / "ff9"
    if example_data.exists():
        console.print("  Including example data (replace with your own)...")
        for f in example_data.rglob("*"):
            if f.is_file():
                rel = f.relative_to(example_data)
                dest = data_dir / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, dest)

    # Copy docs into project
    docs_dir = target / "yume_docs"
    docs_dir.mkdir(exist_ok=True)
    for d in [yume_root / "core" / "docs", yume_root / "archetypes" / archetype / "docs"]:
        if d.exists():
            for f in d.glob("*.md"):
                shutil.copy2(f, docs_dir / f.name)

    # Copy prompts
    prompts_src = yume_root / "archetypes" / archetype / "prompts"
    if prompts_src.exists():
        shutil.copytree(prompts_src, target / "yume_prompts")

    # Update project name
    pg = target / "project.godot"
    if pg.exists():
        text = pg.read_text()
        text = text.replace('config/name="My RPG Game"', f'config/name="{project_name}"')
        pg.write_text(text)

    # Install /yume skill for Claude Code
    skill_src = yume_root / "skills" / "yume"
    skill_dest = Path.home() / ".claude" / "skills" / "yume"
    if skill_src.exists():
        skill_dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(skill_src / "SKILL.md", skill_dest / "SKILL.md")
        console.print("  [green]✓ /yume skill installed[/green]")

    # Validate
    from yume.validator import validate_project
    result = validate_project(target)
    if result.ok:
        console.print("  [green]✓ All checks passed![/green]")
    else:
        console.print(result.summary())

    console.print(f"\n  [bold green]Project created![/bold green]")
    console.print(f"  Open [cyan]{target}[/cyan] in Godot 4.x and press F5.")
    console.print(f"  Use [bold]/yume[/bold] in Claude Code for guided development.")


@app.command()
def validate(
    project_path: Path = typer.Argument(..., help="Path to a Godot project to validate", exists=True),
) -> None:
    """Validate a Yume game project for common issues."""
    from yume.validator import validate_project

    console.print(f"Validating [cyan]{project_path}[/cyan]...")
    result = validate_project(project_path)
    console.print(result.summary())

    if not result.ok:
        raise typer.Exit(1)


@app.command()
def test(
    project_path: Path = typer.Argument(..., help="Path to a Yume game project (the data/ directory or its parent)", exists=True),
    layer: str = typer.Option("all", "--layer", "-l", help="Test layer: data, systems, playthrough, godot, all"),
    godot_exe: str = typer.Option("", "--godot", "-g", help="Path to Godot executable (for headless tests)"),
) -> None:
    """Run automated tests on a Yume game project.

    Tests every game system without needing a human to play:
    - data: JSON integrity, exit refs, reachability, content density
    - systems: Party joins, quest chain, damage formulas, shop economy
    - playthrough: Simulates playing the entire game start to finish
    - godot: Runs Godot headless to verify spawn logic and battle math
    """
    import subprocess
    import importlib.util

    # Resolve data directory
    data_dir = project_path / "data" if (project_path / "data").exists() else project_path
    if not (data_dir / "locations").exists():
        console.print(f"[red]Error:[/red] No data/locations/ found in {project_path}")
        raise typer.Exit(1)

    yume_root = Path(__file__).parent.parent.parent
    tools_dir = yume_root / "tools"

    results = {}

    if layer in ("data", "all"):
        console.print("\n[bold]Layer 1: Data Validation[/bold]")
        console.print("-" * 40)
        r = subprocess.run(
            ["python3", str(tools_dir / "validate_game_data.py"), str(data_dir)],
            capture_output=False,
        )
        results["data"] = r.returncode == 0

    if layer in ("systems", "all"):
        console.print("\n[bold]Layer 2: Game System Tests[/bold]")
        console.print("-" * 40)
        r = subprocess.run(
            ["python3", str(tools_dir / "test_game_systems.py"), str(data_dir)],
            capture_output=False,
        )
        results["systems"] = r.returncode == 0

    if layer in ("playthrough", "all"):
        console.print("\n[bold]Layer 3: Full Playthrough Simulation[/bold]")
        console.print("-" * 40)
        r = subprocess.run(
            ["python3", str(tools_dir / "simulate_playthrough.py"), str(data_dir)],
            capture_output=False,
        )
        results["playthrough"] = r.returncode == 0

    if layer in ("godot", "all") and godot_exe:
        console.print("\n[bold]Layer 4: Godot Headless Tests[/bold]")
        console.print("-" * 40)
        r = subprocess.run(
            [godot_exe, "--headless", "--path", str(project_path), "--script", "res://tests/test_runner.gd"],
            capture_output=False,
        )
        results["godot"] = r.returncode == 0

    # Summary
    console.print("\n" + "=" * 40)
    console.print("[bold]TEST SUMMARY[/bold]")
    console.print("=" * 40)
    all_pass = True
    for name, passed in results.items():
        icon = "[green]✓[/green]" if passed else "[red]✗[/red]"
        console.print(f"  {icon} {name}")
        if not passed:
            all_pass = False

    if all_pass:
        console.print("\n  [bold green]All tests passed![/bold green]")
    else:
        console.print("\n  [bold red]Some tests failed.[/bold red]")
        raise typer.Exit(1)


@app.command(name="list-lessons")
def list_lessons() -> None:
    """List all accumulated lessons in the knowledge base."""
    from yume.config import load_config
    config = load_config()
    lessons_dir = config.lessons_dir

    if not lessons_dir.exists():
        console.print("No lessons yet.")
        return

    files = sorted(lessons_dir.rglob("*.yaml")) + sorted(lessons_dir.rglob("*.yml"))
    if not files:
        console.print("No lessons yet.")
        return

    console.print(f"[bold]{len(files)} lesson(s)[/bold] in {lessons_dir}:\n")
    for f in files:
        rel = f.relative_to(lessons_dir)
        console.print(f"  - {rel}")


@app.command()
def learn(
    problem: str = typer.Option(..., "--problem", "-p", help="What went wrong"),
    fix: str = typer.Option(..., "--fix", "-f", help="How it was fixed"),
    system: str = typer.Option("general", "--system", "-s", help="System area"),
    archetype: str = typer.Option("rpg", "--archetype", "-a", help="Game archetype"),
) -> None:
    """Record a lesson learned from debugging."""
    from yume.lessons.store import Lesson, LessonStore
    from yume.config import load_config
    import re

    config = load_config()
    store = LessonStore(config.lessons_dir)

    lesson_id = re.sub(r"[^a-z0-9]+", "_", problem.lower().strip())[:50].strip("_")

    lesson = Lesson(
        id=lesson_id,
        archetype=archetype,
        system=system,
        problem=problem,
        root_cause=problem,
        fix=fix,
        prevention_rule=fix,
        tags=[system, archetype],
    )

    path = store.save(lesson)
    console.print(f"[green]Lesson saved:[/green] {path}")
