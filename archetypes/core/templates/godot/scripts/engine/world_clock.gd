extends Node
class_name WorldClock

## World Clock — heartbeat for the simulation.
##
## Emits `tick(tick_count)` every `tick_seconds` of real time. The phase
## scheduler listens to this signal. Movement + rendering are unaffected;
## they stay continuous between ticks.
##
## `tick_seconds` is set programmatically by the World orchestrator at
## construction, not read from a global meta.json. That keeps multi-world
## usage (parallel sims, tests, save/load) from depending on a shared file.

signal tick(tick_count: int)

@export var tick_seconds: float = 0.5
var tick_count: int = 0
var _elapsed: float = 0.0


func _ready() -> void:
	print("[Clock] tick_seconds=", tick_seconds)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= tick_seconds:
		_elapsed -= tick_seconds
		tick_count += 1
		tick.emit(tick_count)
