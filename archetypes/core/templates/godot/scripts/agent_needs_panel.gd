extends Control

## Single-agent needs panel — reusable. Bind one agent via set_agent(),
## panel draws label + bars for whatever needs that agent's brain reports.
## Layout self-contained: caller positions the panel and reads its size.

var agent: Node = null

# Layout
var bar_width: float = 200.0
var bar_height: float = 12.0
var bar_gap: float = 18.0

# Per-need fill colors (full color, critical color)
var need_colors: Dictionary = {
	"hunger": [Color(0.85, 0.55, 0.2), Color(0.95, 0.2, 0.2)],
	"thirst": [Color(0.3, 0.6, 0.95), Color(0.95, 0.2, 0.2)],
	"energy": [Color(0.4, 0.85, 0.4), Color(0.95, 0.2, 0.2)],
}
var color_bg := Color(0.12, 0.12, 0.12, 0.85)
var color_border := Color(0.4, 0.4, 0.4, 0.7)
var color_text := Color(1, 1, 1)


func set_agent(a: Node) -> void:
	agent = a
	queue_redraw()


func get_needs_count() -> int:
	if not agent: return 0
	var brain: Node = agent.get("brain") if agent.has_method("get") else null
	if not brain or not brain.has_method("get_needs_summary"): return 0
	return brain.get_needs_summary().size()


func panel_height() -> float:
	# Title line + N need bars + status line
	return 16.0 + get_needs_count() * bar_gap + 16.0


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if not agent or not is_instance_valid(agent):
		return
	var brain: Node = agent.get("brain") if agent.has_method("get") else null
	if not brain or not brain.has_method("get_needs_summary"):
		return
	var summary: Dictionary = brain.get_needs_summary()
	var label_prefix: String = str(agent.name).replace("Entity_", "")

	draw_string(ThemeDB.fallback_font, Vector2(0, 0), label_prefix,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color_text)

	var y: float = 16.0
	# Stable order: known needs first, then any extras
	var order: Array = ["hunger", "thirst", "energy"]
	for k in summary.keys():
		if not (k in order):
			order.append(k)
	for need_id in order:
		if not summary.has(need_id):
			continue
		var n: Dictionary = summary[need_id]
		_draw_bar(need_id, float(n.get("current", 0)), float(n.get("max", 100)), y)
		y += bar_gap

	# Status line — what the brain is doing right now
	if brain.has_method("get_status_label"):
		var status: String = str(brain.get_status_label())
		draw_string(ThemeDB.fallback_font, Vector2(0, y + 12), status,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.85, 0.7))


func _draw_bar(need_id: String, current: float, maximum: float, y: float) -> void:
	var pct: float = clamp(current / max(maximum, 0.01), 0.0, 1.0)
	var colors: Array = need_colors.get(need_id, [Color.WHITE, Color.RED])
	var fill_color: Color = colors[1] if pct < 0.25 else colors[0]

	draw_string(ThemeDB.fallback_font, Vector2(0, y + bar_height - 2), need_id.capitalize(),
		HORIZONTAL_ALIGNMENT_LEFT, 56, 10, color_text)

	var bar_x: float = 56.0
	draw_rect(Rect2(Vector2(bar_x, y), Vector2(bar_width, bar_height)), color_bg)
	draw_rect(Rect2(Vector2(bar_x, y), Vector2(bar_width * pct, bar_height)), fill_color)
	draw_rect(Rect2(Vector2(bar_x, y), Vector2(bar_width, bar_height)), color_border, false, 1.0)

	var val_text: String = "%d / %d" % [int(current), int(maximum)]
	draw_string(ThemeDB.fallback_font, Vector2(bar_x + bar_width + 6, y + bar_height - 2),
		val_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color_text)
