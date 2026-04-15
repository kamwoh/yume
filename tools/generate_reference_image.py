#!/usr/bin/env python3
"""Generate a reference image via Gemini Image (Nano Banana).

Manual reference-image generation for Yume scenes. Takes a prompt, writes a PNG.
Used to produce reference.png files that anchor visual QA for a scene/zone/game.

Pattern borrowed from godogen's asset_gen.py image subcommand: explicit size +
aspect ratio via GenerateContentConfig, PIL re-encode (Gemini sometimes returns
JPEG in a PNG wrapper), image-to-image support via --image, and finish-reason
reporting when safety filters block.

Requires: GEMINI_API_KEY (or GOOGLE_API_KEY) env var.
Libs: google-genai, Pillow.

Usage:
  python3 generate_reference_image.py --preset medieval_house -o house.png
  python3 generate_reference_image.py --prompt "..." --size 1K --aspect-ratio 16:9 -o out.png
  python3 generate_reference_image.py --model pro --preset medieval_village -o village.png
  python3 generate_reference_image.py --preset medieval_house --image existing_ref.png -o variant.png
"""

import argparse
import io
import os
import sys
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image

MODELS = {
    "flash": "gemini-3.1-flash-image-preview",  # default — 5-15¢ depending on size
    "pro": "gemini-3-pro-image-preview",          # higher quality, higher cost
}

SIZES = ["512", "1K", "2K", "4K"]
ASPECT_RATIOS = [
    "1:1", "1:4", "1:8", "2:3", "3:2", "3:4", "4:1", "4:3",
    "4:5", "5:4", "8:1", "9:16", "16:9", "21:9",
]

# ---------------------------------------------------------------------------
# Prompts follow godogen's visual-target.md discipline:
# - Frame as "screenshot of a video game" (not concept art, not "render")
# - Clean sharp digital rendering, game engine output
# - Enumerate every object (each becomes an asset requirement downstream)
# - NO "lowpoly" / "stylized" / "pixel art" — those make output worse, not more
#   game-like. Prompt the actual COMPOSITION you need.
# - Camera framing explicit
# - Palette explicit
# ---------------------------------------------------------------------------
PRESETS = {
    "medieval_house": (
        "Screenshot of a 3D video game. Camera: elevated three-quarter view, "
        "eye-level-plus, framing one building centered. "
        "Game objects: one small medieval fantasy cottage — "
        "wooden plank walls (warm brown), red clay gable roof, small square "
        "shuttered window on one side, a wooden plank door on front, simple "
        "chimney. Building sits on a grassy square plot with a few scattered "
        "wildflowers (yellow, white). "
        "Environment: bright green grass ground, soft blue sky background. "
        "HUD: none. "
        "Art direction: warm painterly color palette, cozy fantasy village feel, "
        "readable silhouette, soft diffuse daytime lighting, clean sharp "
        "digital rendering, game engine output."
    ),
    "medieval_village": (
        "Screenshot of a 3D video game. Camera: elevated three-quarter overview, "
        "framing a small village. "
        "Game objects: central stone fountain; 5 medieval fantasy cottages "
        "arranged around it, each with wooden plank walls and gable roofs in "
        "varied colors (red, blue-grey, tan); dirt paths connecting cottages "
        "to the fountain; 3 farm plots nearby with neat green crop rows; one "
        "windmill on a low rise at the edge of frame; scattered trees around "
        "the village edges; a small round blue pond to one side. "
        "Environment: grass ground, blue sky, distant hills. "
        "HUD: none. "
        "Art direction: warm painterly color palette, cozy fantasy village feel, "
        "readable layout, soft daytime lighting, clean sharp digital rendering, "
        "game engine output."
    ),
    "character_eye_view_house": (
        "Screenshot of a 3D video game from first-person player perspective. "
        "Camera: eye-level, 1.7 meters above ground, looking forward and slightly "
        "upward toward a building 4 meters away. "
        "Game objects: one medieval fantasy cottage directly ahead filling the "
        "frame — wooden plank walls (warm brown), red clay gable roof partially "
        "visible at top, a wooden plank front door centered, small shuttered "
        "window to the right of the door. Grass ground visible at the bottom "
        "of frame. A few wildflowers near the base. "
        "Environment: blue sky above the roofline, no other buildings in view. "
        "HUD: none. "
        "Art direction: warm painterly color palette, cozy fantasy feel, "
        "clean sharp digital rendering, game engine output."
    ),
    "medieval_house_kenney": (
        "Screenshot of a 3D video game built from modular Kenney-style asset "
        "packs. Camera: elevated three-quarter view, one building centered, "
        "eye-level-plus, framing the whole structure with a small margin of "
        "ground below. "
        "Game objects: one small rectangular wooden cottage built from 4 flat "
        "wall panels forming a closed square — uniform warm brown wood-plank "
        "walls (same color on all 4 sides, no variation), a red gable roof "
        "(flat uniform red, simple triangular peak, no tile detail), a single "
        "wooden plank door centered on the front wall, one small shuttered "
        "window on a side wall, a light-grey stone chimney poking straight up "
        "through the roof. "
        "Environment: flat green grass ground, plain blue sky background, no "
        "clouds, no distant buildings, no trees, no fence, no accessories. "
        "HUD: none. "
        "Art direction: flat-shaded low-poly, chunky modular parts that fit "
        "together cleanly, uniform solid color per material (no PBR, no "
        "ambient occlusion, no painterly shading, no weathering, no "
        "atmospheric effects), clean sharp game-engine output."
    ),
}


def _mime_for_image(path: Path) -> str:
    return {
        ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".png": "image/png", ".webp": "image/webp",
    }.get(path.suffix.lower(), "image/png")


def generate(prompt: str, output: Path, model_id: str, size: str,
             aspect_ratio: str, image_ref: Path | None) -> None:
    if not os.environ.get("GEMINI_API_KEY") and not os.environ.get("GOOGLE_API_KEY"):
        sys.exit("ERROR: set GEMINI_API_KEY or GOOGLE_API_KEY env var")

    config = types.GenerateContentConfig(
        response_modalities=["IMAGE"],
        image_config=types.ImageConfig(
            image_size=size,
            aspect_ratio=aspect_ratio,
        ),
    )

    contents: list = []
    if image_ref is not None:
        if not image_ref.exists():
            sys.exit(f"ERROR: reference image not found: {image_ref}")
        contents.append(types.Part.from_bytes(
            data=image_ref.read_bytes(),
            mime_type=_mime_for_image(image_ref),
        ))
    contents.append(prompt)

    client = genai.Client()
    response = client.models.generate_content(
        model=model_id, contents=contents, config=config,
    )

    if response.parts is None:
        reason = "unknown"
        if response.candidates and response.candidates[0].finish_reason:
            reason = str(response.candidates[0].finish_reason)
        sys.exit(f"ERROR: generation blocked (reason: {reason})")

    for part in response.parts:
        if getattr(part, "inline_data", None) is not None:
            # Re-encode as real PNG — Gemini sometimes returns JPEG bytes.
            output.parent.mkdir(parents=True, exist_ok=True)
            img = Image.open(io.BytesIO(part.inline_data.data))
            img.save(output, format="PNG")
            size_kb = output.stat().st_size // 1024
            print(f"OK  {output}  ({size_kb} KB, {img.size[0]}x{img.size[1]}, model={model_id})")
            return

    sys.exit(f"ERROR: no image in response. Text: {getattr(response, 'text', None)!r}")


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--prompt", help="Free-form prompt (overrides --preset).")
    p.add_argument("--preset", choices=list(PRESETS),
                   help=f"Built-in prompt: {list(PRESETS)}")
    p.add_argument("--model", choices=list(MODELS), default="flash",
                   help="flash=cheaper/faster (default), pro=higher quality")
    p.add_argument("--size", choices=SIZES, default="1K",
                   help="Image size. Default: 1K.")
    p.add_argument("--aspect-ratio", choices=ASPECT_RATIOS, default="16:9",
                   help="Aspect ratio. Default: 16:9 (game-screenshot framing).")
    p.add_argument("--image", type=Path, default=None,
                   help="Reference image for image-to-image edit.")
    p.add_argument("-o", "--output", type=Path, default=Path("reference.png"),
                   help="Output PNG path (default: reference.png).")
    args = p.parse_args()

    prompt = args.prompt or (PRESETS[args.preset] if args.preset else None)
    if not prompt:
        p.error("provide --prompt or --preset")

    generate(
        prompt=prompt,
        output=args.output,
        model_id=MODELS[args.model],
        size=args.size,
        aspect_ratio=args.aspect_ratio,
        image_ref=args.image,
    )


if __name__ == "__main__":
    main()
