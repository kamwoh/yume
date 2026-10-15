#!/usr/bin/env python3
"""
Regression test for validate_engine_wiring check C (ADR 0085, 2026-10-16).

The check fails when the engine has a vocabulary item without an accepted
ADR that names it. This test builds a small fake repo per case and pins
each failure.

Run:  python3 -m tools.validators.tests.test_engine_vocabulary
"""

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent))

import tools.validators.validate_engine_wiring as w  # noqa: E402

ENGINE = {"effects": ["state_set", "declare_war"], "directors": ["GameShell"], "formula_roots": ["self"]}
ADRS = {
    "0001": ("accepted", "`state_set` and `self`"),
    "0011": ("**accepted (refactored)**", "`GameShell`"),
    "0032": ("proposed", "`declare_war`"),
}


def run(allow: dict, adrs=ADRS) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        (repo / "tools" / "validators").mkdir(parents=True)
        (repo / "tools" / "validators" / "engine_vocabulary.json").write_text(json.dumps(allow))
        (repo / "docs" / "adr").mkdir(parents=True)
        for n, (status, body) in adrs.items():
            (repo / "docs" / "adr" / f"{n}-x.md").write_text(f"# ADR {n}\n\n_Status: {status}_\n\n{body}\n")
        real = w.engine_vocabulary
        w.engine_vocabulary = lambda engine: ENGINE
        try:
            return w.check_vocabulary(repo, repo)
        finally:
            w.engine_vocabulary = real


def allow(**effects) -> dict:
    return {"effects": effects, "directors": {"GameShell": "0011"}, "formula_roots": {"self": "0001"}}


CASES = [
    ("unlisted engine effect", allow(state_set="0001"), "not in engine_vocabulary.json"),
    ("ADR still proposed", allow(state_set="0001", declare_war="0032"), "not accepted"),
    ("new legacy entry", allow(state_set="0001", declare_war="legacy"), "new legacy entry"),
    ("ADR does not name it", allow(state_set="0001", declare_war="0001"), "does not name it"),
    ("missing ADR file", allow(state_set="0001", declare_war="0099"), "no file"),
    ("listed but gone", {**allow(state_set="0001", declare_war="0001"),
                         "formula_roots": {"self": "0001", "faction": "0001"}}, "no longer has"),
]


def main() -> int:
    failures = 0
    for name, allowlist, expect in CASES:
        errs = run(allowlist)
        ok = any(expect in e for e in errs)
        print(f"  [{'ok' if ok else 'FAIL'}] {name} -> {errs[:1]}")
        failures += 0 if ok else 1
    clean = run(allow(state_set="0001", declare_war="0001"),
                {**ADRS, "0001": ("accepted", "`state_set`, `self` and `declare_war`")})
    print(f"  [{'ok' if not clean else 'FAIL'}] all listed and named -> {clean}")
    failures += 1 if clean else 0
    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {len(CASES) + 1} cases, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
