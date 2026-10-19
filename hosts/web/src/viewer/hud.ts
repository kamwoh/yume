// The HUD as HTML. Mirrors hud_builder.gd for panels of `label`, `spacer`,
// `progress_bar`, `crosshair`, `minimap` and `slot_grid` elements, the
// controls hint and the win panel. A HUD `list` is not in this host yet.
// It is skipped, with one console note.
import type { Entity } from "../entity.ts";
import { type Dict, isDict } from "../value.ts";
import type { World } from "../world.ts";
import { type LiveWidget, Minimap, SlotGrid } from "./widgets.ts";

type BoundLabel = { el: HTMLElement; binds: string; format: string; phases: string[] };
type BoundBar = { fill: HTMLElement; binds: string; max: number; lerp: [string, string] | null };

const ANCHORS: Record<string, string> = {
  "top-left": "top:12px;left:12px",
  "top-center": "top:12px;left:50%;transform:translateX(-50%);text-align:center",
  "top-right": "top:12px;right:12px;text-align:right",
  "center-left": "top:50%;left:12px;transform:translateY(-50%)",
  center: "top:50%;left:50%;transform:translate(-50%,-50%);text-align:center",
  "center-right": "top:50%;right:12px;transform:translateY(-50%);text-align:right",
  "bottom-left": "bottom:12px;left:12px",
  "bottom-center": "bottom:12px;left:50%;transform:translateX(-50%);text-align:center",
  "bottom-right": "bottom:12px;right:12px;text-align:right",
};

export class Hud {
  private labels: BoundLabel[] = [];
  private bars: BoundBar[] = [];
  private widgets: LiveWidget[] = [];
  private win: { binds: string; op: string; value: unknown; el: HTMLElement } | null = null;
  private strings: Dict;

  constructor(layer: HTMLElement, hud: Dict, strings: Dict) {
    this.strings = strings;
    for (const panel of Array.isArray(hud.panels) ? hud.panels : []) {
      if (!isDict(panel)) continue;
      const box = div(layer, `position:absolute;${ANCHORS[String(panel.anchor ?? "top-left")] ?? ANCHORS["top-left"]}`);
      for (const el of Array.isArray(panel.elements) ? panel.elements : []) {
        if (!isDict(el)) continue;
        const type = String(el.type ?? "");
        if (type === "spacer") div(box, `height:${Number(el.height ?? 8)}px`);
        else if (type === "label") {
          const node = div(box, `font-size:${Number(el.size ?? 16)}px;color:${String(el.color ?? "#ffffff")};white-space:pre`);
          node.textContent = this.text(String(el.text ?? ""));
          if ("binds" in el) this.labels.push({ el: node, binds: String(el.binds), format: String(el.format ?? "{}"), phases: Array.isArray(el.format_phases) ? el.format_phases.map(String) : [] });
        } else if (type === "progress_bar") {
          // A ProgressBar of width × height (280 × 16), filled to value / max. color_lerp tints it from low to high.
          const bar = div(box, `width:${Number(el.width ?? 280)}px;height:${Number(el.height ?? 16)}px;background:rgba(26,26,31,0.75);border-radius:3px;overflow:hidden;margin:2px 0`);
          const fill = div(bar, "height:100%;width:0;background:#c8c8c8;border-radius:3px");
          const lerp = Array.isArray(el.color_lerp) && el.color_lerp.length === 2 ? ([String(el.color_lerp[0]), String(el.color_lerp[1])] as [string, string]) : null;
          this.bars.push({ fill, binds: String(el.binds ?? ""), max: Number(el.max ?? 100) || 100, lerp });
        } else if (type === "crosshair") {
          // A centered glyph. The third-person aim point (crosshair_screen_x/y) comes with the camera slice.
          const ch = div(box, `font-size:${Number(el.size ?? 28)}px;color:${String(el.color ?? "#ffffff")};line-height:1;text-shadow:0 0 3px #000,0 0 3px #000`);
          ch.textContent = String(el.glyph ?? "+");
        } else if (type === "minimap" || type === "slot_grid") {
          const w = type === "minimap" ? new Minimap(el) : new SlotGrid(el);
          box.appendChild(w.el);
          this.widgets.push(w);
        } else console.info(`[hud] element type '${type}' is not in this host yet, skipped`);
      }
    }
    const hint = this.text(String(hud.controls_hint ?? ""));
    if (hint !== "") div(layer, "position:absolute;bottom:12px;left:12px;font-size:13px;color:#e6e6e6;opacity:0.8").textContent = hint;
    if (isDict(hud.win)) {
      const el = div(
        layer,
        "position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);display:none;padding:24px 36px;" +
          "background:rgba(0,0,0,0.75);color:#ffe9a8;font-size:26px;text-align:center;white-space:pre;border-radius:6px",
      );
      el.textContent = this.text(String(hud.win.message ?? ""));
      this.win = { binds: String(hud.win.binds ?? ""), op: String(hud.win.op ?? ">="), value: hud.win.value ?? 1, el };
    }
  }

  update(world: World): void {
    for (const l of this.labels) {
      const v = resolveBinding(world, l.binds);
      // A missing value keeps the old text, as in the reference.
      if (v === null || v === undefined) continue;
      // HudBuilder: format_phases picks one string by a number in [0, 1].
      if (l.phases.length > 0 && typeof v === "number") {
        l.el.textContent = l.phases[Math.min(Math.max(Math.trunc(v * l.phases.length), 0), l.phases.length - 1)];
        continue;
      }
      l.el.textContent = this.text(l.format).replace("{}", formatValue(v));
    }
    for (const w of this.widgets) w.update(world, (p) => resolveBinding(world, p));
    for (const b of this.bars) {
      const v = Number(resolveBinding(world, b.binds));
      if (!Number.isFinite(v)) continue;
      const k = Math.min(Math.max(v / b.max, 0), 1);
      b.fill.style.width = `${k * 100}%`;
      if (b.lerp) b.fill.style.background = lerpColor(b.lerp[0], b.lerp[1], k);
    }
    if (this.win) {
      const v = resolveBinding(world, this.win.binds);
      this.win.el.style.display = v !== null && v !== undefined && compare(Number(v), this.win.op, Number(this.win.value)) ? "block" : "none";
    }
  }

  /** `@strings.a.b` → ui/strings.json[a][b]. Other text stays as it is. */
  private text(s: string): string {
    if (!s.startsWith("@strings.")) return s;
    let cur: unknown = this.strings;
    for (const seg of s.slice("@strings.".length).split(".")) {
      if (!isDict(cur) || !(seg in cur)) return s;
      cur = cur[seg];
    }
    return typeof cur === "string" ? cur : s;
  }
}

/** GameShell._resolve_binding: world.<field>, or <tag or id>.<state field>, with an optional [N]. */
export function resolveBinding(world: World, path: string): unknown {
  const parts = path.split(".");
  if (parts.length < 2) return null;
  const m = /^(.*)\[(\d+)\]$/.exec(parts[1]);
  const field = m ? m[1] : parts[1];
  let value: unknown;
  if (parts[0] === "def") {
    // "def.<def_id>.<path>", or "def.@<root>.<field>.<path>" where the binding <root>.<field> names the def.
    let defId = field;
    let start = 2;
    if (field.startsWith("@") && parts.length >= 3) {
      const r = resolveBinding(world, `${field.slice(1)}.${parts[2]}`);
      if (typeof r !== "string" || r === "") return null;
      defId = r;
      start = 3;
    }
    let cur: unknown = world.env.defs.get(defId);
    for (const seg of parts.slice(start)) {
      if (!isDict(cur) || !(seg in cur)) return null;
      cur = cur[seg];
    }
    return cur ?? null;
  }
  if (parts[0] === "world") value = world.env.world[field] ?? null;
  else {
    const ent = findByTag(world, parts[0]);
    if (!ent) return null;
    value = ent.getState(field, null);
  }
  if (m) return Array.isArray(value) ? (value[Number(m[2])] ?? "") : "";
  return value;
}

function findByTag(world: World, tag: string): Entity | null {
  for (const e of world.env.entities.values()) if (e.hasTag(tag)) return e;
  return world.env.entities.get(tag) ?? null;
}

/** ControlFactory.format_bound_value: a float shows as an integer. Every JSON number is a float there. */
function formatValue(v: unknown): string {
  return typeof v === "number" ? String(Math.trunc(v)) : String(v);
}

function lerpColor(a: string, b: string, k: number): string {
  const rgb = (c: string) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
  const [x, y] = [rgb(a), rgb(b)];
  return `rgb(${x.map((v, i) => Math.round(v + (y[i] - v) * k)).join(",")})`;
}

function compare(a: number, op: string, b: number): boolean {
  switch (op) {
    case ">=": return a >= b;
    case ">": return a > b;
    case "<=": return a <= b;
    case "<": return a < b;
    case "==": return a === b;
    case "!=": return a !== b;
  }
  return false;
}

function div(parent: HTMLElement, css: string): HTMLElement {
  const d = document.createElement("div");
  d.style.cssText = css;
  parent.appendChild(d);
  return d;
}
