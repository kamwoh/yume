"""tools.validators — sync-time static validators for Yume.

Each `validate_<name>.py` is a standalone script. Run individually:

    python3 tools/validators/validate_<name>.py <game> [--strict]

Or run the full bank with:

    python3 tools/validators/run_all.py <game>

`scripts/play.sh` invokes the bank automatically before launching a
demo. Pass `SKIP_VALIDATE=1` to bypass.

See `.claude/rules/README.md` § Static validators for the per-script
intent + the rule each validator enforces.
"""
