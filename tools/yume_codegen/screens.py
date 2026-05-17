"""
screens.py — builders for screens.json / hud.json JSON dicts.

Schema: ADR 0011 (declarative screen flow) + .claude/rules/visual-qa.md
        § screen-flow gate + ControlFactory element types.

A screens.json file has the shape:
    {
      "starting_screen": "<id>" | "",
      "screens": [<screen_dict>...],
      "global_inputs": [<global_input_dict>...]
    }

Each screen has elements; each element is built by element() with a
type, anchor, and type-specific fields. The control_factory engine
side does the dispatch.
"""


def _strip_none(d: dict) -> dict:
    return {k: v for k, v in d.items() if v is not None}


# ============================================================
# SCREEN
# ============================================================


def screen(
    id: str,
    elements: list[dict],
    freeze_world: bool = False,
    background_color: str | None = None,
    background_alpha: float | None = None,
    modal: bool = False,
    advance_action: str | None = None,
    comment: str | None = None,
) -> dict:
    """Build a screen dict.

    Common patterns:
        - title screen:   freeze_world=False, background full
        - pause modal:    freeze_world=True, modal=True, dim background
        - inventory:      freeze_world=True, modal=True
        - end splash:     freeze_world=True, full-screen

    `advance_action` lets a single action (typically ui_accept = Enter)
    dismiss the screen — common on tutorial overlays.
    """
    return _strip_none({
        "_comment": comment,
        "id": id,
        "freeze_world": freeze_world,
        "modal": modal,
        "background_color": background_color,
        "background_alpha": background_alpha,
        "advance_action": advance_action,
        "elements": elements,
    })


# ============================================================
# GLOBAL INPUTS (close-toggle pattern)
# ============================================================


def global_input(
    action: str,
    on_press: list[dict],
    if_screen: str | None = None,
    comment: str | None = None,
) -> dict:
    """A screen-flow-level input handler. Fires on press-edge while
    if_screen filter matches (empty string = match when stack is empty).

    Use for the toggle-close pattern (I-press closes the inventory it
    just opened) per commit c221633's fix. Pair every open-rule with
    an `if_screen: <screen_id>` global_input whose on_press pops
    `@previous`."""
    return _strip_none({
        "_comment": comment,
        "action": action,
        "if_screen": if_screen,
        "on_press": on_press,
    })


# ============================================================
# ELEMENT — generic + sugar factories per type
# ============================================================


def element(
    type: str,
    anchor: str = "top-left",
    x_offset: int | float = 0,
    y_offset: int | float = 0,
    width=None,
    height=None,
    **extra,
) -> dict:
    """Build a generic element dict. Prefer the typed helpers below
    when available (label, panel, progress_bar, etc.) — this is the
    escape hatch for element types not yet exposed as factories.

    width/height accept either pixel ints/floats OR percent strings
    like "25%" (resolved by ControlFactory.resolve_pct against
    viewport basis).
    """
    return _strip_none({
        "type": type,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
        **extra,
    })


def label(
    text=None,
    binds: str | None = None,
    anchor: str = "top-left",
    x_offset=0,
    y_offset=0,
    width=None,
    height=None,
    font_size: int | None = None,
    color: str | None = None,
    align: str | None = None,
    comment: str | None = None,
) -> dict:
    """Text label. Either `text` (static) or `binds` (live state).

    binds path resolves at runtime:
        - "world.X"        — env.world_state.X (deprecated; prefer entity)
        - "<tag>.X"        — first entity with tag, state.X
        - "@strings.X.Y"   — ui/strings.json lookup
        - "def.<def>.X"    — def-property lookup
    """
    return _strip_none({
        "_comment": comment,
        "type": "label",
        "text": text,
        "binds": binds,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
        "font_size": font_size,
        "color": color,
        "align": align,
    })


def panel(
    children: list[dict],
    anchor: str = "top-left",
    x_offset=0,
    y_offset=0,
    width=None,
    height=None,
    background_color: str | None = None,
    background_alpha: float | None = None,
    padding: int | None = None,
    spacing: int | None = None,
    comment: str | None = None,
) -> dict:
    """A VBox-layout panel. Children stack vertically with `spacing`
    px between them.

    Gotcha (per .claude/rules/engine-scripts.md § HUD panel anchor):
    centered anchors (top-center, bottom-center, center) need CENTER
    presets, NOT WIDE presets. _build_panel handles this — but if you
    pass a wide anchor and a narrow width, the panel stretches the
    full viewport with children offset off-screen.
    """
    return _strip_none({
        "_comment": comment,
        "type": "panel",
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
        "background_color": background_color,
        "background_alpha": background_alpha,
        "padding": padding,
        "spacing": spacing,
        "elements": children,
    })


def progress_bar(
    binds: str,
    max_value=100,
    min_value=0,
    anchor: str = "top-left",
    x_offset=0,
    y_offset=0,
    width=140,
    height=10,
    color: str | None = None,
    background_color: str | None = None,
    label_binds: str | None = None,
    comment: str | None = None,
) -> dict:
    """Progress bar (vital, XP, etc.). binds resolves to current value.

    Width-flag note (per yume-visual-designer skill): ProgressBar
    defaults to SIZE_FILL ignoring authored width. Engine sets
    SIZE_SHRINK_BEGIN by default; override via `size_flags_h: "fill"`
    if you want it to stretch."""
    return _strip_none({
        "_comment": comment,
        "type": "progress_bar",
        "binds": binds,
        "min": min_value,
        "max": max_value,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
        "color": color,
        "background_color": background_color,
        "label_binds": label_binds,
    })


def slot_grid(
    binds: str,
    cell_count: int = 4,
    cell_size: int = 50,
    cell_content_type: str | None = None,
    active_binds: str | None = None,
    anchor: str = "bottom-right",
    x_offset=0,
    y_offset=0,
    columns: int | None = None,
    comment: str | None = None,
) -> dict:
    """Slot grid — N cells laid out in a grid, optionally with content
    icons (cell_content_type="item_icon").

    binds: path resolving to an array of slot values (typically
        "<actor_tag>.inventory" → ["wheat", "", "axe", ""]).
    active_binds: optional path to the active-slot index, used to
        highlight the currently-selected cell.
    """
    return _strip_none({
        "_comment": comment,
        "type": "slot_grid",
        "binds": binds,
        "cell_count": cell_count,
        "cell_size": cell_size,
        "cell_content_type": cell_content_type,
        "active_binds": active_binds,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "columns": columns,
    })


def item_icon(
    binds: str,
    size: int = 32,
    anchor: str = "top-left",
    x_offset=0,
    y_offset=0,
    fallback_color: str = "#808080",
    comment: str | None = None,
) -> dict:
    """Single item icon — a ColorRect whose color comes from the
    bound def's `properties.inventory_icon_color`. Falls back to
    `fallback_color` when the slot is empty."""
    return _strip_none({
        "_comment": comment,
        "type": "item_icon",
        "binds": binds,
        "size": size,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "fallback_color": fallback_color,
    })


def button(
    text: str,
    on_click: list[dict] | None = None,
    on_submit: list[dict] | None = None,
    anchor: str = "center",
    x_offset=0,
    y_offset=0,
    width=200,
    height=40,
    id: str | None = None,
    comment: str | None = None,
) -> dict:
    """Button with click-effect chain.

    EFFECT-CHAIN GATE: per .claude/rules/engine-scripts.md, destructive
    effects (transition_level, reload_scene, load_state, quit_app)
    must be LAST in the chain. Anything queued after is silently
    dropped at end-of-frame.
    """
    return _strip_none({
        "_comment": comment,
        "type": "button",
        "id": id,
        "text": text,
        "on_click": on_click,
        "on_submit": on_submit,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
    })


def image(
    path: str,
    anchor: str = "center",
    x_offset=0,
    y_offset=0,
    width=None,
    height=None,
    comment: str | None = None,
) -> dict:
    """2D image (texture). `path` is a `res://` resource path."""
    return _strip_none({
        "_comment": comment,
        "type": "image",
        "path": path,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
    })


def image_3d(
    mesh: str,
    anchor: str = "center",
    x_offset=0,
    y_offset=0,
    size=None,
    rotation=None,
    comment: str | None = None,
) -> dict:
    """3D mesh thumbnail rendered into a SubViewport. Used for
    inventory item icons, faction crests, etc."""
    return _strip_none({
        "_comment": comment,
        "type": "image_3d",
        "mesh": mesh,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "size": size,
        "rotation": rotation,
    })


def minimap(
    binds: str | None = None,
    world_bounds: list | None = None,
    tag_colors: dict | None = None,
    anchor: str = "top-right",
    x_offset=0,
    y_offset=0,
    width=200,
    height=200,
    show_view_cone: bool = False,
    comment: str | None = None,
) -> dict:
    """Minimap widget. tag_colors maps entity tags to dot colors.
    show_view_cone draws the player's facing direction as an arc.
    """
    return _strip_none({
        "_comment": comment,
        "type": "minimap",
        "binds": binds,
        "world_bounds": world_bounds,
        "tag_colors": tag_colors,
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
        "show_view_cone": show_view_cone,
    })


def control(
    children: list[dict],
    anchor: str = "top-left",
    x_offset=0,
    y_offset=0,
    width=None,
    height=None,
    comment: str | None = None,
) -> dict:
    """Generic Control container. Like panel but no VBox auto-layout
    — children position by their own anchors. Use for free-form
    layouts (HUD, overlay)."""
    return _strip_none({
        "_comment": comment,
        "type": "control",
        "anchor": anchor,
        "x_offset": x_offset,
        "y_offset": y_offset,
        "width": width,
        "height": height,
        "elements": children,
    })
