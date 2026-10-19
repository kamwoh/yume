// The spec key names (ADR 0090) as browser KeyboardEvent.code values.
// Mirrors input_keys.gd. A browser reports physical keys, as Godot does.

const NAMED: Record<string, string[]> = {
  Up: ["ArrowUp"],
  Down: ["ArrowDown"],
  Left: ["ArrowLeft"],
  Right: ["ArrowRight"],
  Space: ["Space"],
  Enter: ["Enter", "NumpadEnter"],
  Escape: ["Escape"],
  Tab: ["Tab"],
  Shift: ["ShiftLeft", "ShiftRight"],
  Ctrl: ["ControlLeft", "ControlRight"],
  Alt: ["AltLeft", "AltRight"],
  Backspace: ["Backspace"],
};

/** The KeyboardEvent.code values of one spec key name, or [] for an unknown name. */
export function codesOf(name: string): string[] {
  if (name in NAMED) return NAMED[name];
  if (/^[A-Z]$/.test(name)) return [`Key${name}`];
  if (/^[0-9]$/.test(name)) return [`Digit${name}`];
  if (/^F([1-9]|1[0-2])$/.test(name)) return [name];
  if (/^Numpad[0-9]$/.test(name)) return [name];
  return [];
}

/** Godot's built-in UI actions, which screens and overlays use (ui_accept, ui_cancel, ui_up ...). */
export const UI_ACTIONS: Record<string, string[]> = {
  ui_accept: ["Enter", "Space"],
  ui_select: ["Space"],
  ui_cancel: ["Escape"],
  ui_up: ["Up"],
  ui_down: ["Down"],
  ui_left: ["Left"],
  ui_right: ["Right"],
};

/** A map from KeyboardEvent.code to the actions that it drives, the built-in UI actions too. */
export function codeToActions(actionKeys: Map<string, string[]>): Map<string, string[]> {
  const out = new Map<string, string[]>();
  const all = new Map(actionKeys);
  for (const [a, keys] of Object.entries(UI_ACTIONS)) if (!all.has(a)) all.set(a, keys);
  for (const [action, keys] of all) {
    for (const k of keys) {
      for (const code of codesOf(k)) {
        if (!out.has(code)) out.set(code, []);
        out.get(code)!.push(action);
      }
    }
  }
  return out;
}

/** InputKeys.mouse_button names as MouseEvent.button values. The wheel is not a button here. */
const MOUSE: Record<string, number> = { Left: 0, Middle: 1, Right: 2 };

/** A map from MouseEvent.button to the actions that it drives. */
export function buttonToActions(actionMouse: Map<string, string[]>): Map<number, string[]> {
  const out = new Map<number, string[]>();
  for (const [action, names] of actionMouse) {
    for (const n of names) {
      const b = MOUSE[n];
      if (b === undefined) continue;
      if (!out.has(b)) out.set(b, []);
      out.get(b)!.push(action);
    }
  }
  return out;
}
