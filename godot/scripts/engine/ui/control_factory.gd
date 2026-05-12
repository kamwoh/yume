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
	if spec.has("visible_if") or spec.has("enabled_if"):
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
	if spec.has("x_offset") or spec.has("y_offset"):
		var ox := float(spec.get("x_offset", 0))
		var oy := float(spec.get("y_offset", 0))
		node.position = Vector2(ox, oy) + node.position
	if spec.has("width") or spec.has("height"):
		var w := float(spec.get("width", node.custom_minimum_size.x))
		var h := float(spec.get("height", node.custom_minimum_size.y))
		node.custom_minimum_size = Vector2(w, h)
	if spec.has("size_flags_h"):
		node.size_flags_horizontal = _size_flag(str(spec["size_flags_h"]))
	if spec.has("size_flags_v"):
		node.size_flags_vertical = _size_flag(str(spec["size_flags_v"]))


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
