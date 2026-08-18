#!/usr/bin/env python3
"""A signal-buffer entry must nest its fields under `payload`.

WHY THIS EXISTS
---------------
The scheduler dispatches signals by reading `sig["payload"]`
(`PhaseScheduler._drain_signals_into`). An entry whose fields sit FLAT beside
`name` therefore hands every matching rule an EMPTY payload. Nothing errors: the
rule is registered, the signal fires, every `require` on a payload binding fails,
and the rule simply never runs. From the outside that is indistinguishable from a
content bug, and it is invisible to the boot log, to every other validator, and
even to a unit test that inspects the buffer instead of firing a rule.

This exact shape has been found FOUR times:

  1. Authored JSON: `emit` written with its fields at top level instead of under
     `payload`. Every signal in a game fired empty and every button did nothing.
     Gated on the content side by validate_emit_payload.py.
  2. ENGINE, `level_return` (ADR 0077): built its entry by hand and flattened
     `result`, so the return value — the entire reason the effect takes a
     `result` — arrived empty at every caller. A cleared dungeon floor paid 0
     coin. 2026-08-18.
  3. ENGINE, `advance_time`: emitted `{"name": "time_advanced", "units": N}` with
     `units` flat, so a rule could learn that time had passed but never how much,
     which is the only interesting thing about that signal. 2026-08-18.
  4. The unit test for (3) asserted `sig["units"]` and so passed for as long as
     the bug existed. A signal-payload assertion has to run downstream of a real
     rule firing; asserting against the buffer proves nothing about readability.

WHAT IT CHECKS, AND WHAT IT DELIBERATELY DOES NOT
-------------------------------------------------
It checks the SHAPE: a dict appended to the signal buffer carrying `name` and no
`payload`.

It does NOT require every producer to call `EffectCore.push_signal`. That is the
stronger invariant and was this validator's first draft, but the engine has around
ten hand-built producers across the directors (faction, lifecycle, schedule,
class, overlay, dynasty, tech-tree) and every one of them is already correctly
shaped. Rewriting seven untouched subsystems to satisfy a validator is a larger
change than the bug justifies, and the shape check catches the actual defect at
every one of those sites anyway. `push_signal` exists and is what new code should
call; this gate enforces the property rather than the route.

Scoped to functions that actually opened `signal_buffer`. The engine has several
buffers with different entry shapes — `screen_event_buffer` (`{"event": ...}`),
`shell_event_buffer`, the error buffer — and flagging those would make this
validator noise. Noise gets a validator skipped, which is worse than not having
one.

Usage:
  python3 tools/validators/validate_signal_entry_shape.py [<game>] [--strict]

`game` is accepted and ignored: this scans engine source, not content, but
run_all.py passes a game to every validator.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ENGINE = REPO / "godot" / "scripts" / "engine"

APPEND = re.compile(r"\.\s*(?:append|push_back)\s*\(")
FUNC = re.compile(r"(?:static )?func\s+(\w+)")
NAME_KEY = re.compile(r"""["']name["']\s*:""")
PAYLOAD_KEY = re.compile(r"""["']payload["']\s*:""")


def _enclosing_func(lines: list[str], idx: int) -> tuple[str, list[str]]:
    start, name = 0, ""
    for i in range(idx, -1, -1):
        m = FUNC.match(lines[i])
        if m:
            start, name = i, m.group(1)
            break
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if FUNC.match(lines[j]):
            end = j
            break
    return name, lines[start:end]


def main() -> int:
    strict = "--strict" in sys.argv
    if not ENGINE.is_dir():
        print(f"[validate_signal_entry_shape] no engine dir at {ENGINE} — skipping")
        return 0

    violations: list[str] = []
    checked = 0
    for gd in sorted(ENGINE.rglob("*.gd")):
        rel = gd.relative_to(ENGINE).as_posix()
        if rel.startswith("tests/"):
            continue  # tests build entries by hand to probe the dispatcher itself
        lines = gd.read_text(encoding="utf-8", errors="replace").splitlines()
        for n, line in enumerate(lines):
            if not APPEND.search(line):
                continue
            func, body = _enclosing_func(lines, n)
            if not any("signal_buffer" in b for b in body):
                continue  # a different buffer, with a different entry shape
            # The append plus its continuation lines: gdformat wraps long ones.
            stmt = " ".join(lines[n : n + 5])
            if not NAME_KEY.search(stmt):
                continue  # appending something that is not an entry literal
            checked += 1
            if PAYLOAD_KEY.search(stmt):
                continue
            violations.append(
                f"  {rel}:{n + 1} (in {func or '<top level>'})\n"
                f"    {line.strip()}\n"
                f'    -> entry has "name" but no "payload". The dispatcher reads\n'
                f'       sig["payload"], so every field beside "name" is invisible and\n'
                f"       every rule matching this signal gets an EMPTY payload, silently.\n"
                f"       Nest the fields, or call EffectCore.push_signal(env, name, payload)."
            )

    if violations:
        print("[validate_signal_entry_shape] flat signal entries (payload undeliverable):")
        print("\n".join(violations))
        return 1 if strict else 0

    print(
        "[validate_signal_entry_shape] ok — %d signal entr%s nest their payload"
        % (checked, "y" if checked == 1 else "ies")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
