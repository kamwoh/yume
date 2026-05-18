"""
`python3 -m tools.yume_assetgen <game>` — run the pipeline.

Flags:
    --dry-run             list what would be generated, don't write
    --backend <name>      override asset_gen.json's backend choice
    --only-textures       skip mesh prompts
    --only-meshes         skip texture prompts
    --init                drop a starter asset_gen.json into the game dir
    --quiet               suppress per-item logging
"""

import argparse
import json
import sys
from pathlib import Path

from .config import save_config_template
from .pipeline import run_pipeline


REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"


def main(argv=None):
    ap = argparse.ArgumentParser(prog="yume_assetgen")
    ap.add_argument("game", help="game folder name (e.g. demo_aldenmere)")
    ap.add_argument("--dry-run", action="store_true",
                    help="list outputs without generating")
    ap.add_argument("--backend", default=None,
                    help="override backend (mock / openai_images / ...)")
    ap.add_argument("--only-textures", action="store_true")
    ap.add_argument("--only-meshes", action="store_true")
    ap.add_argument("--init", action="store_true",
                    help="drop a starter asset_gen.json into the game dir and exit")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--json", action="store_true",
                    help="print full summary as JSON at the end")
    args = ap.parse_args(argv)

    game_dir = DATA_ROOT / args.game
    if not game_dir.exists():
        print(f"error: {game_dir} does not exist", file=sys.stderr)
        return 1

    if args.init:
        try:
            p = save_config_template(game_dir)
            print(f"wrote starter config: {p}")
            return 0
        except FileExistsError as e:
            print(f"error: {e}", file=sys.stderr)
            print("(pass --init --force to overwrite — not implemented yet; edit by hand)",
                  file=sys.stderr)
            return 1

    only = None
    if args.only_textures and args.only_meshes:
        print("error: --only-textures and --only-meshes are mutually exclusive",
              file=sys.stderr)
        return 2
    if args.only_textures:
        only = "texture"
    elif args.only_meshes:
        only = "mesh"

    summary = run_pipeline(
        game_dir,
        only=only,
        dry_run=args.dry_run,
        backend_override=args.backend,
        verbose=not args.quiet,
    )

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        # `backends` is a per-kind dict {texture, mesh, concept}; render
        # as "texture=nanobanana mesh=tripo3d" — much more useful than
        # one string when the pipeline routes per-kind.
        backends_dict = summary.get("backends", {})
        b_str = " ".join(f"{k}={v}" for k, v in backends_dict.items())
        print(
            f"\n[{summary['game']}] {b_str} "
            f"scanned={summary['scanned']} "
            f"generated={summary['generated']} "
            f"skipped_existing={summary['skipped_existing']} "
            f"skipped_ledger={summary.get('skipped_ledger', 0)} "
            f"patched={summary['patched']} "
            f"errors={len(summary['errors'])}"
        )

    return 0 if not summary["errors"] else 1


if __name__ == "__main__":
    sys.exit(main())
