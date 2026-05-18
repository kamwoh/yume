"""animate_smoke.py — end-to-end test of ADR 0053 animation pipeline.

Targets ONE entity in ONE game and runs the full Tripo3D animation
chain:
    image_to_model → animate_prerigcheck → animate_rig
    → animate_retarget × N → glb_merge → patch entity def

Hardcoded to demo_aldenmere/npc_morwen as the smoke target. Once
this works, the same logic gets folded into pipeline.py for any
entity with visual.animate=true.

Each stage is ledger-cached individually. Re-runs skip already-paid
stages. Failures at any stage abort with diagnostic output (no
partial-state writes).

Cost: ~$1.40 (image $0.40 + prerigcheck $0.10 + rig $0.30 + 2× retarget $0.60).

Usage:
    python3 -m tools.yume_assetgen.animate_smoke
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.yume_assetgen.backends.nanobanana import NanobananaBackend  # noqa: E402
from tools.yume_assetgen.backends.tripo3d import Tripo3DBackend  # noqa: E402
from tools.yume_assetgen.glb_merge import merge as glb_merge  # noqa: E402
from tools.yume_assetgen.ledger import (  # noqa: E402
    load_ledger,
    prompt_hash,
)

GAME = "demo_aldenmere"
ENTITY_ID = "npc_morwen"
RIG_TYPE = "biped"
CLIPS = ["preset:idle", "preset:walk"]
# Engine-side state names. Each CLIPS[i] retarget result gets renamed
# to ENGINE_CLIP_NAMES[i] during glb_merge — Tripo/Blender exports clips
# as "NlaTrack" / "NlaTrack_2" otherwise, which animation_state_rules
# can't address. Renaming during merge bridges Tripo preset IDs to
# engine state names without needing a clip_alias indirection.
ENGINE_CLIP_NAMES = ["idle", "walk"]
RIG_MODEL_VERSION = "v1.0-20240301"

FULL_BODY_REF_PROMPT = (
    "elderly village matriarch in T-POSE for 3D model rigging, "
    "arms straight out horizontal to the sides palms facing down, "
    "legs slightly apart shoulder-width, fingers spread open, "
    "full body from head to feet, front view with feet visible at the base of the frame, "
    "grey-haired weathered kind face, "
    "knee-length earthy-brown wool tunic showing legs, brown wool trousers, "
    "leather boots, "
    "NO held items, NO staff, NO long robe, NO cloak, NO held objects, "
    "viewable from any angle, low-poly stylized, painterly, "
    "earnest folkloric aesthetic"
)
FULL_BODY_MESH_PROMPT = (
    "low-poly stylized elderly village matriarch full body T-pose v3, "
    "arms straight out horizontal palms down, legs apart, fingers spread, "
    "grey hair tied back, knee-length brown wool tunic, brown trousers, "
    "leather boots, no held items, no robe, no cloak, "
    "rigged for biped animation"
)


def _read_glb_bbox_min_y(path: Path) -> float | None:
    raw = path.read_bytes()
    if raw[:4] != b"glTF":
        return None
    json_len = struct.unpack_from("<II", raw, 12)[0]
    doc = json.loads(raw[20 : 20 + json_len].decode("utf-8"))
    min_y = float("inf")
    for m in doc.get("meshes", []):
        for p in m.get("primitives", []):
            pos = p.get("attributes", {}).get("POSITION")
            if pos is None:
                continue
            acc = doc["accessors"][pos]
            mn = acc.get("min", [])
            if len(mn) >= 2:
                min_y = min(min_y, float(mn[1]))
    return None if min_y == float("inf") else min_y


def _find_entity(doc: dict, entity_id: str) -> dict | None:
    for d in doc.get("definitions", []):
        if isinstance(d, dict) and d.get("id") == entity_id:
            return d
    return None


def main() -> int:
    game_dir = ROOT / "godot" / "data" / GAME
    villagers_path = game_dir / "entities" / "villagers.json"
    doc = json.loads(villagers_path.read_text(encoding="utf-8"))
    target = _find_entity(doc, ENTITY_ID)
    if target is None:
        print(f"ERROR: {ENTITY_ID} not found in {villagers_path}")
        return 2
    visual = target["visual"]

    # v3 test (2026-05-18): image-to-3D with a FRESHLY-generated
    # rig-friendly concept. The new concept uses nanobanana + the
    # background-stripping concept_suffix from asset_gen.json, plus a
    # T-pose mesh_reference_prompt. If the concept comes out clean (no
    # scenery, T-pose, no held items), Tripo's image-to-3D should both
    # PASS prerigcheck AND give better style than text-to-3D.
    import hashlib as _hl
    concept_dir = game_dir / "assets" / "concepts"
    concept_dir.mkdir(parents=True, exist_ok=True)
    # Load the game's asset_gen.json for the concept_suffix
    asset_cfg_path = game_dir / "asset_gen.json"
    asset_cfg = json.loads(asset_cfg_path.read_text(encoding="utf-8"))
    style = asset_cfg.get("style", {})
    concept_suffix = style.get("concept_suffix", "")
    assembled_concept_prompt = FULL_BODY_REF_PROMPT + concept_suffix
    concept_hash = _hl.sha256(assembled_concept_prompt.encode("utf-8")).hexdigest()[:8]
    concept_path = concept_dir / f"{ENTITY_ID}_v3_{concept_hash}.png"
    if not concept_path.exists():
        print(f"[smoke] generating fresh concept via nanobanana ({concept_hash})")
        nano_cfg = asset_cfg.get("backend_config", {}).get("nanobanana", {})
        nano = NanobananaBackend(nano_cfg)
        nano.generate_texture(assembled_concept_prompt, concept_path, size=(512, 512))
        print(f"[smoke] concept saved → {concept_path.name}")
    else:
        print(f"[smoke] using existing concept: {concept_path.name}")

    backend = Tripo3DBackend(
        {
            "api_key_env": "TRIPO_API_KEY",
            "model_version": "v2.5-20250123",
            "rig_model_version": RIG_MODEL_VERSION,
            "texture": True,
            "pbr": True,
            "poll_interval": 5.0,
        }
    )
    if not os.environ.get("TRIPO_API_KEY", "").strip():
        print("ERROR: TRIPO_API_KEY not set in environment")
        return 2

    ledger = load_ledger(game_dir)
    p_hash = prompt_hash(FULL_BODY_MESH_PROMPT)

    print(f"[smoke] target: {GAME}/{ENTITY_ID}")
    print(f"[smoke] rig_type: {RIG_TYPE}, clips: {CLIPS}")
    print(f"[smoke] prompt: {FULL_BODY_MESH_PROMPT[:80]}...")
    print(f"[smoke] prompt_hash: {p_hash}")

    out_dir = game_dir / "assets" / "meshes"
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- Stage 1: image_to_model
    print(f"\n[smoke] === Stage 1: image_to_model ===")
    base_hit = ledger.has("tripo3d", "tripo3d_base", p_hash)
    if base_hit:
        print(f"[smoke] (ledger cached, skip) base_task_id={base_hit.get('task_id', '?')}")
        # Reconstruct base task id + paths from ledger
        base_task_id = base_hit.get("task_id", "")
        base_glb = game_dir / base_hit.get("out_path", "")
    else:
        api_key = backend._get_api_key()
        if concept_path is not None and concept_path.exists():
            file_token = backend._upload_image(concept_path, api_key)
            print(f"[smoke] image uploaded, file_token={file_token[:8]}...")
            base_task_id = backend._submit_image_to_model(
                file_token, FULL_BODY_MESH_PROMPT, api_key
            )
            print(f"[smoke] image_to_model submitted, task_id={base_task_id}")
        else:
            base_task_id = backend._submit_text_to_model(
                FULL_BODY_MESH_PROMPT, api_key
            )
            print(f"[smoke] text_to_model submitted, task_id={base_task_id}")
        base_url = backend._poll_until_done(base_task_id, api_key)
        base_glb = out_dir / f"{ENTITY_ID}_base_{base_task_id[:8]}.glb"
        backend._download(base_url, base_glb)
        print(f"[smoke] base mesh downloaded → {base_glb.name}")
        ledger.add(
            backend="tripo3d",
            kind="tripo3d_base",
            entity_id=ENTITY_ID,
            prompt=FULL_BODY_MESH_PROMPT,
            p_hash=p_hash,
            out_path=str(base_glb.relative_to(game_dir)),
            extra={"task_id": base_task_id},
        )
        ledger.save()

    # --- Stage 2: animate_prerigcheck
    print(f"\n[smoke] === Stage 2: animate_prerigcheck ===")
    pre_disc = f"{RIG_TYPE}:{RIG_MODEL_VERSION}"
    pre_hit = ledger.has(
        "tripo3d", "tripo3d_prerigcheck", p_hash, discriminator=pre_disc
    )
    if pre_hit:
        riggable = bool(pre_hit.get("riggable", False))
        print(f"[smoke] (ledger cached) riggable={riggable}")
    else:
        api_key = backend._get_api_key()
        pre_task = backend._submit_prerigcheck(base_task_id, api_key)
        print(f"[smoke] prerigcheck submitted, task_id={pre_task}")
        pre_out = backend._poll_for_status_dict(pre_task, api_key)
        riggable = bool(pre_out.get("riggable", False))
        print(f"[smoke] prerigcheck result: riggable={riggable}, output={pre_out}")
        ledger.add(
            backend="tripo3d",
            kind="tripo3d_prerigcheck",
            entity_id=ENTITY_ID,
            prompt=FULL_BODY_MESH_PROMPT,
            p_hash=p_hash,
            out_path="",
            discriminator=pre_disc,
            extra={"riggable": riggable, "task_id": pre_task},
        )
        ledger.save()

    if not riggable:
        print(f"[smoke] FAIL: Tripo prerigcheck rejected the base mesh.")
        print(f"[smoke] Entity stays static; the cached REJECT verdict")
        print(f"[smoke] persists in the ledger for {pre_disc}.")
        return 1

    # --- Stage 3: animate_rig
    print(f"\n[smoke] === Stage 3: animate_rig ===")
    rig_disc = f"{RIG_TYPE}:{RIG_MODEL_VERSION}"
    rig_hit = ledger.has(
        "tripo3d", "tripo3d_rig", p_hash, discriminator=rig_disc
    )
    if rig_hit:
        rig_task_id = rig_hit.get("task_id", "")
        rig_glb = game_dir / rig_hit.get("out_path", "")
        print(f"[smoke] (ledger cached) rig_task_id={rig_task_id}")
    else:
        api_key = backend._get_api_key()
        rig_task_id = backend._submit_rig(base_task_id, RIG_TYPE, api_key)
        print(f"[smoke] rig submitted, task_id={rig_task_id}")
        rig_url = backend._poll_until_done(rig_task_id, api_key)
        rig_glb = out_dir / f"{ENTITY_ID}_rig_{rig_task_id[:8]}.glb"
        backend._download(rig_url, rig_glb)
        print(f"[smoke] rigged mesh downloaded → {rig_glb.name}")
        ledger.add(
            backend="tripo3d",
            kind="tripo3d_rig",
            entity_id=ENTITY_ID,
            prompt=FULL_BODY_MESH_PROMPT,
            p_hash=p_hash,
            out_path=str(rig_glb.relative_to(game_dir)),
            discriminator=rig_disc,
            extra={"task_id": rig_task_id},
        )
        ledger.save()

    # --- Stage 4: animate_retarget × N
    print(f"\n[smoke] === Stage 4: animate_retarget ({len(CLIPS)} clips) ===")
    retarget_glbs: list[Path] = []
    for clip in CLIPS:
        rt_disc = f"{RIG_TYPE}:{clip}:{RIG_MODEL_VERSION}"
        rt_hit = ledger.has(
            "tripo3d", "tripo3d_retarget", p_hash, discriminator=rt_disc
        )
        if rt_hit:
            rt_glb = game_dir / rt_hit.get("out_path", "")
            retarget_glbs.append(rt_glb)
            print(f"[smoke] (ledger cached) retarget '{clip}' → {rt_glb.name}")
            continue
        api_key = backend._get_api_key()
        rt_task = backend._submit_retarget(rig_task_id, clip, api_key)
        print(f"[smoke] retarget '{clip}' submitted, task_id={rt_task}")
        rt_url = backend._poll_until_done(rt_task, api_key)
        safe_clip = clip.replace(":", "_")
        rt_glb = out_dir / f"{ENTITY_ID}_{safe_clip}_{rt_task[:8]}.glb"
        backend._download(rt_url, rt_glb)
        retarget_glbs.append(rt_glb)
        print(f"[smoke] retarget '{clip}' downloaded → {rt_glb.name}")
        ledger.add(
            backend="tripo3d",
            kind="tripo3d_retarget",
            entity_id=ENTITY_ID,
            prompt=FULL_BODY_MESH_PROMPT,
            p_hash=p_hash,
            out_path=str(rt_glb.relative_to(game_dir)),
            discriminator=rt_disc,
            extra={"task_id": rt_task},
        )
        ledger.save()

    # --- Stage 5: merge (with clip renaming)
    print(f"\n[smoke] === Stage 5: glb_merge ===")
    merge_hash = hashlib.sha256(
        (FULL_BODY_MESH_PROMPT + ":" + ",".join(CLIPS)).encode("utf-8")
    ).hexdigest()[:8]
    merged_path = out_dir / f"{ENTITY_ID}_animated_{merge_hash}.glb"
    glb_merge(
        retarget_glbs,
        merged_path,
        on_name_collision="suffix",
        rename_animations=ENGINE_CLIP_NAMES,
    )
    print(f"[smoke] merged → {merged_path.name}")
    print(f"[smoke] clips renamed: {ENGINE_CLIP_NAMES}")

    # --- Stage 6: patch entity def
    print(f"\n[smoke] === Stage 6: patch entity def ===")
    rel_mesh = f"res://data/{GAME}/assets/meshes/{merged_path.name}"
    visual["mesh"] = rel_mesh
    visual["mesh_reference_prompt"] = FULL_BODY_REF_PROMPT
    visual["mesh_prompt"] = FULL_BODY_MESH_PROMPT
    visual["animate"] = True
    visual["rig_type"] = RIG_TYPE
    visual["animation_clips"] = ENGINE_CLIP_NAMES
    # Clip names in the merged GLB are renamed to ENGINE_CLIP_NAMES during
    # merge (see Stage 5), so no clip_alias indirection is needed.
    visual.pop("clip_alias", None)
    # ADR 0046 schema — flat keys, NOT nested "if"
    visual["animation_state_rules"] = [
        {"if_velocity_gt": 0.1, "state": "walk"},
        {"default": "idle"},
    ]
    # Re-derive y_offset_mesh from the merged GLB's bbox
    bbox_min_y = _read_glb_bbox_min_y(merged_path)
    if bbox_min_y is not None and bbox_min_y < -0.01:
        visual["y_offset_mesh"] = round(-bbox_min_y, 4)
        visual.pop("y_offset", None)
        print(f"[smoke] y_offset_mesh = {visual['y_offset_mesh']} (from bbox.min.y={bbox_min_y:.4f})")
    # Clean up stale comments
    visual.pop("_comment_static_mesh", None)
    visual["_comment_animated"] = (
        f"ADR 0053 animated mesh — {len(CLIPS)} clips ({', '.join(CLIPS)}). "
        f"Rig: {RIG_TYPE}. Engine drives clips via animation_state_rules + clip_alias. "
        f"Generated 2026-05-18 via animate_smoke.py."
    )
    villagers_path.write_text(
        json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[smoke] patched {villagers_path}")

    print(f"\n[smoke] SUCCESS")
    print(f"  base:      {base_glb.name}")
    print(f"  rig:       {rig_glb.name}")
    print(f"  retargets: {[g.name for g in retarget_glbs]}")
    print(f"  merged:    {merged_path.name}")
    print(f"  entity:    {ENTITY_ID} patched (visual.mesh + animation fields)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
