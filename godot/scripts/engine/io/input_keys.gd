class_name InputKeys
extends RefCounted
## ADR 0090 — the key names and mouse button names of the spec.
##
## A key name means a key position on a US keyboard layout. The Godot
## interpreter binds it as a physical keycode, so "W" stays in the same
## place on any layout. This table maps each name to its host code. The
## interpreter does not parse key names with the host's own key table.
##
## validate_host_neutral.py and gen_api_manifest.py read KEYS and
## MOUSE_BUTTONS from this file. A new name needs an ADR.

const KEYS := {
	"A": KEY_A, "B": KEY_B, "C": KEY_C, "D": KEY_D, "E": KEY_E, "F": KEY_F,
	"G": KEY_G, "H": KEY_H, "I": KEY_I, "J": KEY_J, "K": KEY_K, "L": KEY_L,
	"M": KEY_M, "N": KEY_N, "O": KEY_O, "P": KEY_P, "Q": KEY_Q, "R": KEY_R,
	"S": KEY_S, "T": KEY_T, "U": KEY_U, "V": KEY_V, "W": KEY_W, "X": KEY_X,
	"Y": KEY_Y, "Z": KEY_Z,
	"0": KEY_0, "1": KEY_1, "2": KEY_2, "3": KEY_3, "4": KEY_4,
	"5": KEY_5, "6": KEY_6, "7": KEY_7, "8": KEY_8, "9": KEY_9,
	"F1": KEY_F1, "F2": KEY_F2, "F3": KEY_F3, "F4": KEY_F4, "F5": KEY_F5,
	"F6": KEY_F6, "F7": KEY_F7, "F8": KEY_F8, "F9": KEY_F9, "F10": KEY_F10,
	"F11": KEY_F11, "F12": KEY_F12,
	"Up": KEY_UP, "Down": KEY_DOWN, "Left": KEY_LEFT, "Right": KEY_RIGHT,
	"Space": KEY_SPACE, "Enter": KEY_ENTER, "Escape": KEY_ESCAPE,
	"Tab": KEY_TAB, "Shift": KEY_SHIFT, "Ctrl": KEY_CTRL, "Alt": KEY_ALT,
	"Backspace": KEY_BACKSPACE,
	"Numpad0": KEY_KP_0, "Numpad1": KEY_KP_1, "Numpad2": KEY_KP_2,
	"Numpad3": KEY_KP_3, "Numpad4": KEY_KP_4, "Numpad5": KEY_KP_5,
	"Numpad6": KEY_KP_6, "Numpad7": KEY_KP_7, "Numpad8": KEY_KP_8,
	"Numpad9": KEY_KP_9,
}

const MOUSE_BUTTONS := {
	"Left": MOUSE_BUTTON_LEFT, "Right": MOUSE_BUTTON_RIGHT,
	"Middle": MOUSE_BUTTON_MIDDLE, "WheelUp": MOUSE_BUTTON_WHEEL_UP,
	"WheelDown": MOUSE_BUTTON_WHEEL_DOWN,
}


## The host keycode of `key_name`, or KEY_NONE after input.unknown_key.
## `where` names the JSON field for the error message.
static func keycode(key_name: String, where: String) -> int:
	if KEYS.has(key_name):
		return KEYS[key_name]
	push_error(
		"%s: %s '%s' is not a key name. See the api manifest, Input keys (ADR 0090)."
		% [EngineError.INPUT_UNKNOWN_KEY, where, key_name]
	)
	return KEY_NONE


## The host button index of `button_name`, or 0 after input.unknown_key.
static func mouse_button(button_name: String, where: String) -> int:
	if MOUSE_BUTTONS.has(button_name):
		return MOUSE_BUTTONS[button_name]
	push_error(
		"%s: %s '%s' is not a mouse button name. The names are: %s (ADR 0090)."
		% [EngineError.INPUT_UNKNOWN_KEY, where, button_name, ", ".join(MOUSE_BUTTONS.keys())]
	)
	return 0
