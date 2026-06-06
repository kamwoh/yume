"""tools.visual_layout — image-gen → extraction → JSON compose pipelines.

Two families of LLM-as-parser harnesses (prompt → image → preprocess
context → LLM authors draft → postprocess validates):

  3D world (ACTIVE)   compose_scene → compose_world (map: extract entities +
                      biome ground + water) → compose_shell (camera/player/
                      input/lighting/.tscn). Extraction dispatches via
                      lib_extract_dispatch over data/lib/extraction_strategies.json;
                      lib_extract supplies the CV helpers; a per-scene
                      data/<game>/extract.py may override extraction.
                      compare_semantic scores placement vs the semantic map.

  2D UI (STABLE)      compose_hud / compose_screen / compose_map +
                      wireframe_to_* — fit-fit authoring handed to the
                      yume-{hud,screen,map}-author skills.

See tools/visual_layout/README.md and .claude/rules/pipeline-stability.md.
"""
