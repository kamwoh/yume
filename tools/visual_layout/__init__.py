"""tools.visual_layout — image-gen → CV extraction → JSON compiler.

Per ADR 0054. Pipeline:
    intent → semantic image → k-means quantize → legend match
        → connected components → schema → validate + repair → JSON

Modules:
    extractor_common  — k-means quantize + legend match + mask helpers
    extract_ui        — UI wireframe → rect schema (Phase 1)
    extract_map       — semantic map → anchor schema (Phase 2)
    compile_ui        — rect schema → hud.json
    compile_map       — anchor schema → entities.json + patterns

See tools/visual_layout/README.md for usage.
"""
