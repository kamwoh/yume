"""Infinigen → Yume asset-library backend (ADR 0074, Phase B).

Generates procedural assets with Princeton's Infinigen (an external
Blender pipeline), decimates them to a real-time budget, bakes PBR maps,
and emits Yume entity defs + .glb. An OPTIONAL World/Assets-layer content
source — never required, output is plain .glb + JSON the rest of the
pipeline already consumes.

CLI:  python -m tools.yume_infinigen <game> --factory BoulderFactory --seeds 0,1,2
"""
