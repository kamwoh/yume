extends RefCounted
class_name WinLoseWidget

## Win / lose condition checker + panel display.
##
## Reads `win` / `lose` blocks from hud.json each frame:
##   win = {binds: "world.score", op: ">=", value: 30, message: "YOU WIN"}
##   lose = {binds: "player.hp", op: "<=", value: 0, sustained: 30, message: "GAME OVER"}
##
## When the win condition matches: show win panel, freeze world.
## When the lose condition matches for `sustained` consecutive ticks:
## show lose panel, freeze world.
##
## Owned by GameShell. Uses GameShell's _win_panel/_win_label (built by
## HudBuilder) and shell._resolve_binding / shell._resolve_at_ref for
## per-frame binding evaluation.

var _shell: Node = null  # GameShell back-ref
var _won: bool = false
var _lost: bool = false
var _sustain_counter: int = 0


func _init(shell: Node) -> void:
	_shell = shell


## True if the game has ended (won or lost). GameShell uses this to gate
## per-frame processing — once ended, only listen for restart.
func is_ended() -> bool:
	return _won or _lost


## Per-frame check. Called from GameShell._process.
func check(hud_cfg: Dictionary) -> void:
	var win_cfg: Dictionary = hud_cfg.get("win", {}) as Dictionary
	if not win_cfg.is_empty() and _matches(win_cfg):
		_show_outcome(
			_resolve_message(str(win_cfg.get("message", "🌟 YOU WIN! 🌟\nPress R to restart"))), true
		)
		return
	var lose_cfg: Dictionary = hud_cfg.get("lose", {}) as Dictionary
	if not lose_cfg.is_empty():
		var hit := _matches(lose_cfg)
		var sustained := int(lose_cfg.get("sustained", 0))
		if hit:
			_sustain_counter += 1
			if _sustain_counter >= sustained:
				_show_outcome(
					_resolve_message(
						str(lose_cfg.get("message", "💀 GAME OVER\nPress R to restart"))
					),
					false
				)
		else:
			_sustain_counter = max(0, _sustain_counter - 1)


## ADR 0009 Phase 2c: pass strings through @-prefix resolution. Falls
## back to literal text if not @-prefixed or ref unresolved.
func _resolve_message(s: String) -> String:
	if not s.begins_with("@"):
		return s
	var resolved = _shell.call("_resolve_at_ref", s)
	return resolved if resolved != "" else s


func _matches(cond: Dictionary) -> bool:
	var binding := str(cond.get("binds", ""))
	var op := str(cond.get("op", ">="))
	var threshold = cond.get("value", 0)
	var v = _shell.call("_resolve_binding", binding)
	if v == null:
		return false
	var lhs := float(v)
	var rhs := float(threshold)
	match op:
		">=":
			return lhs >= rhs
		">":
			return lhs > rhs
		"<=":
			return lhs <= rhs
		"<":
			return lhs < rhs
		"==":
			return lhs == rhs
		"!=":
			return lhs != rhs
	return false


func _show_outcome(message: String, won: bool) -> void:
	if _won or _lost:
		return
	if won:
		_won = true
	else:
		_lost = true
	# HudBuilder owns _win_label / _win_panel; GameShell exposes them as
	# fields. Read them via the shell back-ref.
	var lbl = _shell.get("_win_label")
	var panel = _shell.get("_win_panel")
	if lbl != null:
		(lbl as Label).text = message + "\n\nPress R to restart"
	if panel != null:
		(panel as Panel).visible = true
	# Freeze World — stops input polling + motion integration. HUD keeps running.
	var world = _shell.get("_world")
	if world != null and world.has_method("set_process"):
		world.set_process(false)
