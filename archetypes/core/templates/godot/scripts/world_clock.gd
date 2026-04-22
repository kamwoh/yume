extends Node

## World Clock — heartbeat for the simulation.
##
## Emits `tick(tick_count)` every `tick_seconds` of real time. Brains and the
## rules engine connect to this signal to drive their decisions and effects.
## Movement physics is unaffected — it stays continuous between ticks.
##
## Default tick rate set from meta.world_clock.tick_seconds, fallback 0.5.

signal tick(tick_count: int)

var tick_seconds: float = 0.5
var tick_count: int = 0
var _elapsed: float = 0.0


func _ready() -> void:
	# Read tick_seconds from meta.json (no per-data_root override yet — single global rate).
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			var wc: Dictionary = meta.get("world_clock", {})
			tick_seconds = float(wc.get("tick_seconds", tick_seconds))
	print("[Clock] tick_seconds=", tick_seconds)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= tick_seconds:
		_elapsed -= tick_seconds
		tick_count += 1
		tick.emit(tick_count)
