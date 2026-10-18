"""Generate Yume's engine API manifest from GDScript source.

Tier 2.6c — replaces hand-edited tool registries in agent prompts. Run on
demand or as a CI step; the manifest is the source of truth for what
verbs the engine supports. Adding a primitive (new effect type, new query
operator) automatically updates the manifest.

Usage:
    python tools/gen_api_manifest.py

Outputs:
    docs/engine-reference/api-manifest.json   — machine-readable, agent input
    docs/engine-reference/api-manifest.md     — human-readable companion

Design: regex over GDScript source. The patterns rely on the engine's
formatting conventions (constant arrays, match arms, const declarations).
A sanity check at the end fails loudly if expected vocabulary is missing,
so source-format drift is caught early instead of silently dropping items.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENGINE_DIR = REPO / "godot" / "scripts" / "engine"
PROJECT_GODOT = REPO / "godot" / "project.godot"
OUTPUT_DIR = REPO / "docs" / "engine-reference"
JSON_OUT = OUTPUT_DIR / "api-manifest.json"
MD_OUT = OUTPUT_DIR / "api-manifest.md"


# HUD element schema — curated, with regex sanity-check below.
# Each element's fields match what HudBuilder._build_element (or
# minimap_widget.configure) actually reads from cfg.
HUD_ELEMENTS: list[dict] = [
    {
        "type": "label",
        "fields": {
            "text": "literal string (capital-start avoids formula eval)",
            "binds": "binding path (e.g. 'world_clock.current_day')",
            "format": "template — {} substitutes the bound value",
            "size": "int — font size px (default 18)",
            "color": "hex #RRGGBB (default #ffffff)",
            "bold": "bool",
            "shadow": "bool",
            "shadow_color": "hex",
            "shadow_offset": "[x, y] px",
            "align": "begin | center | right",
        },
        "source": "hud_builder.gd _build_element 'label'",
    },
    {
        "type": "progress_bar",
        "fields": {
            "binds": "binding path (required)",
            "max": "number (default 100)",
            "width": "px or '%' (default 280)",
            "height": "px or '%' (default 16)",
            "color": "hex (fixed color)",
            "color_lerp": "[hex, hex, hex] — interpolated by value/max",
            "size_flags_h": "shrink_begin|shrink_center|shrink_end|expand|expand_fill|fill",
        },
        "source": "hud_builder.gd _build_element 'progress_bar'",
    },
    {
        "type": "spacer",
        "fields": {"height": "px (default 8)"},
        "source": "hud_builder.gd _build_element 'spacer'",
    },
    {
        "type": "crosshair",
        "fields": {
            "glyph": "string (default '+')",
            "size": "int (default 28)",
            "color": "hex (default #ffffff)",
        },
        "source": "hud_builder.gd _build_element 'crosshair'",
    },
    {
        "type": "minimap",
        "fields": {
            "size": "[w, h] px",
            "world_bounds": "[x_min, z_min, x_max, z_max]",
            "background": "hex",
            "border": "hex",
            "tag_colors": "dict { tag: hex } — first match wins",
            "player_tag": "string (which tag = the player dot, default 'player')",
            "dot_radius": "px (default 1.5)",
            "player_radius": "px (default 4.0)",
            "show_view_cone": "bool",
            "view_cone_radius": "world units",
            "view_cone_half_angle": "radians",
            "view_cone_color": "hex",
            "view_cone_alpha": "0..1",
        },
        "source": "minimap_widget.gd configure()",
    },
    {
        "type": "slot_grid",
        "fields": {
            "cell_count": "int (required)",
            "columns": "int (required)",
            "binds": "array binding path (e.g. 'player.inventory')",
            "active_binds": "int binding path (highlights cell i where i==value)",
            "cell_size": "[w, h] px (default [56, 48])",
            "gap": "px (default 4)",
            "show_index": "bool (default true)",
            "cell_content_type": "label | item_icon",
            "bg_color": "hex",
            "bg_active_color": "hex",
            "border_color": "hex",
            "border_active_color": "hex",
            "border_width": "px (default 2)",
            "index_color": "hex",
            "default_icon_color": "hex (item_icon fallback)",
        },
        "source": "control_factory.gd _build_slot_grid",
    },
    {
        "type": "list",
        "fields": "see LIST_ELEMENT_FIELDS below — same primitive, used in both",
        "source": "control_factory.gd _build_list (ADR 0076)",
    },
]

# ADR 0076 — query-bound repeated UI. Shared by hud.json and screens.json.
LIST_ELEMENT_FIELDS = {
    "from": "Query spec (REQUIRED) — any clause Query.run accepts: tags_all/tags_any/tags_none/id/ids/properties/state/relations/radius/order_by/limit",
    "item": "element dict (REQUIRED) — instantiated once per match; recurses through the normal element builders",
    "bind": "binding name used inside `item` (default 'row')",
    "edge_of": "{relation, to} or {relation, from} — exposes `<bind>_edge.<field>` from the relation edge's state (ADR 0075)",
    "limit": "int, positive (default 50). Truncation emits a push_warning — never silent.",
    "empty": "element dict rendered when the query matches nothing",
    "separation": "px between rows (default 4)",
    "_substitution": "`<bind>` and `<bind>.id` → the entity's instance id; `<bind>.properties.X` → literal (properties are static); `<bind>.state.X` under a `binds` key → '<instance_id>.X' (stays live); `<bind>.state.X` elsewhere → literal snapshot",
    "_cadence": "query runs at build time AND on every World.world_loaded (boot + each level transition). NOT per frame.",
}


HUD_ANCHORS: list[str] = [
    "top-left", "top-center", "top-right",
    "center-left", "center", "center-right",
    "bottom-left", "bottom-center", "bottom-right",
]


HUD_PANEL_FIELDS: dict = {
    "anchor": "anchor name (from hud_anchors)",
    "width": "px or '%' (panel width)",
    "height": "px or '%' (panel height)",
    "x_offset": "px or '%' offset from anchor",
    "y_offset": "px or '%' offset from anchor",
    "align": "begin | center | end (inner vbox alignment)",
    "elements": "list of element dicts",
}


# Screen element catalog (ControlFactory's vocabulary).
# Screens (modal/full-cover) consume the broader control set including
# interactive elements (button, slider, checkbox, option_button). HUD
# (always-on overlay) uses a narrower set — see HUD_ELEMENTS above.
# Source: control_factory.gd::build dispatch.
SCREEN_ELEMENTS: list[dict] = [
    {
        "type": "label",
        "fields": {
            "text": "literal string (capital-start avoids formula eval)",
            "binds": "binding path (e.g. 'player.hunger')",
            "format": "template — {} substitutes the bound value",
            "font_size": "int px",
            "color": "hex #RRGGBB",
            "halign": "left | center | right",
            "anchor": "anchor name (see screen_anchors)",
            "x_offset": "px",
            "y_offset": "px",
            "width": "px or '%'",
            "height": "px or '%'",
        },
        "source": "control_factory.gd _build_label",
    },
    {
        "type": "button",
        "fields": {
            "text": "button label",
            "font_size": "int px",
            "id": "Control.name for testing (#39)",
            "anchor": "anchor name",
            "x_offset": "px",
            "y_offset": "px",
            "width": "px or '%'",
            "height": "px or '%'",
            "on_click": "effect chain — list of effect dicts to fire on press",
            "color": "hex #RRGGBB — font colour for all states (skinned buttons on light frames need this; engine-default text is pale)",
            "texture": "asset path (ADR 0087) — StyleBoxTexture skin for the normal state, and the fallback for the others",
            "texture_hover": "asset path (defaults to `texture`)",
            "texture_pressed": "asset path (defaults to `texture`)",
            "texture_focus": "asset path (defaults to `texture`)",
            "texture_disabled": "asset path (defaults to `texture`)",
            "texture_margin": "px nine-slice inset — keeps a frame's corner ornament unstretched at any button size. Author sprites with ornament in the CORNERS ONLY and straight edges, and one frame serves every size.",
            "content_margin": "px text padding (default 4). MUST be set separately: with it unset Godot derives the content box from texture_margin, so a 34px slice inset also becomes 34px of text padding and shoves the label out of a small button.",
            "visible_if": "formula — set node.visible each frame",
            "enabled_if": "formula — set node.disabled each frame",
        },
        "source": "control_factory.gd _build_button",
    },
    {
        "type": "vbox",
        "fields": {
            "separation": "px between children (default 4)",
            "children": "list of element dicts (recurses)",
            "anchor": "anchor name",
            "x_offset": "px",
            "y_offset": "px",
            "width": "px or '%'",
            "height": "px or '%'",
            "size_flags_h": "shrink_begin|shrink_center|shrink_end|expand|expand_fill|fill",
            "size_flags_v": "shrink_begin|shrink_center|shrink_end|expand|expand_fill|fill",
        },
        "source": "control_factory.gd _build_vbox",
    },
    {
        "type": "hbox",
        "fields": {
            "separation": "px between children",
            "children": "list of element dicts (recurses)",
            "anchor": "anchor name",
            "x_offset": "px",
            "y_offset": "px",
            "width": "px or '%'",
            "height": "px or '%'",
        },
        "source": "control_factory.gd _build_hbox",
    },
    {
        "type": "color_rect",
        "fields": {
            "color": "hex (default #000000)",
            "alpha": "0..1",
            "anchor": "anchor name (often 'fill' for full-cover background)",
            "x_offset": "px",
            "y_offset": "px",
            "width": "px or '%'",
            "height": "px or '%'",
        },
        "source": "control_factory.gd _build_color_rect",
    },
    {
        "type": "spacer",
        "fields": {
            "width": "px (default 0)",
            "height": "px (default 8)",
        },
        "source": "control_factory.gd _build_spacer",
    },
    {
        "type": "image",
        "fields": {
            "texture": "asset path, relative to the game folder or @lib/ (ADR 0087)",
            "anchor": "anchor name",
            "x_offset": "px",
            "y_offset": "px",
            "width": "px or '%'",
            "height": "px or '%'",
        },
        "source": "control_factory.gd _build_image",
    },
    {
        "type": "slider",
        "fields": {
            "min": "float (default 0.0)",
            "max": "float (default 1.0)",
            "step": "float (default 0.05)",
            "value": "float (current)",
            "default": "float (initial if no value)",
            "width": "px (default 200)",
            "height": "px (default 20)",
            "on_change": "effect chain — receives {value: new}",
        },
        "source": "control_factory.gd _build_slider",
    },
    {
        "type": "checkbox",
        "fields": {
            "text": "label next to checkbox",
            "value": "bool (current)",
            "default": "bool (initial)",
            "on_change": "effect chain — receives {value: new}",
        },
        "source": "control_factory.gd _build_checkbox",
    },
    {
        "type": "option_button",
        "fields": {
            "options": "list of strings",
            "value": "current selected string",
            "default": "initial selected string",
            "on_change": "effect chain — receives {value: new}",
        },
        "source": "control_factory.gd _build_option_button",
    },
    {
        "type": "slot_grid",
        "fields": "see hud_elements[slot_grid] — same primitive, used in both",
        "source": "control_factory.gd _build_slot_grid",
    },
    {
        "type": "list",
        "fields": LIST_ELEMENT_FIELDS,
        "source": "control_factory.gd _build_list (ADR 0076)",
    },
    {
        "type": "minimap",
        "fields": "see hud_elements[minimap] — same primitive, used in both",
        "source": "minimap_widget.gd configure()",
    },
    {
        "type": "settings_renderer",
        "fields": {
            "_note": "Special: filled in by SettingsManager-aware screens (e.g. settings menu). ControlFactory creates a placeholder VBox; settings layer adds child elements from settings_schema.json.",
        },
        "source": "control_factory.gd 'settings_renderer'",
    },
]


# Screen-level fields (the dict that wraps `elements`).
SCREEN_FIELDS: dict = {
    "id": "unique string — referenced by transition_screen targets",
    "modal": "bool — when true, previous screen stays visible underneath",
    "freeze_world": "bool — when true, world simulation pauses while shown",
    "background_color": "hex — full-cover background (default #000000)",
    "background_alpha": "0..1 — for modal screens, dim the world (default 1.0)",
    "elements": "list of element dicts",
}


# Screens.json TOP-LEVEL fields (the document root).
SCREEN_DOC_FIELDS: dict = {
    "starting_screen": "id of the screen pushed on first load",
    "screens": "list of screen dicts",
    "global_inputs": "list of {action, if_screen, on_press} — global input → effect chain bindings",
}


# Interaction events per element type. Authors should know which events
# they can wire on each element. Each event fires an effect chain.
INTERACTION_EVENTS: dict = {
    "button": ["on_click"],
    "slider": ["on_change"],
    "checkbox": ["on_change"],
    "option_button": ["on_change"],
    "global_input": ["on_press"],
}


# ============================================================
# Map authoring vocabulary (Tier 2.7v, 2026-05-20).
# Not engine primitives — these are content-authoring concepts the
# wireframe-to-map harness emits. The engine sees the OUTPUT
# (initial_instances + patterns) as ordinary entity placements; the
# anchor/zone/path distinction is purely for the LLM author.
# ============================================================


MAP_AUTHORING_CONCEPTS: dict = {
    "anchor": {
        "definition": (
            "A single distinct point of interest — fire pit, hut, "
            "well, market stall, bridge. Emitted as ONE entry in "
            "the level's initial_instances array."
        ),
        "wireframe_cue": (
            "Small to medium solid-color region (~3-8% of canvas) "
            "at a specific location. Often centered on a path or "
            "near other anchors. The shape is distinct (square, "
            "circle, rectangle) and the color is unique per anchor "
            "type per the per-game legend."
        ),
        "json_shape": {
            "def": "<def_id from game's entities/>",
            "id": "<unique instance id, e.g. fire_pit_00>",
            "position": [
                "<x in world units>",
                "<y, usually 0 for floor-anchored>",
                "<z in world units>",
            ],
            "state": "<optional state overrides>",
        },
        "output_array": "initial_instances",
    },
    "zone": {
        "definition": (
            "A region populated by SCATTER of similar entities — "
            "forest of trees, rock field, mushroom patch. Emitted "
            "as ONE entry in the level's patterns array with a "
            "density count derived from area + scatter_preset."
        ),
        "wireframe_cue": (
            "Large solid-color region (>10% of canvas) covering "
            "an irregular or rectangular area. The color matches "
            "the per-game legend's zone-type color (forest, grass, "
            "water, rocks_field, etc.)."
        ),
        "json_shape": {
            "pattern": "scatter",
            "def": "<def_id of the scattered entity>",
            "id_prefix": "<id prefix for scattered instances>",
            "count": "<int — total entities to scatter>",
            "min_r": "<float — REQUIRED for count > 10. Inner annulus radius in world units around origin. Engine default 0 only fits ~30 entities in min_spacing-packed disk.>",
            "max_r": "<float — REQUIRED for count > 10. Outer annulus radius. Engine default 5; pick from wireframe geometry.>",
            "min_spacing": "<float — minimum spacing in world units>",
            "scale_min": "<float — per-instance random scale lower bound>",
            "scale_max": "<float — upper bound>",
            "yaw_jitter": "<float radians — random rotation range>",
            "origin": ["<x>", "<y>", "<z>"],
        },
        "output_array": "patterns",
    },
    "path": {
        "definition": (
            "A sequence of waypoints connecting anchors. Currently "
            "EMITTED AS METADATA ONLY (engine does not consume "
            "paths directly; level designers can use them as a "
            "design reference for foot-traffic intent). Deferred "
            "to a future primitive."
        ),
        "wireframe_cue": (
            "Thin elongated solid-color band connecting two or "
            "more anchors. Often tan/brown for foot paths."
        ),
        "json_shape": {
            "_path": True,
            "from_anchor": "<source anchor id>",
            "to_anchor": "<dest anchor id>",
            "_note": "Deferred; engine does not consume paths yet.",
        },
        "output_array": "_paths_meta (informational only)",
    },
}


# Per-anchor world-position math. The semantic map is a 1:1 top-down
# image; world bounds come from scene.json's ground.mesh.size OR a
# per-game level_bounds declaration. Standard scaling assumes the
# map's center maps to world (0, 0, 0).
MAP_COORD_TRANSFORM: dict = {
    "_doc": (
        "How to convert a wireframe pixel (px_x, px_y) to a world "
        "position (wx, wz). The map's center is world origin; +X "
        "is east (image right); +Z is south (image down). Y stays "
        "at 0 for floor-anchored entities."
    ),
    "formula": {
        "wx": "(px_x - image.width/2) / image.width * world_bounds.width",
        "wz": "(px_y - image.height/2) / image.height * world_bounds.depth",
        "wy": "0.0",
    },
    "example": (
        "image 1024x1024, world_bounds.width=160 (80m radius). "
        "Center pixel (512, 512) → world (0, 0, 0). Pixel (640, "
        "256) → world ((640-512)/1024 * 160, 0, (256-512)/1024 "
        "* 160) = (20, 0, -40) [20m east, 40m north]."
    ),
}


# Screen anchors — same set as HUD but canonical screens form uses
# underscores (top_left). Both forms accepted at runtime via
# control_factory.gd::_apply_anchor's replace("-", "_").
SCREEN_ANCHORS: list[str] = [
    "top_left", "top_center", "top_right",
    "center_left", "center", "center_right",
    "bottom_left", "bottom_center", "bottom_right",
    "fill",  # full parent rect — modal background
]


# Anchor-relative geometry math — for fit-fit harness to compute
# x_offset / y_offset from a bbox in viewport pixels. wf = wireframe,
# vp = viewport. bbox in wireframe pixels, scaled to viewport first.
HUD_ANCHOR_GEOMETRY: dict = {
    "top-left":      {"x_offset": "bbox.x",                "y_offset": "bbox.y"},
    "top-center":    {"x_offset": "bbox.cx - vp.w/2",      "y_offset": "bbox.y"},
    "top-right":     {"x_offset": "-(vp.w - bbox.x2)",     "y_offset": "bbox.y"},
    "center-left":   {"x_offset": "bbox.x",                "y_offset": "bbox.cy - vp.h/2"},
    "center":        {"x_offset": "bbox.cx - vp.w/2",      "y_offset": "bbox.cy - vp.h/2"},
    "center-right":  {"x_offset": "-(vp.w - bbox.x2)",     "y_offset": "bbox.cy - vp.h/2"},
    "bottom-left":   {"x_offset": "bbox.x",                "y_offset": "-(vp.h - bbox.y2)"},
    "bottom-center": {"x_offset": "bbox.cx - vp.w/2",      "y_offset": "-(vp.h - bbox.y2)"},
    "bottom-right":  {"x_offset": "-(vp.w - bbox.x2)",     "y_offset": "-(vp.h - bbox.y2)"},
}


@dataclass
class Manifest:
    version: str = "1"
    generated_at: str = ""
    generated_from: str = ""
    primitives: list[str] = field(default_factory=list)
    deferred_primitives: list[str] = field(default_factory=list)
    triggers: list[str] = field(default_factory=list)
    effects: list[dict] = field(default_factory=list)
    query_clauses: list[str] = field(default_factory=list)
    query_operator_suffixes: list[str] = field(default_factory=list)
    formula_entity_roles: list[str] = field(default_factory=list)
    formula_math_helpers: list[str] = field(default_factory=list)
    error_codes: list[dict] = field(default_factory=list)
    # ADR 0089: the named shaders and their parameters, read from
    # util/shader_lib.gd and the library .gdshader files.
    shaders: list[dict] = field(default_factory=list)
    # ADR 0090: key names, audio channels, lighting fields and physics
    # names, read from the engine files that own them (via content.py).
    vocabularies: dict = field(default_factory=dict)
    reserved_state_fields: list[str] = field(default_factory=list)
    invariants_count: int = 8
    # HUD authoring catalog (Tier 2.7v, 2026-05-19) — for the
    # wireframe-to-hud harness. ui_elements + ui_anchors + panel
    # fields + viewport so future skills/scripts read JSON instead
    # of parsing GDScript.
    hud_elements: list[dict] = field(default_factory=list)
    hud_anchors: list[str] = field(default_factory=list)
    hud_panel_fields: dict = field(default_factory=dict)
    hud_anchor_geometry: dict = field(default_factory=dict)
    viewport: dict = field(default_factory=dict)
    # Screen (modal/full-cover UI) catalog — Tier 2.7v (2026-05-20).
    # ControlFactory's full vocabulary, used by screens.json. Same anchor
    # geometry math as HUD; broader element catalog (adds button + form
    # controls + interaction event names).
    screen_elements: list[dict] = field(default_factory=list)
    screen_anchors: list[str] = field(default_factory=list)
    screen_fields: dict = field(default_factory=dict)
    screen_doc_fields: dict = field(default_factory=dict)
    interaction_events: dict = field(default_factory=dict)
    # Map authoring vocabulary — Tier 2.7v (2026-05-20). Procedural
    # level generation via wireframe → semantic map → LLM author.
    # Not engine primitives; the engine sees the OUTPUT (instances +
    # patterns) as ordinary entity placements.
    map_authoring_concepts: dict = field(default_factory=dict)
    map_coord_transform: dict = field(default_factory=dict)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_string_array(text: str, const_name: str) -> list[str]:
    """Extract entries from `const NAME: Array = [ "a", "b", ... ]`."""
    pattern = rf"const\s+{re.escape(const_name)}\s*:\s*Array\s*=\s*\[(.*?)\]"
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        return []
    return re.findall(r'"([^"]+)"', m.group(1))


def parse_effects(text: str) -> list[dict]:
    """Find the `match type:` block in effect_apply.gd and extract arm names."""
    block = re.search(r"match\s+type:\s*\n((?:\t+.*\n)+)", text)
    if not block:
        return []
    arms = re.findall(r'^\t+"([a-z_]+)"\s*:', block.group(1), re.MULTILINE)
    return [{"type": name, "source": "effect_apply.gd"} for name in arms]


# ------------------------------------------------------------
# Effect field schema (batch G, 2026-10-16)
# ------------------------------------------------------------
# For each dispatcher arm, follow its handler (and every engine helper the
# effect dict is passed to) and collect the keys it reads: `e.get("k")`,
# `e["k"]` and `e.has("k")`. A handler that passes the dict to code outside
# a class_name script, or iterates its keys, has an OPEN field set: any key
# can matter, so no validator may call a key unknown.
#
# Field names used to live as hand lists in validators. A wrong name (for
# example `formula_x` for `x`, or `state` for `overrides.state`) was a
# silent no-op that no list covered.


def _class_files() -> dict[str, Path]:
    out = {}
    for p in ENGINE_DIR.rglob("*.gd"):
        if "/tests/" in p.as_posix():
            continue
        m = re.search(r"^class_name (\w+)", read(p), re.M)
        if m:
            out[m.group(1)] = p
    return out


def _func_body(path: Path, name: str):
    m = re.search(
        r"^static func " + re.escape(name) + r"\(([^)]*)\)[^\n]*:\n((?:(?:\t.*|\s*)\n)+)",
        read(path), re.M,
    )
    if not m:
        return None, None
    return [x.split(":")[0].strip() for x in m.group(1).split(",")], m.group(2)


def _walk_fields(classes, cls, fn, argpos, seen, depth=0):
    """Return (fields, open) for the dict passed at `argpos` of cls.fn."""
    if (cls, fn, argpos) in seen or depth > 4 or cls not in classes:
        return set(), False
    seen.add((cls, fn, argpos))
    params, body = _func_body(classes[cls], fn)
    if not body or argpos >= len(params):
        return set(), False
    p = params[argpos]
    fields = set(re.findall(rf'\b{p}\.get\("(\w+)"', body))
    fields |= set(re.findall(rf'\b{p}\["(\w+)"\]', body))
    fields |= set(re.findall(rf'\b{p}\.has\("(\w+)"', body))
    is_open = bool(re.search(rf"for \w+ in {p}(\.keys\(\))?\s*:|=\s*{p}\s*$", body, re.M))
    for m in re.finditer(rf"([\w\.]+)\(([^()]*\b{p}\b[^()]*)\)", body):
        args = [a.strip() for a in m.group(2).split(",")]
        if p not in args:
            continue
        parts = m.group(1).split(".")
        c2, f2 = (parts[-2], parts[-1]) if len(parts) >= 2 else (cls, parts[-1])
        if c2 in classes and _func_body(classes[c2], f2)[1] is not None:
            sub, sub_open = _walk_fields(classes, c2, f2, args.index(p), seen, depth + 1)
            fields |= sub
            is_open |= sub_open
        elif not m.group(1).endswith(("get", "has")):
            is_open = True
    return fields, is_open


def parse_effect_fields(effect_src: str) -> dict[str, dict]:
    """{effect_type: {"fields": [...], "open": bool}} from the dispatcher."""
    classes = _class_files()
    block = re.search(r"match\s+type:\s*\n((?:\t+.*\n)+)", effect_src)
    out = {}
    if not block:
        return out
    for name, cls, fn in re.findall(
        r'^\t\t"([a-z_]+)":\s*\n\t\t\t(?:return )?(\w+)\.(\w+)\(effect', block.group(1), re.M
    ):
        fields, is_open = _walk_fields(classes, cls, fn, 0, set())
        fields.discard("type")
        out[name] = {"fields": sorted(fields), "open": is_open}
    return out


def parse_query_clauses(text: str) -> list[str]:
    """Find `spec.has("clause")` calls in query.gd's matches() / run()."""
    clauses = re.findall(r'spec\.has\("([a-z_]+)"\)', text)
    seen: dict[str, None] = {}
    for c in clauses:
        seen[c] = None
    return list(seen.keys())


def parse_error_codes(text: str) -> list[dict]:
    """Pull `const NAME := "code.value"` declarations from engine_error.gd."""
    out: list[dict] = []
    for m in re.finditer(r'^const\s+([A-Z_]+)\s*:?=\s*"([a-z_.]+)"', text, re.MULTILINE):
        out.append({"constant": m.group(1), "code": m.group(2)})
    return out


_UNIFORM_RE = re.compile(
    r"^\s*uniform\s+(\w+)\s+(\w+)(\[\w+\])?\s*(?::\s*([^=;]*))?(?:=\s*([^;]*))?;\s*(?://\s*(.*))?$"
)
_SPEC_TYPES = {"float": "number", "int": "integer", "bool": "bool", "vec2": "[x, y]",
               "vec3": "[x, y, z]", "vec4": "[x, y, z, w]", "sampler2D": "texture (asset path)"}


def parse_shaders() -> list[dict]:
    """The named shaders of ADR 0089 with the parameters content may set."""
    lib_src = read(ENGINE_DIR / "util" / "shader_lib.gd")
    hidden = set(parse_string_array(lib_src, "INTERPRETER_PARAMS"))
    out = []
    for name in parse_string_array(lib_src, "NAMES"):
        src = read(REPO / "godot" / "data" / "lib" / "shaders" / f"{name}.gdshader")
        kind = re.search(r"^shader_type\s+(\w+);", src, re.MULTILINE).group(1)
        params = []
        for line in src.splitlines():
            m = _UNIFORM_RE.match(line)
            if not m or m.group(2) in hidden:
                continue
            gtype, pname, arr, hints, default, note = m.groups()
            hints = hints or ""
            spec = "color" if "source_color" in hints and gtype.startswith("vec") else _SPEC_TYPES.get(gtype, gtype)
            rng = re.search(r"hint_range\(([^)]*)\)", hints)
            params.append({
                "name": pname,
                "type": f"list of {spec}" if arr else spec,
                "default": re.sub(r"^vec\d\((.*)\)$", r"[\1]", (default or "").strip()),
                "range": rng.group(1).replace(" ", "") if rng else "",
                "note": (note or "").strip(),
            })
        out.append({"name": name, "kind": kind, "params": params})
    return out


def parse_vocabularies() -> dict:
    """The ADR 0090 vocabularies. tools/validators/content.py reads them
    from the engine files, so the validator and this manifest agree."""
    sys.path.insert(0, str(REPO / "tools" / "validators"))
    import content  # noqa: E402
    return {
        "keys": list(content.KEY_NAMES),
        "mouse_buttons": list(content.MOUSE_BUTTONS),
        "audio_channels": list(content.AUDIO_CHANNELS),
        "lighting_fields": content.SCENE_FIELDS,
        "lighting_host_hints": list(content.SCENE_HOST_HINTS),
        "body_types": list(content.BODY_TYPES),
        "physics_fields": list(content.PHYSICS_FIELDS),
        "collision_layers": list(content.LAYER_NAMES),
    }


def parse_formula_roles(text: str) -> list[str]:
    """Doc-listed entity roles in formula.gd."""
    block = re.search(r"## Bindings supported.*?##\s*\n", text, re.DOTALL)
    if not block:
        return ["self", "target", "a", "b", "source", "world"]
    found = re.findall(r"\b(self|target|a|b|source|from|to|world)\.", block.group(0))
    seen: dict[str, None] = {}
    for f in found:
        seen[f] = None
    return list(seen.keys())


def parse_hud_element_types(text: str) -> list[str]:
    """Extract element type strings from hud_builder.gd's _build_element
    match arms. Used as a sanity check against HUD_ELEMENTS schema."""
    m = re.search(r"func _build_element\(.*?\n(.*?)(?=\nfunc |\Z)", text, re.DOTALL)
    if not m:
        return []
    body = m.group(1)
    mb = re.search(r"match\s+t\s*:\s*\n(.*)", body, re.DOTALL)
    if not mb:
        return []
    return re.findall(r'^\t+"([a-z_]+)"\s*:', mb.group(1), re.MULTILINE)


def parse_control_factory_types(text: str) -> list[str]:
    """Extract element type strings from control_factory.gd's top-level
    `match t:` dispatch in `build()`. Sanity check against SCREEN_ELEMENTS."""
    m = re.search(r"static func build\(.*?\n(.*?)(?=\nstatic func |\Z)", text, re.DOTALL)
    if not m:
        return []
    body = m.group(1)
    mb = re.search(r"match\s+t\s*:\s*\n(.*)", body, re.DOTALL)
    if not mb:
        return []
    return re.findall(r'^\t+"([a-z_]+)"\s*:', mb.group(1), re.MULTILINE)


def parse_viewport_settings() -> dict:
    """Read project.godot for the canonical viewport size + stretch mode."""
    if not PROJECT_GODOT.exists():
        return {}
    text = PROJECT_GODOT.read_text(encoding="utf-8")
    out: dict = {"source": str(PROJECT_GODOT.relative_to(REPO))}
    m = re.search(r"window/size/viewport_width\s*=\s*(\d+)", text)
    if m:
        out["width"] = int(m.group(1))
    m = re.search(r"window/size/viewport_height\s*=\s*(\d+)", text)
    if m:
        out["height"] = int(m.group(1))
    m = re.search(r'window/stretch/mode\s*=\s*"([^"]+)"', text)
    out["stretch_mode"] = m.group(1) if m else "disabled"
    m = re.search(r'window/stretch/aspect\s*=\s*"([^"]+)"', text)
    out["stretch_aspect"] = m.group(1) if m else "ignore"
    if "width" in out and "height" in out and out["height"]:
        from math import gcd as _gcd
        w, h = out["width"], out["height"]
        g = _gcd(w, h)
        out["aspect_ratio"] = f"{w // g}:{h // g}"
    return out


def build_manifest() -> Manifest:
    rule_src = read(ENGINE_DIR / "core" / "rule.gd")
    effect_src = read(ENGINE_DIR / "core" / "effect_apply.gd")
    query_src = read(ENGINE_DIR / "core" / "query.gd")
    formula_src = read(ENGINE_DIR / "core" / "formula.gd")
    err_src = read(ENGINE_DIR / "core" / "engine_error.gd")

    m = Manifest(
        generated_at=datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
        generated_from=str(ENGINE_DIR.relative_to(REPO)),
        primitives=["Entity", "Tag", "Rule", "Trigger", "Effect", "Query", "Relation"],
        deferred_primitives=["Plan", "Knowledge"],
        triggers=parse_string_array(rule_src, "VALID_TRIGGERS"),
        effects=[
            {**e, **parse_effect_fields(effect_src).get(e["type"], {"fields": [], "open": True})}
            for e in parse_effects(effect_src)
        ],
        query_clauses=parse_query_clauses(query_src),
        query_operator_suffixes=parse_string_array(query_src, "OPERATOR_SUFFIXES"),
        formula_entity_roles=parse_formula_roles(formula_src),
        formula_math_helpers=parse_string_array(formula_src, "FUNCTIONS"),
        shaders=parse_shaders(),
        vocabularies=parse_vocabularies(),
        error_codes=parse_error_codes(err_src),
        reserved_state_fields=["position", "velocity", "age"],
        hud_elements=HUD_ELEMENTS,
        hud_anchors=HUD_ANCHORS,
        hud_panel_fields=HUD_PANEL_FIELDS,
        hud_anchor_geometry=HUD_ANCHOR_GEOMETRY,
        viewport=parse_viewport_settings(),
        screen_elements=SCREEN_ELEMENTS,
        screen_anchors=SCREEN_ANCHORS,
        screen_fields=SCREEN_FIELDS,
        screen_doc_fields=SCREEN_DOC_FIELDS,
        interaction_events=INTERACTION_EVENTS,
        map_authoring_concepts=MAP_AUTHORING_CONCEPTS,
        map_coord_transform=MAP_COORD_TRANSFORM,
    )
    return m


def sanity_check(m: Manifest) -> list[str]:
    """Fail loudly if regex parsing dropped expected vocabulary. Catches
    source-format drift before agents read a half-empty manifest."""
    problems: list[str] = []
    expected_triggers = {"tick", "contact", "signal", "input", "spawn", "despawn"}
    if not expected_triggers.issubset(set(m.triggers)):
        problems.append(f"triggers missing expected items; got {m.triggers}")
    expected_effects = {"state_set", "spawn", "remove", "transform", "relate", "tag_add", "emit"}
    got_effects = {e["type"] for e in m.effects}
    if not expected_effects.issubset(got_effects):
        problems.append(f"effects missing expected items; got {sorted(got_effects)}")
    expected_clauses = {"tags_all", "properties", "state"}
    if not expected_clauses.issubset(set(m.query_clauses)):
        problems.append(f"query_clauses missing expected items; got {m.query_clauses}")
    if len(m.error_codes) < 20:
        problems.append(f"error_codes count too low: {len(m.error_codes)} (expected 20+)")
    if "_eq" not in m.query_operator_suffixes:
        problems.append("query_operator_suffixes missing _eq")
    # HUD elements: regex against hud_builder.gd must match our schema, so
    # adding/renaming an element type in GDScript without updating
    # HUD_ELEMENTS surfaces immediately.
    hud_builder = ENGINE_DIR / "ui" / "widgets" / "hud_builder.gd"
    if hud_builder.exists():
        live_types = set(parse_hud_element_types(read(hud_builder)))
        schema_types = {e["type"] for e in m.hud_elements}
        missing = live_types - schema_types
        extra = schema_types - live_types
        if missing:
            problems.append(
                f"HUD_ELEMENTS schema missing types present in hud_builder.gd: "
                f"{sorted(missing)} — add to HUD_ELEMENTS in gen_api_manifest.py"
            )
        if extra:
            problems.append(
                f"HUD_ELEMENTS schema lists types absent from hud_builder.gd: "
                f"{sorted(extra)} — likely renamed/removed in GDScript"
            )
    # Screen elements: same sanity check, against control_factory.gd. If
    # someone adds a new element type to ControlFactory without updating
    # SCREEN_ELEMENTS, fail loudly.
    cf = ENGINE_DIR / "ui" / "control_factory.gd"
    if cf.exists():
        live_types = set(parse_control_factory_types(read(cf)))
        schema_types = {e["type"] for e in m.screen_elements}
        missing = live_types - schema_types
        extra = schema_types - live_types
        if missing:
            problems.append(
                f"SCREEN_ELEMENTS schema missing types present in control_factory.gd: "
                f"{sorted(missing)} — add to SCREEN_ELEMENTS in gen_api_manifest.py"
            )
        if extra:
            problems.append(
                f"SCREEN_ELEMENTS schema lists types absent from control_factory.gd: "
                f"{sorted(extra)} — likely renamed/removed in GDScript"
            )
    # Viewport must have width/height (defines fit-fit scale factor).
    if not m.viewport or "width" not in m.viewport:
        problems.append("viewport block missing — check parse_viewport_settings against project.godot")
    return problems


def render_markdown(m: Manifest) -> str:
    lines: list[str] = [
        "# Yume Engine API Manifest",
        "",
        "**Auto-generated** by `tools/gen_api_manifest.py` — do not hand-edit.",
        f"_Generated: {m.generated_at}_",
        f"_Source: `{m.generated_from}`_",
        "",
        "This manifest is the canonical list of what verbs the engine supports.",
        "Agents (`yume-content-designer`, `yume-systems-designer`, `yume-tech-director`)",
        "should reference this file instead of hand-edited markdown.",
        "",
        "## Primitives (7)",
        "",
        ", ".join(f"`{p}`" for p in m.primitives),
        "",
        f"**Deferred** (Tier 3): {', '.join(f'`{p}`' for p in m.deferred_primitives)}",
        "",
        "## Triggers",
        "",
        "Valid `rule.trigger.type` strings:",
        "",
        ", ".join(f"`{t}`" for t in m.triggers),
        "",
        "## Effect types",
        "",
        f"{len(m.effects)} effect types (used as `rule.effect[].type`):",
        "",
    ]
    for e in m.effects:
        fields = ", ".join(f"`{f}`" for f in e.get("fields", [])) or "none"
        more = " (open: passes the dict on, so other keys can matter)" if e.get("open") else ""
        lines.append(f"- `{e['type']}` — fields: {fields}{more}")
    lines += [
        "",
        "## Query clauses",
        "",
        "Top-level keys allowed in a `query` spec:",
        "",
        ", ".join(f"`{c}`" for c in m.query_clauses),
        "",
        "### Operator suffixes",
        "",
        "Used in `state` / `properties` filters (e.g. `\"hp_lt\": 50`):",
        "",
        ", ".join(f"`{s}`" for s in m.query_operator_suffixes),
        "",
        "## Formula bindings",
        "",
        "**Entity roles** (use as `<role>.state.<field>`):",
        "",
        ", ".join(f"`{r}`" for r in m.formula_entity_roles),
        "",
        "**Functions** (ADR 0088, `Formula.FUNCTIONS`). A call to any other name fails with `formula.unknown_function`:",
        "",
        ", ".join(f"`{h}`" for h in m.formula_math_helpers),
        "",
        "**Formula language** (ADR 0088):",
        "",
        "- Every number is a float. `5 / 2` gives `2.5`.",
        "- Allowed: numbers, bindings, `+ - * /`, `== != < <= > >=`, `and or not`, `true false`, parentheses, and an index such as `self.state.position[0]`.",
        "- Not allowed: `%`, `**`, strings, method calls, constructors, array literals, `&& || !`, bitwise operators.",
        "- No ternary. Write `b + (a - b) * float(cond)`. `float(b)` gives 1.0 or 0.0.",
        "- Vector component access `v.x`, `v.y`, `v.z` works through the binding path.",
        "",
        "## Shaders (ADR 0089)",
        "",
        "Content names a library shader by name (`\"shader\": \"sky_clouds\"`) and sets its parameters in `shader_params`. A custom shader is a `shader_dag` graph (ADR 0058). The exact look is host-defined. The interpreter sets `plane_size`, `screen_tex` and `depth_tex` itself.",
        "",
        *[line for sh in m.shaders for line in (
            f"### `{sh['name']}` ({sh['kind']})",
            "",
            "| Parameter | Type | Default | Range | Note |",
            "|---|---|---|---|---|",
            *[f"| `{p['name']}` | {p['type']} | {p['default'] or '—'} | {p['range'] or '—'} | {p['note'] or ''} |" for p in sh["params"]],
            "",
        )],
        "## Spec vocabularies (ADR 0090)",
        "",
        "Each list is closed. `validate_host_neutral.py` rejects other names, and the engine reports an error code. The contract document defines each name.",
        "",
        "### Input keys",
        "",
        "A key name means a key position on a US keyboard. Use it in `ui/input.json` (`key`, `keys`) and in `set_input_mapping`:",
        "",
        ", ".join(f"`{k}`" for k in m.vocabularies["keys"]),
        "",
        "Mouse buttons (`mouse_button`, `mouse_buttons`): " + ", ".join(f"`{k}`" for k in m.vocabularies["mouse_buttons"]),
        "",
        "### Audio channels",
        "",
        "`set_audio_bus_volume` `bus`: " + ", ".join(f"`{k}`" for k in m.vocabularies["audio_channels"]) + ". Music plays on `music`, sound cues on `sfx`. Both feed `master`.",
        "",
        "### Lighting fields",
        "",
        "The fields of `scene.json` `lighting` and `render`. A key that starts with `_` is a comment. Host hints tune one host's renderer, and an interpreter may ignore them.",
        "",
        "| Block | Fields |",
        "|---|---|",
        *[f"| `{path}`{' (host hint)' if path in m.vocabularies['lighting_host_hints'] else ''} | "
          + ", ".join(f"`{f}`" for f in fields) + " |" for path, fields in m.vocabularies["lighting_fields"].items()],
        "",
        "### Physics",
        "",
        "Body types: " + ", ".join(f"`{k}`" for k in m.vocabularies["body_types"]) + ". `kinematic` is the default.",
        "",
        "Fields of a `physics` block: " + ", ".join(f"`{k}`" for k in m.vocabularies["physics_fields"]),
        "",
        "Collision layer names (`collision_layer`, `collision_mask`, or `\"all\"`): " + ", ".join(f"`{k}`" for k in m.vocabularies["collision_layers"]),
        "",
        "## Error codes (Tier 2.6a)",
        "",
        f"{len(m.error_codes)} stable codes for matching in retry loops:",
        "",
        "| Code | Constant |",
        "|---|---|",
    ]
    for c in m.error_codes:
        lines.append(f"| `{c['code']}` | `EngineError.{c['constant']}` |")
    lines += [
        "",
        "## Reserved state fields",
        "",
        "Fields the engine reads by name (everything else is content vocabulary):",
        "",
        ", ".join(f"`{f}`" for f in m.reserved_state_fields),
        "",
        f"## Invariants",
        "",
        f"{m.invariants_count} contract invariants — see `docs/guideline/30_framework_primitives.md`.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    m = build_manifest()
    problems = sanity_check(m)
    if problems:
        print("Sanity check failed:", file=sys.stderr)
        for p in problems:
            print("  -", p, file=sys.stderr)
        return 1

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    JSON_OUT.write_text(json.dumps(m.__dict__, indent=2) + "\n", encoding="utf-8")
    MD_OUT.write_text(render_markdown(m), encoding="utf-8")
    print(f"Wrote {JSON_OUT.relative_to(REPO)}")
    print(f"Wrote {MD_OUT.relative_to(REPO)}")
    print(f"  triggers: {len(m.triggers)}")
    print(f"  effects: {len(m.effects)}")
    print(f"  query_clauses: {len(m.query_clauses)}")
    print(f"  query_operator_suffixes: {len(m.query_operator_suffixes)}")
    print(f"  error_codes: {len(m.error_codes)}")
    print(f"  hud_elements: {len(m.hud_elements)}")
    print(f"  hud_anchors: {len(m.hud_anchors)}")
    print(f"  screen_elements: {len(m.screen_elements)}")
    print(f"  screen_anchors: {len(m.screen_anchors)}")
    print(f"  map_authoring_concepts: {len(m.map_authoring_concepts)}")
    if m.viewport:
        print(f"  viewport: {m.viewport.get('width')}x{m.viewport.get('height')} "
              f"({m.viewport.get('aspect_ratio','?')}, stretch={m.viewport.get('stretch_mode','?')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
