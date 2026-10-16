#!/usr/bin/env python3
"""
Regression test: tools/visual_qa/run_plan.py never writes game data in the
repo (2026-10-16).

Empirical case: on demo_sokoban, run_plan wrote a transient camera into the
tracked levels/1/entities.json. Then set_active_camera raised, because the
game has no world_clock.json. The restore sat in a `finally` that the
error skipped, so the camera stayed in the repo file. run_plan now edits
only the synced template copy.

The test runs run_test on a fake game in temp folders, with a capture
that fails and with a missing world_clock.json. The repo files must stay
byte-equal, and the template copy must match the repo afterwards.

Run:  python3 -m tools.validators.tests.test_run_plan_no_repo_writes
"""

import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

from tools.visual_qa import run_plan  # noqa: E402

LEVEL = {"initial_instances": [{"def": "rock", "id": "rock_1", "position": [1, 0, 1]}]}
CLOCK = {"definitions": [{"id": "world_clock", "state_init": {"active_camera_id": "camera_a"}}]}


def make_game(root: Path, with_clock: bool) -> list[Path]:
    files = [root / "g" / "levels" / "l1" / "entities.json"]
    files[0].parent.mkdir(parents=True)
    files[0].write_text(json.dumps(LEVEL))
    if with_clock:
        files.append(root / "g" / "entities" / "world_clock.json")
        files[1].parent.mkdir(parents=True)
        files[1].write_text(json.dumps(CLOCK))
    return files


def run_case(with_clock: bool) -> list[str]:
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        repo, tmpl = Path(tmp) / "repo_data", Path(tmp) / "template"
        files = make_game(repo, with_clock)
        before = {f: f.read_bytes() for f in files}
        saved = (run_plan.GODOT_DATA, run_plan.TEMPLATE_DST, run_plan.sync_to_template,
                 run_plan.load_assertion, run_plan.compute_camera_pose, run_plan.capture_once)
        run_plan.GODOT_DATA, run_plan.TEMPLATE_DST = repo, tmpl
        run_plan.sync_to_template = lambda: shutil.copytree(repo, tmpl / "data", dirs_exist_ok=True)
        run_plan.load_assertion = lambda _id: {"framing": {"rule": "x"}}
        run_plan.compute_camera_pose = lambda *a, **k: ([0.0, 5.0, 5.0], 0.0, -0.5)

        def boom(*_a, **_k):
            raise RuntimeError("capture failed")
        run_plan.capture_once = boom
        try:
            run_plan.run_test("g", "l1", {"id": "t", "assertion": "a", "params": {}}, 0)
            fails.append("run_test did not raise")
        except (RuntimeError, FileNotFoundError):
            pass
        finally:
            (run_plan.GODOT_DATA, run_plan.TEMPLATE_DST, run_plan.sync_to_template,
             run_plan.load_assertion, run_plan.compute_camera_pose, run_plan.capture_once) = saved
        for f, data in before.items():
            if f.read_bytes() != data:
                fails.append(f"repo file changed: {f.relative_to(repo)}")
            t = tmpl / "data" / f.relative_to(repo)
            if t.read_bytes() != data:
                fails.append(f"template copy not restored: {f.relative_to(repo)}")
    return fails


def main() -> int:
    failures = 0
    for name, with_clock in (("capture fails", True), ("no world_clock.json", False)):
        fails = run_case(with_clock)
        print(f"  [{'ok' if not fails else 'FAIL'}] {name} {fails if fails else ''}")
        failures += len(fails)
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: 2 cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
