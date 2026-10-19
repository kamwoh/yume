// Settings (ADR 0013). Mirrors settings_manager.gd: settings_schema.json
// gives each setting a type, a default and an `apply` effect chain. The
// chain runs for every setting at boot, and again for one setting when
// its value changes. In a chain, the literal string "value" becomes the
// setting's value. Godot keeps the values in user://settings.cfg. This
// host keeps them in localStorage, one entry for each game.
import { apply } from "../effects.ts";
import { type Dict, type Value, isDict } from "../value.ts";
import type { World } from "../world.ts";

export class Settings {
  private schema: Dict;
  private byKey = new Map<string, Dict>();
  private values = new Map<string, Value>();
  private world: () => World;
  private storageKey: string;

  constructor(schema: Dict, world: () => World, game: string) {
    this.schema = schema;
    this.world = world;
    this.storageKey = `yume.settings.${game}`;
    for (const cat of this.categories()) {
      for (const s of Array.isArray(cat.settings) ? cat.settings : []) {
        if (isDict(s) && typeof s.key === "string" && s.key !== "") this.byKey.set(s.key, { ...s, _category: String(cat.id ?? "general") });
      }
    }
    // SettingsManager._fill_defaults: the stored value, else the default.
    let stored: Dict = {};
    try {
      const raw = localStorage.getItem(this.storageKey);
      if (raw) stored = JSON.parse(raw);
    } catch {
      // No storage: the defaults hold for this page.
    }
    for (const [k, s] of this.byKey) {
      const sec = stored[String(s._category)];
      const v = isDict(sec) && k in sec ? sec[k] : (s.default ?? null);
      this.values.set(k, clampValue(s, v));
    }
  }

  categories(): Dict[] {
    return (Array.isArray(this.schema.categories) ? this.schema.categories : []).filter(isDict);
  }

  get(key: string): Value {
    return this.values.get(key) ?? null;
  }

  /** SettingsManager.set_value: clamp, store, then run the setting's apply chain. */
  set(key: string, value: Value): void {
    const s = this.byKey.get(key);
    if (!s) {
      console.warn(`[settings] unknown setting key '${key}'`);
      return;
    }
    const v = clampValue(s, value);
    this.values.set(key, v);
    this.save();
    this.runApply(s, v);
  }

  /** SettingsManager.apply_all: every apply chain, once at boot. */
  applyAll(): void {
    for (const [k, s] of this.byKey) this.runApply(s, this.values.get(k) ?? null);
  }

  private runApply(s: Dict, value: Value): void {
    const env = this.world().env;
    for (const eff of Array.isArray(s.apply) ? s.apply : []) {
      if (!isDict(eff)) continue;
      const resolved: Dict = {};
      for (const k of Object.keys(eff)) resolved[k] = eff[k] === "value" ? value : eff[k];
      apply(resolved, env, { _rule_id: `settings:${String(s.key ?? "")}` });
    }
  }

  private save(): void {
    const out: Dict = {};
    for (const [k, s] of this.byKey) {
      const sec = String(s._category);
      if (!isDict(out[sec])) out[sec] = {};
      (out[sec] as Dict)[k] = this.values.get(k) ?? null;
    }
    try {
      localStorage.setItem(this.storageKey, JSON.stringify(out));
    } catch {
      // No storage: the value holds for this page.
    }
  }
}

/** SettingsManager._clamp_value. */
export function clampValue(s: Dict, value: unknown): Value {
  switch (String(s.type ?? "")) {
    case "slider":
      return Math.min(Math.max(Number(value), Number(s.min ?? 0)), Number(s.max ?? 1));
    case "bool":
      return Boolean(value);
    case "enum": {
      const opts = Array.isArray(s.options) ? s.options : [];
      return opts.includes(value as Value) ? (value as Value) : (opts[0] ?? null);
    }
    case "key_binding":
      return String(value);
  }
  return value as Value;
}

/** ScreenFlow._populate_one_settings_renderer: a header for each category, then one row for each setting. */
export function buildSettingsRows(host: HTMLElement, settings: Settings, text: (s: unknown) => string): void {
  for (const cat of settings.categories()) {
    const h = document.createElement("div");
    h.textContent = text(cat.label ?? cat.id ?? "");
    h.style.cssText = "font-size:24px;color:#fdd068;text-shadow:0 0 3px #000";
    host.appendChild(h);
    for (const s of Array.isArray(cat.settings) ? cat.settings : []) if (isDict(s)) row(host, s, settings, text);
  }
}

/** ScreenFlow._build_setting_row: a 220 px label, then the control of the setting's type. */
function row(host: HTMLElement, s: Dict, settings: Settings, text: (s: unknown) => string): void {
  const key = String(s.key ?? "");
  if (key === "") return;
  const r = document.createElement("div");
  r.style.cssText = "display:flex;gap:16px;align-items:center";
  const lbl = document.createElement("div");
  lbl.textContent = text(s.label ?? key);
  lbl.style.cssText = "min-width:220px;text-shadow:0 0 3px #000";
  r.appendChild(lbl);
  const cur = settings.get(key);
  const btnCss = "background:#2b2b33;border:1px solid #4a4a55;border-radius:3px;padding:4px 10px;color:#e0e0e0;font:inherit;pointer-events:auto";
  let ctrl: HTMLElement;
  switch (String(s.type ?? "")) {
    case "slider": {
      const sl = document.createElement("input");
      sl.type = "range";
      sl.min = String(s.min ?? 0);
      sl.max = String(s.max ?? 1);
      sl.step = String(s.step ?? 0.05);
      sl.value = String(cur);
      sl.style.cssText = "width:220px;pointer-events:auto";
      sl.addEventListener("input", () => settings.set(key, Number(sl.value)));
      ctrl = sl;
      break;
    }
    case "bool": {
      // A toggle button that says On or Off, as the reference (2026-10-16).
      const b = document.createElement("button");
      let on = Boolean(cur);
      b.textContent = on ? "On" : "Off";
      b.style.cssText = `${btnCss};min-width:120px;height:30px`;
      b.addEventListener("click", () => {
        on = !on;
        b.textContent = on ? "On" : "Off";
        settings.set(key, on);
      });
      ctrl = b;
      break;
    }
    case "enum": {
      const sel = document.createElement("select");
      const opts = Array.isArray(s.options) ? s.options : [];
      opts.forEach((o, i) => {
        const op = document.createElement("option");
        op.value = String(i);
        op.textContent = text(String(o));
        if (o === cur) op.selected = true;
        sel.appendChild(op);
      });
      sel.style.cssText = btnCss;
      sel.addEventListener("change", () => settings.set(key, opts[Number(sel.value)] ?? null));
      ctrl = sel;
      break;
    }
    case "key_binding": {
      // Phase A of the reference: the current key, read-only.
      const kb = document.createElement("button");
      kb.textContent = String(cur);
      kb.disabled = true;
      kb.style.cssText = `${btnCss};opacity:0.6`;
      ctrl = kb;
      break;
    }
    default:
      ctrl = document.createElement("div");
      ctrl.textContent = "(unknown setting type)";
  }
  r.appendChild(ctrl);
  host.appendChild(r);
}
