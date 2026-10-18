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

/** A map from KeyboardEvent.code to the actions that it drives. */
export function codeToActions(actionKeys: Map<string, string[]>): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const [action, keys] of actionKeys) {
    for (const k of keys) {
      for (const code of codesOf(k)) {
        if (!out.has(code)) out.set(code, []);
        out.get(code)!.push(action);
      }
    }
  }
  return out;
}
