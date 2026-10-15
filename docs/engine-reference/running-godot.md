# Running Godot — tests, scenarios, captures

_Last updated: 2026-10-15_ (moved out of CLAUDE.md to cut always-on context)


`scripts/play.sh` is the single source of truth for `GODOT_BIN` and
`TEMPLATE_DST`. Both are env-overridable: `YUME_GODOT_BIN`,
`YUME_TEMPLATE_DST`. Source them in any other workflow:

```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"
# Now $GODOT_BIN and $TEMPLATE_DST are set.
```

### Standard 3-step workflow

```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"

# 1. Sync framework to template (orchestrator-only per parallel-execution discipline)
cp -r godot/. "$TEMPLATE_DST/"

# 2. cd INTO the template, then use `--path .`. The Windows Godot.exe CANNOT
#    resolve a `/mnt/c/...` path passed to `--path` from a /home CWD — it
#    aborts with "Invalid project path specified ... aborting" and prints NO
#    test output. play.sh + tools/yume_env/oracle.py both cd + `--path .` for
#    exactly this reason. NEVER use `--path "$TEMPLATE_DST"` (absolute).
cd "$TEMPLATE_DST"

# 3. Rebuild class cache if a NEW `class_name X` GDScript was added (otherwise skip)
"$GODOT_BIN" --path . --headless --import 2>&1 | tail -5

# 4. Run tests / scenarios / captures (always tee; direct stdout from the
#    Windows .exe through WSL pipes is unreliable)
"$GODOT_BIN" --path . --headless scenes/test_main.tscn 2>&1 | tee /tmp/test_out.log
"$GODOT_BIN" --path . --headless scenes/scenario_test.tscn -- --game=demo_<name> 2>&1 | tee /tmp/scen_out.log
"$GODOT_BIN" --path . --rendering-driver opengl3 scenes/<name>_3d.tscn -- --capture-after=4 --capture-output='user://x.png' 2>&1 | tee /tmp/cap.log
```

> **Invalid-project-path trap (2026-05-30).** If a run prints
> `Invalid project path specified: "/mnt/c/..." aborting` and **no
> RESULTS line**, you used the absolute `--path` form — the run never
> executed. "No output" is NOT a pass. A real run ALWAYS ends with
> `passed: NN  failed: N  total: NN`. Re-run with `cd "$TEMPLATE_DST"`
> + `--path .`. (Empirical: this silently masked an `instance_patterns`
> parse error for an hour — every "verification" aborted, read as clean.)

Unit tests should report `passed: NN  failed: 0  total: NN`. Test source:
`godot/scripts/engine/tests/test_runner.gd`; per-game scenarios in
`godot/data/demo_<name>/tests.json`. Gotchas:

- **Long runs**: test_main.tscn takes 60-120s — bump `timeout` to ≥240 or
  run in background + Monitor (`until grep -qE "passed:|RESULTS|ERROR" /tmp/f; do sleep 2; done`).
- **New `class_name X`**: run `--import` once before the test scene (else
  `Identifier "X" not declared`); verify in `.godot/global_script_class_cache.cfg`.
- **Capture path**: `user://X.png` → `/mnt/c/Users/.../AppData/Roaming/Godot/app_userdata/<project>/X.png`
  (`find /mnt/c -path "*/app_userdata/*" -name "X.png"`); Read it as a normal PNG.

