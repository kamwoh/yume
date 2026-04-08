extends Node

## UI Theme — loaded from meta.json "ui_theme" section, or defaults if not present.
## Every color, size, and margin is data-driven.

# Defaults (overridden by meta.json)
var PANEL_BG := Color(0.06, 0.05, 0.12, 0.92)
var PANEL_BORDER := Color(0.72, 0.58, 0.2, 1)
var ACCENT := Color(0.9, 0.75, 0.3, 1)
var TEXT_COLOR := Color(0.95, 0.93, 0.85, 1)
var TEXT_DIM := Color(0.6, 0.55, 0.45, 1)
var HP_COLOR := Color(0.2, 0.75, 0.3, 1)
var MP_COLOR := Color(0.3, 0.4, 0.85, 1)
var DANGER := Color(0.85, 0.2, 0.2, 1)
var SHADOW := Color(0, 0, 0, 0.5)

var BORDER_WIDTH: int = 2
var CORNER_RADIUS: int = 6
var CONTENT_MARGIN: int = 14
var SHADOW_SIZE: int = 3
var FONT_SIZE_TITLE: int = 28
var FONT_SIZE_HEADER: int = 20
var FONT_SIZE_BODY: int = 16
var FONT_SIZE_SMALL: int = 13

func _load_color(theme: Dictionary, key: String, default: Color) -> Color:
	var c = theme.get(key)
	if c is Array and c.size() >= 3:
		var a: float = c[3] if c.size() >= 4 else 1.0
		return Color(c[0], c[1], c[2], a)
	return default

func _ready() -> void:
	# Load theme from meta.json
	var file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			var theme: Dictionary = data.get("ui_theme", {})
			if theme.size() > 0:
				PANEL_BG = _load_color(theme, "panel_bg", PANEL_BG)
				PANEL_BORDER = _load_color(theme, "panel_border", PANEL_BORDER)
				ACCENT = _load_color(theme, "accent", ACCENT)
				TEXT_COLOR = _load_color(theme, "text_color", TEXT_COLOR)
				TEXT_DIM = _load_color(theme, "text_dim", TEXT_DIM)
				HP_COLOR = _load_color(theme, "hp_color", HP_COLOR)
				MP_COLOR = _load_color(theme, "mp_color", MP_COLOR)
				DANGER = _load_color(theme, "danger", DANGER)
				BORDER_WIDTH = theme.get("border_width", BORDER_WIDTH)
				CORNER_RADIUS = theme.get("corner_radius", CORNER_RADIUS)
				FONT_SIZE_TITLE = theme.get("font_size_title", FONT_SIZE_TITLE)
				FONT_SIZE_BODY = theme.get("font_size_body", FONT_SIZE_BODY)

	# Apply theme to all existing UI on next frame
	await get_tree().process_frame
	apply_to_all()

func apply_to_all() -> void:
	var root = get_tree().current_scene
	if root:
		_apply_recursive(root)

func _apply_recursive(node: Node) -> void:
	if node is PanelContainer:
		style_panel(node)
	if node is Label:
		style_label(node)
	if node is RichTextLabel:
		style_richtext(node)
	if node is Button:
		style_button(node)
	for child in node.get_children():
		_apply_recursive(child)

func make_panel_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = PANEL_BORDER
	sb.border_width_bottom = BORDER_WIDTH
	sb.border_width_top = BORDER_WIDTH
	sb.border_width_left = BORDER_WIDTH
	sb.border_width_right = BORDER_WIDTH
	sb.corner_radius_top_left = CORNER_RADIUS
	sb.corner_radius_top_right = CORNER_RADIUS
	sb.corner_radius_bottom_left = CORNER_RADIUS
	sb.corner_radius_bottom_right = CORNER_RADIUS
	sb.content_margin_left = CONTENT_MARGIN
	sb.content_margin_right = CONTENT_MARGIN
	sb.content_margin_top = CONTENT_MARGIN - 4
	sb.content_margin_bottom = CONTENT_MARGIN - 4
	sb.shadow_color = SHADOW
	sb.shadow_size = SHADOW_SIZE
	sb.shadow_offset = Vector2(2, 2)
	return sb

func make_button_stylebox(pressed: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if pressed:
		sb.bg_color = ACCENT
	else:
		sb.bg_color = Color(PANEL_BG.r + 0.05, PANEL_BG.g + 0.05, PANEL_BG.b + 0.08, 0.95)
	sb.border_color = PANEL_BORDER
	sb.border_width_bottom = 1
	sb.border_width_top = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

func make_hover_stylebox() -> StyleBoxFlat:
	var sb := make_button_stylebox()
	sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.25)
	return sb

func style_panel(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", make_panel_stylebox())

func style_label(label: Label) -> void:
	label.add_theme_color_override("font_color", TEXT_COLOR)

func style_richtext(rt: RichTextLabel) -> void:
	rt.add_theme_color_override("default_color", TEXT_COLOR)

func style_button(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", make_button_stylebox())
	btn.add_theme_stylebox_override("hover", make_hover_stylebox())
	btn.add_theme_stylebox_override("pressed", make_button_stylebox(true))
	btn.add_theme_color_override("font_color", TEXT_COLOR)
	btn.add_theme_color_override("font_hover_color", ACCENT)

# --- Convenience for dynamic UI created at runtime ---

func styled_panel() -> PanelContainer:
	var p := PanelContainer.new()
	style_panel(p)
	return p

func styled_label(text: String, size: int = FONT_SIZE_BODY, color: Color = TEXT_COLOR) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func styled_header(text: String) -> Label:
	return styled_label(text, FONT_SIZE_HEADER, ACCENT)

func styled_title(text: String) -> Label:
	var l = styled_label(text, FONT_SIZE_TITLE, ACCENT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func hp_bar(current: int, max_val: int) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = max_val
	bar.value = current
	bar.custom_minimum_size = Vector2(120, 14)
	bar.show_percentage = false
	var fg := StyleBoxFlat.new()
	fg.bg_color = HP_COLOR
	fg.corner_radius_top_left = 3
	fg.corner_radius_bottom_left = 3
	fg.corner_radius_top_right = 3
	fg.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override("fill", fg)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.15, 0.15, 0.15, 0.8)
	bg.corner_radius_top_left = 3
	bg.corner_radius_bottom_left = 3
	bg.corner_radius_top_right = 3
	bg.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override("background", bg)
	return bar

func mp_bar(current: int, max_val: int) -> ProgressBar:
	var bar := hp_bar(current, max_val)
	var fg := StyleBoxFlat.new()
	fg.bg_color = MP_COLOR
	fg.corner_radius_top_left = 3
	fg.corner_radius_bottom_left = 3
	fg.corner_radius_top_right = 3
	fg.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override("fill", fg)
	return bar
