#!/usr/bin/env python3
"""Download reference images for game design study.

Usage:
    python download_references.py /path/to/output/
"""

import sys
import urllib.request
import urllib.error
from pathlib import Path


# Reference images — direct image URLs from wikis, press kits, and public sources
REFERENCES = {
    # Valheim — low-poly survival with amazing lighting
    "valheim_base.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/892970/ss_3a52137f5336ef1903f37fca47bf07cccce912d7.jpg",
    "valheim_forest.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/892970/ss_988e21a0e6543b6baca3e84d0a7b88a97e52f67b.jpg",
    "valheim_night.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/892970/ss_5cb2fdd4f3c08f6aa11057e14e498cfde57a8e17.jpg",

    # Don't Starve — survival + crafting + day/night
    "dont_starve_world.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/219740/ss_2e9cb35c68aafce1e0fce5e88c15e8cbb25780d9.jpg",
    "dont_starve_camp.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/219740/ss_e631cb877e79c16f1bd8fd3f5c2a8c00afe0aba0.jpg",

    # Minecraft — the original block survival
    "minecraft_village.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/1672970/ss_b76a3e9c9c0467a6c408f6fb9d3b04b81ed55d9d.jpg",

    # Minetest/Luanti — open source voxel
    "luanti_world.png": "https://raw.githubusercontent.com/minetest/minetest/master/misc/minetest-icon.png",

    # Low poly nature/survival
    "lowpoly_forest.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/1295920/ss_c15e0f11e0f5c0dea76e2e43e8c2f0b51f5e6eee.jpg",

    # Colony sim — RimWorld
    "rimworld_colony.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/294100/ss_0acb0342eb1a4dac0ce0a22a75b40d9a8a9a4452.jpg",

    # Oxygen Not Included
    "oni_colony.jpg": "https://cdn.akamai.steamstatic.com/steam/apps/457140/ss_c27cba85bfb3db78e44a54dae1be73ea17fa8c97.jpg",
}


def download_images(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    }

    for filename, url in REFERENCES.items():
        output_path = output_dir / filename
        if output_path.exists():
            print(f"  Skip (exists): {filename}")
            continue

        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as response:
                data = response.read()
                output_path.write_bytes(data)
                size_kb = len(data) / 1024
                print(f"  Downloaded: {filename} ({size_kb:.0f} KB)")
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
            print(f"  Failed: {filename} — {e}")


def main():
    output_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/yume_references")
    print(f"Downloading {len(REFERENCES)} reference images → {output_dir}/\n")
    download_images(output_dir)
    print(f"\nDone. View images at: {output_dir}/")


if __name__ == "__main__":
    main()
