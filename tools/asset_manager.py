#!/usr/bin/env python3
"""Yume Asset Manager — web UI showing all asset prompts, existing assets, and generate buttons.

Usage:
    python tools/asset_manager.py /path/to/game/data/
    → Opens browser at http://localhost:8420
"""

import json
import sys
import os
from pathlib import Path
from http.server import HTTPServer, SimpleHTTPRequestHandler
import webbrowser
import urllib.parse


def scan_assets(data_dir: Path, project_dir: Path):
    """Scan all JSON files for asset prompts and check if assets exist."""
    assets = {"characters": [], "enemies": [], "props": set(), "locations": [], "items": []}

    # Characters
    chars_file = data_dir / "characters.json"
    if chars_file.exists():
        for c in json.loads(chars_file.read_text()):
            cid = c.get("id", "")
            asset = {
                "id": cid,
                "name": c.get("name", cid),
                "type": "character",
                "color": c.get("color", [0.5, 0.5, 0.5]),
                "prompts": {},
                "files": {},
            }
            # Collect prompts
            if c.get("portrait_prompt"):
                asset["prompts"]["portrait"] = c["portrait_prompt"]
            if c.get("sprite_prompts"):
                for k, v in c["sprite_prompts"].items():
                    asset["prompts"][f"sprite_{k}"] = v
            if c.get("voice_prompt"):
                asset["prompts"]["voice"] = c["voice_prompt"]
            if c.get("model_prompt"):
                asset["prompts"]["3d_model (Tripo/Meshy)"] = c["model_prompt"]
            if c.get("portrait_3d_prompt"):
                asset["prompts"]["3d_portrait (Tripo)"] = c["portrait_3d_prompt"]
            if c.get("nanobanana_prompt"):
                asset["prompts"]["sprite (NanoBanana)"] = c["nanobanana_prompt"]
            if c.get("nanobanana_portrait_prompt"):
                asset["prompts"]["portrait (NanoBanana)"] = c["nanobanana_portrait_prompt"]
            if c.get("nanobanana_3d_prompt"):
                asset["prompts"]["3d (NanoBanana)"] = c["nanobanana_3d_prompt"]

            # Check existing files
            for ext in ["png", "jpg", "webp"]:
                p = project_dir / "sprites" / "characters" / f"{cid}.{ext}"
                if p.exists():
                    asset["files"]["sprite"] = str(p)
            for ext in ["glb", "gltf", "obj"]:
                p = project_dir / "models" / "characters" / f"{cid}.{ext}"
                if p.exists():
                    asset["files"]["model"] = str(p)

            assets["characters"].append(asset)

    # Enemies
    enemies_file = data_dir / "enemies.json"
    if enemies_file.exists():
        for e in json.loads(enemies_file.read_text()):
            eid = e.get("id", "")
            asset = {
                "id": eid,
                "name": e.get("name", eid),
                "type": "enemy",
                "prompts": {},
                "files": {},
            }
            if e.get("sprite_prompt"):
                asset["prompts"]["sprite"] = e["sprite_prompt"]
            if e.get("model_prompt"):
                asset["prompts"]["3d_model (Tripo/Meshy)"] = e["model_prompt"]
            if e.get("nanobanana_prompt"):
                asset["prompts"]["sprite (NanoBanana)"] = e["nanobanana_prompt"]
            if e.get("nanobanana_3d_prompt"):
                asset["prompts"]["3d (NanoBanana)"] = e["nanobanana_3d_prompt"]
            if e.get("sfx_prompts"):
                for k, v in e["sfx_prompts"].items():
                    asset["prompts"][f"sfx_{k}"] = v

            for ext in ["png", "jpg"]:
                p = project_dir / "sprites" / "enemies" / f"{eid}.{ext}"
                if p.exists():
                    asset["files"]["sprite"] = str(p)
            for ext in ["glb", "gltf"]:
                p = project_dir / "models" / "enemies" / f"{eid}.{ext}"
                if p.exists():
                    asset["files"]["model"] = str(p)

            assets["enemies"].append(asset)

    # Locations
    loc_dir = data_dir / "locations"
    if loc_dir.exists():
        for f in sorted(loc_dir.glob("*.json")):
            loc = json.loads(f.read_text())
            lid = loc.get("id", "")
            asset = {
                "id": lid,
                "name": loc.get("name", lid),
                "type": "location",
                "prompts": {},
                "files": {},
            }
            if loc.get("background_prompt"):
                asset["prompts"]["background"] = loc["background_prompt"]
            atmo = loc.get("atmosphere", {})
            if atmo.get("bgm_prompt"):
                asset["prompts"]["bgm"] = atmo["bgm_prompt"]
            if atmo.get("ambience_prompt"):
                asset["prompts"]["ambience"] = atmo["ambience_prompt"]

            # Collect unique props
            for prop in loc.get("props", []):
                assets["props"].add(prop.get("type", ""))

            for ext in ["png", "jpg"]:
                p = project_dir / "sprites" / "backgrounds" / f"{lid}.{ext}"
                if p.exists():
                    asset["files"]["background"] = str(p)

            assets["locations"].append(asset)

    # Convert props set to list with file checks
    prop_list = []
    for ptype in sorted(assets["props"]):
        if not ptype:
            continue
        pa = {"id": ptype, "name": ptype, "type": "prop", "prompts": {}, "files": {}}
        for ext in ["png", "jpg"]:
            p = project_dir / "sprites" / "props" / f"{ptype}.{ext}"
            if p.exists():
                pa["files"]["sprite"] = str(p)
        for ext in ["glb", "gltf"]:
            p = project_dir / "models" / "props" / f"{ptype}.{ext}"
            if p.exists():
                pa["files"]["model"] = str(p)
        prop_list.append(pa)
    assets["props"] = prop_list

    return assets


def generate_html(assets, data_dir):
    """Generate the asset manager HTML page."""

    def count_status(items):
        total = len(items)
        has_sprite = sum(1 for i in items if "sprite" in i.get("files", {}))
        has_model = sum(1 for i in items if "model" in i.get("files", {}))
        return total, has_sprite, has_model

    c_total, c_sprite, c_model = count_status(assets["characters"])
    e_total, e_sprite, e_model = count_status(assets["enemies"])
    p_total, p_sprite, p_model = count_status(assets["props"])
    l_total = len(assets["locations"])
    l_bg = sum(1 for l in assets["locations"] if "background" in l.get("files", {}))

    def asset_card(item):
        name = item["name"]
        aid = item["id"]
        prompts_html = ""
        for k, v in item.get("prompts", {}).items():
            prompts_html += f'<div class="prompt"><span class="prompt-label">{k}:</span> {v}</div>'

        files_html = ""
        for k, v in item.get("files", {}).items():
            files_html += f'<div class="file-exists">✓ {k}: {Path(v).name}</div>'

        has_any = len(item.get("files", {})) > 0
        status_class = "has-assets" if has_any else "no-assets"

        color_style = ""
        if "color" in item:
            c = item["color"]
            color_style = f'background: rgb({int(c[0]*255)},{int(c[1]*255)},{int(c[2]*255)});'

        return f'''
        <div class="card {status_class}">
            <div class="card-header">
                <div class="color-swatch" style="{color_style}"></div>
                <strong>{name}</strong> <span class="id">({aid})</span>
            </div>
            {prompts_html}
            {files_html}
            <div class="actions">
                <button onclick="copyPrompt('{aid}')">Copy Prompt</button>
                <button class="gen-btn" onclick="generate('{aid}', '2d')">Generate 2D</button>
                <button class="gen-btn" onclick="generate('{aid}', '3d')">Generate 3D</button>
            </div>
        </div>'''

    cards = {"characters": "", "enemies": "", "props": "", "locations": ""}
    for cat in cards:
        for item in assets[cat]:
            cards[cat] += asset_card(item)

    return f'''<!DOCTYPE html>
<html><head>
<title>Yume Asset Manager</title>
<style>
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    body {{ font-family: -apple-system, sans-serif; background: #1a1a2e; color: #e0e0e0; }}
    .header {{ background: #16213e; padding: 20px; display: flex; justify-content: space-between; align-items: center; }}
    .header h1 {{ color: #e8b83a; }}
    .stats {{ display: flex; gap: 20px; }}
    .stat {{ text-align: center; padding: 8px 16px; background: #0f3460; border-radius: 8px; }}
    .stat-num {{ font-size: 24px; font-weight: bold; color: #e8b83a; }}
    .stat-label {{ font-size: 11px; color: #888; }}
    .tabs {{ display: flex; background: #16213e; border-bottom: 2px solid #e8b83a; }}
    .tab {{ padding: 12px 24px; cursor: pointer; color: #888; }}
    .tab.active {{ color: #e8b83a; border-bottom: 2px solid #e8b83a; }}
    .tab:hover {{ color: #e0e0e0; }}
    .content {{ padding: 20px; display: none; }}
    .content.active {{ display: block; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 16px; }}
    .card {{ background: #16213e; border-radius: 8px; padding: 16px; border: 1px solid #333; }}
    .card.has-assets {{ border-color: #2ecc71; }}
    .card.no-assets {{ border-color: #555; }}
    .card-header {{ display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }}
    .color-swatch {{ width: 16px; height: 16px; border-radius: 50%; border: 1px solid #555; }}
    .id {{ color: #666; font-size: 12px; }}
    .prompt {{ font-size: 12px; color: #aaa; margin: 4px 0; padding: 4px 8px; background: #0f3460; border-radius: 4px; }}
    .prompt-label {{ color: #e8b83a; font-weight: bold; }}
    .file-exists {{ color: #2ecc71; font-size: 12px; margin: 2px 0; }}
    .actions {{ margin-top: 8px; display: flex; gap: 8px; }}
    button {{ padding: 6px 12px; border: 1px solid #555; background: #0f3460; color: #e0e0e0; border-radius: 4px; cursor: pointer; font-size: 12px; }}
    button:hover {{ background: #1a4a8a; }}
    .gen-btn {{ background: #1a5a2a; border-color: #2ecc71; }}
    .gen-btn:hover {{ background: #2a7a3a; }}
</style>
</head><body>

<div class="header">
    <h1>夢 Yume Asset Manager</h1>
    <div class="stats">
        <div class="stat"><div class="stat-num">{c_sprite}/{c_total}</div><div class="stat-label">Character Sprites</div></div>
        <div class="stat"><div class="stat-num">{c_model}/{c_total}</div><div class="stat-label">Character 3D</div></div>
        <div class="stat"><div class="stat-num">{e_sprite}/{e_total}</div><div class="stat-label">Enemy Sprites</div></div>
        <div class="stat"><div class="stat-num">{p_sprite}/{p_total}</div><div class="stat-label">Prop Sprites</div></div>
        <div class="stat"><div class="stat-num">{l_bg}/{l_total}</div><div class="stat-label">Backgrounds</div></div>
    </div>
</div>

<div class="tabs">
    <div class="tab active" onclick="showTab('characters')">Characters ({c_total})</div>
    <div class="tab" onclick="showTab('enemies')">Enemies ({e_total})</div>
    <div class="tab" onclick="showTab('props')">Props ({p_total})</div>
    <div class="tab" onclick="showTab('locations')">Locations ({l_total})</div>
</div>

<div id="characters" class="content active"><div class="grid">{cards["characters"]}</div></div>
<div id="enemies" class="content"><div class="grid">{cards["enemies"]}</div></div>
<div id="props" class="content"><div class="grid">{cards["props"]}</div></div>
<div id="locations" class="content"><div class="grid">{cards["locations"]}</div></div>

<script>
function showTab(name) {{
    document.querySelectorAll('.content').forEach(c => c.classList.remove('active'));
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.getElementById(name).classList.add('active');
    event.target.classList.add('active');
}}
function copyPrompt(id) {{
    const card = event.target.closest('.card');
    const prompts = card.querySelectorAll('.prompt');
    const text = Array.from(prompts).map(p => p.textContent).join('\\n');
    navigator.clipboard.writeText(text);
    event.target.textContent = 'Copied!';
    setTimeout(() => event.target.textContent = 'Copy Prompt', 1000);
}}
function generate(id, type) {{
    alert('API integration coming soon! For now, copy the prompt and paste into Tripo3D / Meshy.ai');
}}
</script>
</body></html>'''


def main(data_path):
    data_dir = Path(data_path)
    if (data_dir / "locations").exists():
        project_dir = data_dir.parent
    else:
        project_dir = data_dir
        data_dir = data_dir / "data"

    assets = scan_assets(data_dir, project_dir)
    html = generate_html(assets, data_dir)

    out = Path("/tmp/yume_assets.html")
    out.write_text(html)

    print(f"Asset Manager: {out}")
    print(f"  Characters: {len(assets['characters'])}")
    print(f"  Enemies: {len(assets['enemies'])}")
    print(f"  Props: {len(assets['props'])}")
    print(f"  Locations: {len(assets['locations'])}")

    # Serve it
    os.chdir("/tmp")
    port = 8420
    print(f"\n  Opening http://localhost:{port}/yume_assets.html")
    webbrowser.open(f"http://localhost:{port}/yume_assets.html")

    server = HTTPServer(("localhost", port), SimpleHTTPRequestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} /path/to/game/data/")
        sys.exit(1)
    main(sys.argv[1])
