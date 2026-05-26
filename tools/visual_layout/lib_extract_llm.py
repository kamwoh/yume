"""lib_extract_llm.py — LLM-gestalt extraction strategy for stage-5
of the text-to-world pipeline.

For classes where dense semantic-map texture should collapse to fewer
larger structures (gestalt grouping that CV's connected-component
threshold can't see). Example: a "house district" semantic mass that
should resolve to 6 discrete houses, not 60 small cluster centroids.

The user-stated rule of thumb: prefer CV. Use this only when the
class's strategy in extraction_strategies.json explicitly picks
extraction_method='llm_gestalt'. Today only one class entry would
do that, but the dispatch is here so the vocabulary is closed.

Endpoint: OpenAI chat/completions with vision. Pure stdlib via
urllib.request — no `openai` SDK dependency (mirrors the
openai_images backend convention).

Usage from lib_extract_v2.py's dispatcher:

    from tools.visual_layout.lib_extract_llm import gestalt_extract
    instances = gestalt_extract(
        class_entry=c,
        semantic_map_path=...,
        image_size=(W, H),
        world_size_m=(80, 80),
        sampler=heightmap_sampler,
        anchors=anchors,
    )

Returns the same instance-dict shape as the CV methods.
"""
from __future__ import annotations

import base64
import json
import math
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from tools.visual_layout import lib_extract as cv


OPENAI_CHAT_URL = "https://api.openai.com/v1/chat/completions"
DEFAULT_MODEL = "gpt-4o-2024-11-20"


# ============================================================
# PROMPT
# ============================================================

def _build_prompt(class_entry: dict, image_size: tuple[int, int]) -> str:
    """Build the user prompt. Asks the VLM to enumerate instances of
    the target class as a JSON list of pixel positions + optional
    facing hints."""
    name = class_entry["name"]
    hex_ = class_entry.get("hex", "")
    desc = class_entry.get("description", "")
    expected_count = class_entry.get("expected_count", None)
    W, H = image_size

    expected_str = (
        f"Expected count: roughly {expected_count} instances.\n"
        if expected_count else ""
    )

    return (
        f"You are a layout-extractor for a 2D semantic map.\n"
        f"The map is a {W}x{H} pixel image where colored regions encode\n"
        f"different scene classes. Your task: enumerate every distinct\n"
        f"INSTANCE of the class '{name}' (hex color {hex_}).\n\n"
        f"Class description: {desc}\n"
        f"{expected_str}\n"
        f"Each instance should be ONE building / structure / object —\n"
        f"NOT one pixel and NOT one connected component. Use GESTALT\n"
        f"grouping: a roof-textured neighborhood block of N houses is\n"
        f"N instances, not 1 mass and not 60 dots.\n\n"
        f"Image origin is top-left (0,0). X increases rightward, Y\n"
        f"increases downward. Pixel coordinates are integers.\n\n"
        f"Return STRICT JSON of the form:\n"
        f"  {{\"instances\": [\n"
        f"    {{\"x\": <int>, \"y\": <int>, \"size_px\": <int>}},\n"
        f"    ...\n"
        f"  ]}}\n\n"
        f"size_px is the approximate diameter of the instance's\n"
        f"footprint in pixels. NO text outside the JSON object."
    )


# ============================================================
# HTTP CALL
# ============================================================

def _encode_image(path: str | Path) -> str:
    """Base64-encode the image file."""
    b = Path(path).read_bytes()
    return base64.b64encode(b).decode("ascii")


def _call_openai_vision(
    *,
    image_path: str | Path,
    prompt: str,
    model: str = DEFAULT_MODEL,
    api_key: str | None = None,
    timeout: int = 120,
) -> dict:
    """POST to chat/completions with vision input. Returns the parsed
    JSON content of the assistant's reply.

    Raises RuntimeError on HTTP failure or invalid JSON output.
    """
    api_key = api_key or os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError(
            "llm_gestalt: OPENAI_API_KEY not set in environment"
        )

    image_b64 = _encode_image(image_path)
    suffix = Path(image_path).suffix.lstrip(".").lower() or "png"
    mime = {"jpg": "jpeg"}.get(suffix, suffix)

    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {
                        "url": f"data:image/{mime};base64,{image_b64}",
                    }},
                ],
            }
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.0,
    }

    req = urllib.request.Request(
        OPENAI_CHAT_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"llm_gestalt: HTTP {e.code}: {msg}") from None

    data = json.loads(body)
    if "choices" not in data or not data["choices"]:
        raise RuntimeError(f"llm_gestalt: empty response: {data}")
    content = data["choices"][0]["message"]["content"]
    try:
        return json.loads(content)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"llm_gestalt: model returned non-JSON: {content[:200]}"
        ) from e


# ============================================================
# PUBLIC ENTRY POINT
# ============================================================

def gestalt_extract(
    *,
    class_entry: dict,
    semantic_map_path: str | Path,
    image_size: tuple[int, int],
    world_size_m: tuple[float, float],
    sampler: Any | None = None,
    anchors: dict | None = None,
    model: str = DEFAULT_MODEL,
    api_key: str | None = None,
    dry_run: bool = False,
) -> list[dict]:
    """Extract instances of class_entry via a single VLM call.

    Returns a list of instance dicts in the same shape as the CV
    methods (class / id / position / facing / scale / primitive /
    canonical_front_axis).

    `dry_run=True` skips the API call and returns []. Useful for unit
    tests + when OPENAI_API_KEY isn't available.
    """
    if dry_run or not os.environ.get("OPENAI_API_KEY"):
        if not dry_run:
            print(
                f"[lib_extract_llm] OPENAI_API_KEY not set — skipping "
                f"gestalt extraction for class '{class_entry.get('name')}'",
                file=sys.stderr,
            )
        return []

    prompt = _build_prompt(class_entry, image_size)
    raw = _call_openai_vision(
        image_path=semantic_map_path,
        prompt=prompt,
        model=model,
        api_key=api_key,
    )

    items = raw.get("instances", [])
    if not isinstance(items, list):
        raise RuntimeError(
            f"llm_gestalt: 'instances' is not a list: {type(items).__name__}"
        )

    strategy = class_entry["strategy"]
    canonical = strategy.get("canonical_size_meters", [2.0, 2.0, 2.0])
    name = class_entry["name"]

    out: list[dict] = []
    for i, it in enumerate(items, start=1):
        if not isinstance(it, dict):
            continue
        try:
            cx_px = float(it["x"])
            cy_px = float(it["y"])
        except (KeyError, TypeError, ValueError):
            continue
        wx, wz = cv.pixel_to_world(cx_px, cy_px, image_size, world_size_m)
        wy = sampler.y_at(wx, wz) if sampler is not None else 0.0

        # Optional facing rule still applies. Default no_rotation since the
        # VLM already gestalt-grouped; rotation hints are upstream's job.
        facing = 0.0

        out.append({
            "class": name,
            "id": f"{name}_{i:03d}",
            "position": [round(wx, 3), wy, round(wz, 3)],
            "yaw": facing,
            "scale": [float(canonical[0]), float(canonical[1]),
                      float(canonical[2])],
            "primitive": strategy.get("primitive", "prim_unit_box"),
            "canonical_front_axis": strategy.get(
                "canonical_front_axis", "-Z"
            ),
        })
    return out


# ============================================================
# CLI (manual debugging)
# ============================================================

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--semantic-map", required=True)
    parser.add_argument("--world-x", type=float, default=80.0)
    parser.add_argument("--world-z", type=float, default=80.0)
    parser.add_argument("--out", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    catalog = json.loads(Path(args.catalog).read_text())
    target = next(
        (c for c in catalog["classes"] if c["name"] == args.class_name), None
    )
    if target is None:
        sys.exit(f"class '{args.class_name}' not in catalog")
    if "strategy" not in target:
        sys.exit(f"class '{args.class_name}' has no strategy block — "
                 f"run yume-scene-class-catalog Step 4b first")

    img = cv.load_rgb(args.semantic_map)
    H, W = img.shape[:2]

    instances = gestalt_extract(
        class_entry=target,
        semantic_map_path=args.semantic_map,
        image_size=(W, H),
        world_size_m=(args.world_x, args.world_z),
        dry_run=args.dry_run,
    )
    Path(args.out).write_text(json.dumps({
        "n_instances": len(instances), "instances": instances
    }, indent=2))
    print(f"Wrote {len(instances)} instances to {args.out}")
