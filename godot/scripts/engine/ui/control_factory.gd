extends Object
class_name ControlFactory

## ADR 0011 — Godot Control hierarchy from JSON.
##
## Static helpers that instantiate Godot Control nodes from JSON element
## specs. Per ADR 0021, we EXPOSE Godot's Control system, never reimplement.
## A `{"type": "button", "text": "..."}` becomes a real Godot Button node;
## a `{"type": "vbox", "children": [...]}` becomes a real VBoxContainer.
##
## Used by both ScreenFlow (full screens) and the existing HUD (declared
## later — for now, GameShell still owns hud.json).
##
## Element types supported (v1):
##   label         → Label
##   button        → Button     (on_click effect chain via pressed signal)
##   vbox          → VBoxContainer  (recurses on `children`)
##   hbox          → HBoxContainer  (recurses on `children`)
##   color_rect    → ColorRect      (background fill / modal dim)
##   spacer        → Control with custom_minimum_size
##   image         → TextureRect    (texture from @assets.X reference)
##
## Common properties (any element):
##   anchor: top_left | top_center | top_right | center_left | center
##           | center_right | bottom_left | bottom_center | bottom_right
##           | fill (full_rect)
##   x_offset, y_offset, width, height
##   visible_if: formula evaluated each frame; sets node.visible
##   enabled_if: formula evaluated each frame; sets node.disabled (Button only)
##   theme_variation: name from ui/theme.json (deferred to Phase B)
##
## On-interaction signals → effect chains:
##   Button.pressed       → on_click   (effect list)
##   LineEdit.text_submitted → on_submit (deferred)
##   HSlider.value_changed → on_change  (deferred)
##   CheckBox.toggled     → on_toggle   (deferred)

# ============================================================
# PUBLIC ENTRY POINT
# ============================================================


## Build a Control hierarchy under `parent` from `spec` (element dict).
## `dispatcher` is a Callable invoked with (effect_list_array, context_dict)
## when user interactions fire. Returns the root node created.
##
## `bound_elements` (output array) collects {node, cfg} pairs for elements
## with visible_if / enabled_if formulas, so ScreenFlow can re-evaluate
## them per frame.
static func build(
	spec: Dictionary, parent: Node, dispatcher: Callable, bound_elements: Array
) -> Control:
	var t := str(spec.get("type", ""))
	var node: Control = null
	match t:
		"label":
			node = _build_label(spec)
		"button":
			node = _build_button(spec, dispatcher)
		"vbox":
			node = _build_vbox(spec, dispatcher, bound_elements)
		"hbox":
			node = _build_hbox(spec, dispatcher, bound_elements)
		"color_rect":
			node = _build_color_rect(spec)
		"spacer":
			node = _build_spacer(spec)
		"image":
			node = _build_image(spec)
		# ADR 0013 — settings UI primitives. on_change dispatches an effect
		# chain with the new value bound as ctx.value.
		"slider":
			node = _build_slider(spec, dispatcher)
		"checkbox":
			node = _build_checkbox(spec, dispatcher)
		"option_button":
			node = _build_option_button(spec, dispatcher)
		# Tier-A inventory primitive (#99, 2026-05-16). A grid of bordered
		# cells that binds to an array field and highlights an active cell.
		# Foundation for Tier-B icon hotbar + Tier-C full RPG inventory —
		# same primitive, different parameterization (columns, cell_size).
		"slot_grid":
			node = _build_slot_grid(spec)
		# Map / minimap widget (#104, 2026-05-16). HudBuilder previously
		# owned this. Adding to ControlFactory lets modal screens embed
		# the minimap (e.g. the map screen). bind_world via the Engine
		# meta set by ScreenFlow on_ready.
		"minimap":
			var mm := MinimapWidget.new()
			mm.configure(spec)
			if Engine.has_meta("yume_world"):
				mm.bind_world(Engine.get_meta("yume_world"))
			node = mm
		"settings_renderer":
			# Special: not a generic primitive. Rendered separately by the
			# screen/overlay layer that has access to the SettingsManager
			# reference. ControlFactory creates a placeholder VBox that the
			# settings layer fills in.
			node = _build_vbox({}, dispatcher, bound_elements)
			node.name = "SettingsRenderer"
			# Stash the spec so settings layer can find it
			node.set_meta("settings_spec", spec)
		_:
			push_warning("ControlFactory: unknown element type '%s'" % t)
			return null
	if node == null:
		return null
	_apply_common(node, spec)
	if spec.has("visible_if") or spec.has("enabled_if") or spec.has("binds"):
		bound_elements.append({"node": node, "cfg": spec})
	parent.add_child(node)
	return node


# ============================================================
# ELEMENT BUILDERS
# ============================================================


static func _build_label(spec: Dictionary) -> Label:
	var lbl := Label.new()
	lbl.text = _resolve_text(spec.get("text", ""))
	if spec.has("font_size"):
		lbl.add_theme_font_size_override("font_size", int(spec["font_size"]))
	if spec.has("color"):
		lbl.add_theme_color_override("font_color", _color(spec["color"]))
	# Outline for legibility against varied backgrounds (matches HUD style)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	var halign := str(spec.get("halign", "left"))
	match halign:
		"center":
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		"right":
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_:
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return lbl


static func _build_button(spec: Dictionary, dispatcher: Callable) -> Button:
	var btn := Button.new()
	btn.text = _resolve_text(spec.get("text", ""))
	if spec.has("font_size"):
		btn.add_theme_font_size_override("font_size", int(spec["font_size"]))
	# Wire pressed → effect dispatch. The dispatcher resolves the effect list
	# at fire time, not at build time, so live-updating a button's on_click
	# (rare but possible) works.
	var on_click = spec.get("on_click", null)
	if on_click != null:
		btn.pressed.connect(func(): dispatcher.call(on_click, {"_source": "button"}))
	return btn


static func _build_vbox(
	spec: Dictionary, dispatcher: Callable, bound_elements: Array
) -> VBoxContainer:
	var vb := VBoxContainer.new()
	if spec.has("separation"):
		vb.add_theme_constant_override("separation", int(spec["separation"]))
	for child in spec.get("children", []):
		if child is Dictionary:
			build(child as Dictionary, vb, dispatcher, bound_elements)
	return vb


static func _build_hbox(
	spec: Dictionary, dispatcher: Callable, bound_elements: Array
) -> HBoxContainer:
	var hb := HBoxContainer.new()
	if spec.has("separation"):
		hb.add_theme_constant_override("separation", int(spec["separation"]))
	for child in spec.get("children", []):
		if child is Dictionary:
			build(child as Dictionary, hb, dispatcher, bound_elements)
	return hb


static func _build_color_rect(spec: Dictionary) -> ColorRect:
	var cr := ColorRect.new()
	var c := _color(spec.get("color", "#000000"))
	if spec.has("alpha"):
		c.a = float(spec["alpha"])
	cr.color = c
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE  # don't eat clicks
	return cr


static func _build_spacer(spec: Dictionary) -> Control:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(float(spec.get("width", 0)), float(spec.get("height", 8)))
	return sp


static func _build_image(spec: Dictionary) -> TextureRect:
	var tr := TextureRect.new()
	var path := str(spec.get("texture", ""))
	if path != "" and ResourceLoader.exists(path):
		tr.texture = load(path)
	tr.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	return tr


# ============================================================
# SETTINGS UI PRIMITIVES (ADR 0013)
# ============================================================
#
# slider / checkbox / option_button each emit on_change with the new
# value. The dispatcher receives the effect chain + a context dict
# containing {"value": <new>}. SettingsManager-aware screens use
# settings_renderer (above) instead of these directly.


static func _build_slider(spec: Dictionary, dispatcher: Callable) -> HSlider:
	var sl := HSlider.new()
	sl.min_value = float(spec.get("min", 0.0))
	sl.max_value = float(spec.get("max", 1.0))
	sl.step = float(spec.get("step", 0.05))
	sl.value = float(spec.get("value", spec.get("default", sl.min_value)))
	sl.custom_minimum_size = Vector2(float(spec.get("width", 200)), float(spec.get("height", 20)))
	var on_change = spec.get("on_change", null)
	if on_change != null:
		sl.value_changed.connect(
			func(new_v): dispatcher.call(on_change, {"_source": "slider", "value": new_v})
		)
	return sl


static func _build_checkbox(spec: Dictionary, dispatcher: Callable) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = _resolve_text(spec.get("text", ""))
	cb.button_pressed = bool(spec.get("value", spec.get("default", false)))
	var on_change = spec.get("on_change", null)
	if on_change != null:
		cb.toggled.connect(
			func(new_v): dispatcher.call(on_change, {"_source": "checkbox", "value": new_v})
		)
	return cb


static func _build_option_button(spec: Dictionary, dispatcher: Callable) -> OptionButton:
	var ob := OptionButton.new()
	var options: Array = spec.get("options", [])
	for opt in options:
		ob.add_item(_resolve_text(str(opt)))
	# Select current value
	var current = spec.get("value", spec.get("default", null))
	if current != null:
		var idx := options.find(current)
		if idx >= 0:
			ob.select(idx)
	var on_change = spec.get("on_change", null)
	if on_change != null:
		ob.item_selected.connect(
			func(idx):
				var v = options[idx] if idx < options.size() else null
				dispatcher.call(on_change, {"_source": "option_button", "value": v})
		)
	return ob


# ============================================================
# COMMON PROPERTIES
# ============================================================


## Apply anchor / position / size / sizing flags to any Control.
## Anchors map to Godot's PRESET_* constants (see Control docs).
# ============================================================
# slot_grid (Tier A — #99)
# ============================================================
# Schema:
#   {"type": "slot_grid",
#    "cell_count": 4,                         REQUIRED — number of cells
#    "columns": 4,                            REQUIRED — grid columns
#    "binds": "player.inventory",             optional — array path; cell i shows arr[i]
#    "active_binds": "player.active_slot",    optional — int path; cell i highlights if i==value
#    "cell_size": [60, 50],                   optional [w, h] per cell (default [56, 48])
#    "gap": 4,                                optional separation between cells
#    "cell_format": "{}",                     optional template; {} = value text
#    "empty_text": "—",                       optional content when slot value == "" (default empty)
#    "show_index": true,                      optional index label top-left of each cell
#    "index_format": "{}",                    optional template for the index ({} = slot+1)
#    "bg_color": "#22201a",                   normal cell bg
#    "bg_active_color": "#3a3220",            active cell bg
#    "border_color": "#403828",               normal cell border
#    "border_active_color": "#ffd040",        active cell border
#    "text_color": "#e0d0a0",
#    "index_color": "#807060",
#    "border_width": 2,                       border thickness
#    "font_size": 14,                         content font size
#    "index_font_size": 10}
#
# Build returns a PanelContainer wrapping a GridContainer of cell children.
# Each cell PanelContainer has meta `slot_index: int` for later updates.
# Update path: _update_slot_grid(node, cfg, resolver) — resolver is a
# Callable that maps a binding path string to its current value.


static func _build_slot_grid(spec: Dictionary) -> Control:
	var cell_count: int = int(spec.get("cell_count", 4))
	var columns: int = max(1, int(spec.get("columns", cell_count)))
	var cell_size_arr: Array = spec.get("cell_size", [56, 48])
	var cell_w: float = float(cell_size_arr[0]) if cell_size_arr.size() > 0 else 56.0
	var cell_h: float = float(cell_size_arr[1]) if cell_size_arr.size() > 1 else 48.0
	var gap: int = int(spec.get("gap", 4))
	var show_index: bool = bool(spec.get("show_index", true))
	var font_size: int = int(spec.get("font_size", 14))
	var index_font_size: int = int(spec.get("index_font_size", 10))
	var text_color := _color(spec.get("text_color", "#e0d0a0"))
	var index_color := _color(spec.get("index_color", "#807060"))

	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", gap)
	grid.add_theme_constant_override("v_separation", gap)

	for i in cell_count:
		var cell := PanelContainer.new()
		cell.name = "cell_%d" % i
		cell.custom_minimum_size = Vector2(cell_w, cell_h)
		cell.set_meta("slot_index", i)
		# Initial style (normal). Active styling is applied per-frame in
		# _update_slot_grid based on the resolved active_binds.
		_apply_slot_cell_style(cell, spec, false)

		# Layered inside the cell: index label (top-left, small) + content
		# label (center, larger). MarginContainer holds them so the index
		# floats top-left.
		var stack := Control.new()
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cell.add_child(stack)

		if show_index:
			var idx_fmt := str(spec.get("index_format", "{}"))
			var idx_lbl := Label.new()
			idx_lbl.name = "index"
			idx_lbl.text = idx_fmt.replace("{}", str(i + 1))
			idx_lbl.add_theme_font_size_override("font_size", index_font_size)
			idx_lbl.add_theme_color_override("font_color", index_color)
			idx_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
			idx_lbl.add_theme_constant_override("outline_size", 2)
			idx_lbl.position = Vector2(4, 2)
			idx_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stack.add_child(idx_lbl)

		# Cell content: Label (default — shows def_id text) OR item_icon
		# (UI Tier B, #103 2026-05-16 — shows a colored swatch resolved
		# from each held def's `properties.inventory_icon_color`). Swap by
		# `cell_content_type` on the slot_grid spec.
		var content_type := str(spec.get("cell_content_type", "label"))
		if content_type == "item_icon":
			# ColorRect sized to fit the cell with a small inset so the
			# cell border stays visible around the icon.
			var icon := ColorRect.new()
			icon.name = "content"
			icon.color = Color(0, 0, 0, 0)  # invisible when slot empty
			icon.set_anchors_preset(Control.PRESET_FULL_RECT)
			# Inset 4px on each side so the cell border + index label show.
			icon.offset_left = 4
			icon.offset_top = 4
			icon.offset_right = -4
			icon.offset_bottom = -4
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stack.add_child(icon)
		else:
			var content_lbl := Label.new()
			content_lbl.name = "content"
			content_lbl.text = str(spec.get("empty_text", ""))
			content_lbl.add_theme_font_size_override("font_size", font_size)
			content_lbl.add_theme_color_override("font_color", text_color)
			content_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
			content_lbl.add_theme_constant_override("outline_size", 3)
			content_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			content_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			content_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
			content_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stack.add_child(content_lbl)

		grid.add_child(cell)

	# Mark the root so update paths can detect "this is a slot_grid".
	grid.set_meta("slot_grid_cfg", spec)
	return grid


static func _apply_slot_cell_style(
	cell: PanelContainer, spec: Dictionary, is_active: bool
) -> void:
	var sb := StyleBoxFlat.new()
	if is_active:
		sb.bg_color = _color(spec.get("bg_active_color", "#3a3220"))
		sb.border_color = _color(spec.get("border_active_color", "#ffd040"))
	else:
		sb.bg_color = _color(spec.get("bg_color", "#22201a"))
		sb.border_color = _color(spec.get("border_color", "#403828"))
	var bw := int(spec.get("border_width", 2))
	sb.border_width_left = bw
	sb.border_width_right = bw
	sb.border_width_top = bw
	sb.border_width_bottom = bw
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3
	sb.corner_radius_bottom_right = 3
	cell.add_theme_stylebox_override("panel", sb)


## Update one slot_grid node from its bindings. `resolver` is a Callable
## that maps a binding path (e.g. "player.inventory") to a value via the
## owning shell's _resolve_binding (HudBuilder + ScreenFlow both have one).
## Cheap O(cells) per frame — exits early if the grid has no cfg meta.
static func update_slot_grid(grid: Node, resolver: Callable) -> void:
	if grid == null or not grid.has_meta("slot_grid_cfg"):
		return
	var cfg: Dictionary = grid.get_meta("slot_grid_cfg")
	var values: Array = []
	if cfg.has("binds"):
		var bv = resolver.call(str(cfg["binds"]))
		if bv is Array:
			values = bv
	var active_index: int = -1
	if cfg.has("active_binds"):
		var av = resolver.call(str(cfg["active_binds"]))
		if av != null:
			active_index = int(av)
	var cell_fmt := str(cfg.get("cell_format", "{}"))
	var empty_text := str(cfg.get("empty_text", ""))
	var content_type := str(cfg.get("cell_content_type", "label"))
	# UI Tier B item_icon (#103): per-def fallback color when the def has
	# no inventory_icon_color authored. Author can override per-grid via
	# `default_icon_color` on the spec.
	var fallback_icon := Color("#a09080")
	if cfg.has("default_icon_color"):
		fallback_icon = _color(cfg["default_icon_color"])
	var i := 0
	for cell in grid.get_children():
		if not (cell is PanelContainer):
			continue
		var pc: PanelContainer = cell
		var idx: int = int(pc.get_meta("slot_index", i))
		# Re-style for active vs normal.
		_apply_slot_cell_style(pc, cfg, idx == active_index)
		# Resolve cell content from the bound array.
		var content_node := pc.find_child("content", true, false)
		var raw_val = "" if idx >= values.size() else values[idx]
		var s := str(raw_val)
		if content_type == "item_icon" and content_node is ColorRect:
			if s == "":
				(content_node as ColorRect).color = Color(0, 0, 0, 0)
			else:
				# Resolve def-side inventory_icon_color via the shell's
				# def.X.Y binding path (#103, 2026-05-16). Fallback color
				# if the def doesn't carry one — keeps the cell readable
				# during content-authoring iteration.
				var col_v = resolver.call("def." + s + ".properties.inventory_icon_color")
				if col_v == null or str(col_v) == "":
					(content_node as ColorRect).color = fallback_icon
				else:
					(content_node as ColorRect).color = _color(col_v)
		elif content_node is Label:
			if s == "":
				(content_node as Label).text = empty_text
			else:
				(content_node as Label).text = cell_fmt.replace("{}", s)
		i += 1


static func _apply_common(node: Control, spec: Dictionary) -> void:
	# ADR 0039: propagate JSON id → Control.name verbatim so step_runner's
	# click selectors `{"click": {"id": "btn_new_game"}}` can locate the
	# Control by id. Default Godot autogenerates "Button", "Button2", etc.
	# Collisions are an authoring bug (duplicate id in screens.json) — we
	# log + still assign (Godot dedupes via numeric suffix on add_child),
	# don't silently mangle. Authors fix the duplicate.
	if spec.has("id"):
		node.name = str(spec["id"])
	var anchor := str(spec.get("anchor", ""))
	if anchor != "":
		_apply_anchor(node, anchor)
	# Combined anchor + size positioning (#104, 2026-05-16). All of
	# width/height/x_offset/y_offset accept EITHER pixels (number) OR a
	# percent-of-viewport string ("25%", "-10%"). Examples:
	#   "width": 200        → 200 px
	#   "width": "25%"      → 25% of viewport width
	#   "y_offset": "-5%"   → -5% of viewport height (useful for negative
	#                          offsets from bottom/right anchors)
	# Anchors are already normalized (PRESET_* maps to 0/0.5/1 fractions).
	# This makes the full positioning system resolution-independent.
	var vp := _viewport_size(node)
	var ox := resolve_pct(spec.get("x_offset", 0), vp.x)
	var oy := resolve_pct(spec.get("y_offset", 0), vp.y)
	var has_size: bool = spec.has("width") or spec.has("height")
	if has_size:
		var w := resolve_pct(spec.get("width", node.custom_minimum_size.x), vp.x)
		var h := resolve_pct(spec.get("height", node.custom_minimum_size.y), vp.y)
		node.custom_minimum_size = Vector2(w, h)
		_apply_anchor_sized_rect(node, anchor, w, h, ox, oy)
	elif spec.has("x_offset") or spec.has("y_offset"):
		node.position = Vector2(ox, oy) + node.position
	if spec.has("size_flags_h"):
		node.size_flags_horizontal = _size_flag(str(spec["size_flags_h"]))
	if spec.has("size_flags_v"):
		node.size_flags_vertical = _size_flag(str(spec["size_flags_v"]))


## Resolve a value that may be a pixel number OR a percent-of-viewport
## string ("25%", "100%"). Returns float pixels. Falls back to the value
## as float if no % suffix. `basis` is the dimension to take % against
## (viewport width or height). Use this when reading width/height/
## x_offset/y_offset from JSON to support mixed pixel + % authoring.
##
## Examples:
##   resolve_pct(200, 960)    → 200.0 (pixel)
##   resolve_pct("25%", 960)  → 240.0 (% of viewport width)
##   resolve_pct("-10%", 540) → -54.0 (negative % — useful for offsets
##                                     from bottom/right anchors)
static func resolve_pct(v, basis: float) -> float:
	if v is String:
		var s := str(v).strip_edges()
		if s.ends_with("%"):
			var raw := s.substr(0, s.length() - 1).strip_edges()
			if raw.is_valid_float():
				return float(raw) * 0.01 * basis
		# Fall through: plain string with no % treated as numeric
		if s.is_valid_float():
			return float(s)
		return 0.0
	return float(v)


## Look up the current viewport size for percent resolution. Falls back
## to the project's design viewport (960×540) when no viewport accessible
## yet — safe for build-time positioning.
static func _viewport_size(node: Control) -> Vector2:
	if node != null:
		var vp := node.get_viewport()
		if vp != null:
			var sz := vp.get_visible_rect().size
			if sz.x > 0 and sz.y > 0:
				return sz
	# Fallback to project setting (960×540 per project.godot for Yume)
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 960)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 540))
	)


## Compute the four Control offsets for an anchor + size + user x/y_offset
## combo so the rect spans (w × h) at the right position relative to the
## anchor point. PUBLIC so HudBuilder + other UI builders can delegate
## to the same positioning logic — one canonical anchor + size resolver
## across the engine (#104, 2026-05-16).
##
## Accepts both dash ("top-right") and underscore ("top_right") forms —
## HudBuilder uses dashes; ControlFactory uses underscores. Internally
## normalized to dashes-free form.
##
## x_offset / y_offset shift the rect from its natural anchor position:
##   top_left + x=20 y=20  → rect starts 20 in from the top-left corner
##   center  + x=0  y=-50  → rect centered horizontally, 50 above center
##   bottom_right + x=-20 y=-20 → rect inset 20 from bottom-right
static func apply_anchor_sized_rect(
	node: Control, anchor: String, w: float, h: float, ox: float, oy: float
) -> void:
	# Set the underlying anchor preset first (in case the caller didn't).
	apply_anchor(node, anchor)
	var a := anchor.replace("-", "_")
	var hw := w * 0.5
	var hh := h * 0.5
	# Default to top-left if anchor is empty/unknown.
	var ol := ox
	var ot := oy
	match a:
		"top_left", "":
			ol = ox
			ot = oy
		"top_center":
			ol = -hw + ox
			ot = oy
		"top_right":
			ol = -w + ox
			ot = oy
		"center_left":
			ol = ox
			ot = -hh + oy
		"center":
			ol = -hw + ox
			ot = -hh + oy
		"center_right":
			ol = -w + ox
			ot = -hh + oy
		"bottom_left":
			ol = ox
			ot = -h + oy
		"bottom_center":
			ol = -hw + ox
			ot = -h + oy
		"bottom_right":
			ol = -w + ox
			ot = -h + oy
		"fill":
			# Spans full parent rect; size args ignored in this mode.
			return
	node.offset_left = ol
	node.offset_top = ot
	node.offset_right = ol + w
	node.offset_bottom = ot + h


## Public wrapper around the internal anchor preset lookup. Accepts
## dash or underscore form. Used by HudBuilder + ControlFactory both.
static func apply_anchor(node: Control, anchor: String) -> void:
	_apply_anchor(node, anchor.replace("-", "_"))


## Legacy alias for internal call sites that already pass underscore form.
static func _apply_anchor_sized_rect(
	node: Control, anchor: String, w: float, h: float, ox: float, oy: float
) -> void:
	apply_anchor_sized_rect(node, anchor, w, h, ox, oy)


## Apply an anchor preset. For horizontally-centered presets, also set
## grow_horizontal = BOTH so the control expands symmetrically around the
## anchor point (instead of pinning its left edge to center). Same trick
## for vertically-centered presets via grow_vertical. Without these,
## "anchor: top_center" labels appear right-of-center because Godot's
## default GROW_DIRECTION_END pushes the element to the right.
static func _apply_anchor(node: Control, anchor: String) -> void:
	match anchor:
		"top_left":
			node.set_anchors_preset(Control.PRESET_TOP_LEFT)
		"top_center":
			node.set_anchors_preset(Control.PRESET_CENTER_TOP)
			node.grow_horizontal = Control.GROW_DIRECTION_BOTH
		"top_right":
			node.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		"center_left":
			node.set_anchors_preset(Control.PRESET_CENTER_LEFT)
			node.grow_vertical = Control.GROW_DIRECTION_BOTH
		"center":
			node.set_anchors_preset(Control.PRESET_CENTER)
			node.grow_horizontal = Control.GROW_DIRECTION_BOTH
			node.grow_vertical = Control.GROW_DIRECTION_BOTH
		"center_right":
			node.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
			node.grow_vertical = Control.GROW_DIRECTION_BOTH
		"bottom_left":
			node.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		"bottom_center":
			node.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
			node.grow_horizontal = Control.GROW_DIRECTION_BOTH
		"bottom_right":
			node.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		"fill":
			node.set_anchors_preset(Control.PRESET_FULL_RECT)
		_:
			pass  # unknown anchor — leave default


static func _size_flag(s: String) -> int:
	match s:
		"shrink_begin":
			return Control.SIZE_SHRINK_BEGIN
		"shrink_center":
			return Control.SIZE_SHRINK_CENTER
		"shrink_end":
			return Control.SIZE_SHRINK_END
		"fill":
			return Control.SIZE_FILL
		"expand":
			return Control.SIZE_EXPAND
		"expand_fill":
			return Control.SIZE_EXPAND_FILL
	return Control.SIZE_FILL


# ============================================================
# UTIL
# ============================================================


## Resolve @strings.x.y refs same way GameShell does. Falls back to
## literal text. Static so we don't need a ScreenFlow instance.
static func _resolve_text(v) -> String:
	var s := str(v)
	if not s.begins_with("@"):
		return s
	# ScreenFlow sets a global resolver on the engine env at load time;
	# we look it up via Engine singleton metadata. If absent, fall back.
	# (See ScreenFlow.set_resolver().)
	if Engine.has_meta("yume_at_resolver"):
		var resolver: Callable = Engine.get_meta("yume_at_resolver")
		var resolved := str(resolver.call(s))
		if resolved != "":
			return resolved
	return s


static func _color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(str(v))
	return Color.WHITE
