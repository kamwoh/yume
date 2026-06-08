"""pytest config for the yume_assetgen test dir.

`test_smoke.py` and `test_glb_merge.py` are STANDALONE scripts, not
pytest modules — each has its own `main()` and a "Usage: python3 -m
tools.yume_assetgen.tests.<x>" docstring. Their `test_*` functions are
intentionally stateful + ordered (generate → patch → re-run share one
game_dir threaded by main()) and report via `_check(...) + return`, not
`assert`. Under pytest that shape is doubly wrong:

  - functions taking the shared `game_dir` / `parent_tmp` are read as
    fixture requests → "fixture not found" ERROR;
  - the rest FALSE-GREEN — a non-zero return count is not a failure to
    pytest, so a broken `_check` still reports "passed".

So we exclude both from pytest collection. Run them the canonical way:

    python3 -m tools.yume_assetgen.tests.test_smoke
    python3 -m tools.yume_assetgen.tests.test_glb_merge

(2026-06-08: these were surfacing 12 spurious pytest errors / 2 false
greens; the suites themselves pass via their own runners.)
"""

collect_ignore = ["test_smoke.py", "test_glb_merge.py"]
