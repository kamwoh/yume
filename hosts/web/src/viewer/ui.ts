// Screen controls as HTML (ADR 0095 phase 4). Mirrors control_factory.gd:
// label, button, vbox, hbox, color_rect, spacer, image and list, with the
// anchors, sizes and offsets of _apply_common. A size or an offset is
// pixels, or a percent of the view ("25%").
//
// settings_renderer takes its rows from settings.ts.
//
// minimap and slot_grid come from widgets.ts.
//
// Not in this host yet: slider, checkbox and option_button as screen
// elements. Each raises one console note.
import type { Entity } from "../entity.ts";
import { evaluate } from "../formula.ts";
import { run } from "../query.ts";
import { type Dict, isDict } from "../value.ts";
import type { World } from "../world.ts";
import { type LiveWidget, Minimap, SlotGrid } from "./widgets.ts";

/** The services a control needs: text lookup, live bindings and the effect dispatcher. */
export type UiContext = {
  world: () => World;
  text: (s: unknown) => string;
  binding: (path: string) => unknown;
  dispatch: (effects: unknown, ctx: Dict) => void;
  assetUrl: (path: string) => string;
  /** settings_renderer fills a box with the rows of settings_schema.json. */
  settingsRows?: (host: HTMLElement) => void;
};

/** A control with visible_if, enabled_if or binds, which the shell updates each frame. */
export type Bound = { el: HTMLElement; cfg: Dict; widget?: LiveWidget };

const warned = new Set<string>();
function note(msg: string): void {
  if (warned.has(msg)) return;
  warned.add(msg);
  console.info(`[ui] ${msg}`);
}

/** Godot's default theme: 16 px text, light grey on a dark button. */
const BASE_CSS = "font-family:'Open Sans',system-ui,sans-serif;font-size:16px;color:#e0e0e0;box-sizing:border-box";

/** ControlFactory.build: one control and its children under `parent`. `inFlow` is true inside a vbox or hbox. */
export function build(spec: Dict, parent: HTMLElement, ui: UiContext, bound: Bound[], inFlow = false): HTMLElement | null {
  const t = String(spec.type ?? "");
  let el: HTMLElement;
  switch (t) {
    case "label":
      el = label(spec, ui);
      break;
    case "button":
      el = button(spec, ui);
      break;
    case "vbox":
    case "hbox":
    case "settings_renderer":
      el = box(t === "hbox" ? "row" : "column", spec);
      if (t === "settings_renderer") {
        if (ui.settingsRows) ui.settingsRows(el);
        else note("this game has no settings_schema.json");
      }
      for (const c of Array.isArray(spec.children) ? spec.children : []) if (isDict(c)) build(c, el, ui, bound, true);
      break;
    case "color_rect": {
      el = document.createElement("div");
      const a = "alpha" in spec ? Number(spec.alpha) : null;
      el.style.background = cssColor(String(spec.color ?? "#000000"), a);
      el.style.pointerEvents = "none";
      break;
    }
    case "spacer":
      el = document.createElement("div");
      el.style.minWidth = `${Number(spec.width ?? 0)}px`;
      el.style.minHeight = `${Number(spec.height ?? 8)}px`;
      break;
    case "image": {
      const img = document.createElement("img");
      img.src = ui.assetUrl(String(spec.texture ?? ""));
      img.style.objectFit = "contain";
      el = img;
      break;
    }
    case "list":
      el = list(spec, ui, bound);
      break;
    case "minimap":
    case "slot_grid": {
      const w = t === "minimap" ? new Minimap(spec) : new SlotGrid(spec);
      el = w.el;
      bound.push({ el, cfg: spec, widget: w });
      break;
    }
    default:
      note(`element type '${t}' is not in this host yet`);
      return null;
  }
  el.style.cssText = `${BASE_CSS};${el.style.cssText}`;
  if ("id" in spec) el.dataset.id = String(spec.id);
  applyCommon(el, spec, parent, inFlow);
  if ("visible_if" in spec || "enabled_if" in spec || "binds" in spec) bound.push({ el, cfg: spec });
  parent.appendChild(el);
  return el;
}

function label(spec: Dict, ui: UiContext): HTMLElement {
  const el = document.createElement("div");
  el.textContent = applyFormat(ui.text(spec.text ?? ""), spec.format, ui);
  if ("font_size" in spec) el.style.fontSize = `${Number(spec.font_size)}px`;
  if ("color" in spec) el.style.color = cssColor(String(spec.color));
  // The outline of the reference: 4 px of black around the glyphs.
  el.style.textShadow = "0 0 3px #000, 0 0 3px #000, 1px 1px 2px #000";
  el.style.whiteSpace = "pre-wrap";
  el.style.textAlign = String(spec.halign ?? "left");
  return el;
}

function button(spec: Dict, ui: UiContext): HTMLElement {
  const b = document.createElement("button");
  b.textContent = ui.text(spec.text ?? "");
  b.style.cssText =
    "background:#2b2b33;border:1px solid #4a4a55;border-radius:3px;padding:4px 10px;cursor:pointer;color:#e0e0e0;pointer-events:auto;outline:none";
  if ("font_size" in spec) b.style.fontSize = `${Number(spec.font_size)}px`;
  if ("color" in spec) b.style.color = cssColor(String(spec.color));
  if ("texture" in spec) {
    b.style.background = `url(${ui.assetUrl(String(spec.texture))}) center/100% 100% no-repeat`;
    b.style.border = "none";
  }
  b.addEventListener("focus", () => (b.style.borderColor = "#d0d0e0"));
  b.addEventListener("blur", () => (b.style.borderColor = "#4a4a55"));
  b.addEventListener("mouseenter", () => !b.disabled && (b.style.filter = "brightness(1.25)"));
  b.addEventListener("mouseleave", () => (b.style.filter = ""));
  const onClick = spec.on_click;
  if (onClick !== undefined) b.addEventListener("click", () => ui.dispatch(onClick, { _source: "button" }));
  return b;
}

function box(dir: "row" | "column", spec: Dict): HTMLElement {
  const el = document.createElement("div");
  el.style.display = "flex";
  el.style.flexDirection = dir;
  // Godot's BoxContainer separation defaults to 4.
  el.style.gap = `${Number(spec.separation ?? 4)}px`;
  if (dir === "column") el.style.alignItems = "stretch";
  return el;
}

/**
 * ControlFactory._build_list (ADR 0076): one copy of `item` for each entity
 * that `from` matches, at most `limit` (50). In the copy, "row" or "row.id"
 * is the entity id, "row.state.f" and "row.properties.f" its values, and
 * "row_edge.f" a field of its `edge_of` relation edge. Under `binds`, a
 * "row.state.f" stays live as "<id>.f". Each `id` gets the suffix "__<id>".
 * No match builds `empty`.
 */
function list(spec: Dict, ui: UiContext, bound: Bound[]): HTMLElement {
  const el = box("column", spec);
  const item = isDict(spec.item) ? spec.item : null;
  const from = isDict(spec.from) ? spec.from : null;
  if (!item || !from) {
    note("a list needs both `from` (a query) and `item` (a template)");
    return el;
  }
  const w = ui.world();
  let matches = run(from, w.env, {});
  const limit = Math.trunc(Number(spec.limit ?? 50));
  if (limit > 0 && matches.length > limit) {
    console.warn(`[ui] list: the query matched ${matches.length} entities, rendering ${limit} (limit)`);
    matches = matches.slice(0, limit);
  }
  if (matches.length === 0) {
    if (isDict(spec.empty)) build(spec.empty, el, ui, bound, true);
    return el;
  }
  const bind = String(spec.bind ?? "row");
  const edgeOf = isDict(spec.edge_of) ? spec.edge_of : null;
  for (const ent of matches) build(substituteRow(item, bind, ent, w, edgeOf, false) as Dict, el, ui, bound, true);
  return el;
}

/** ControlFactory._substitute_row. */
function substituteRow(node: unknown, bind: string, ent: Entity, w: World, edgeOf: Dict | null, underBinds: boolean): unknown {
  if (isDict(node)) {
    const out: Dict = {};
    for (const k of Object.keys(node)) out[k] = substituteRow(node[k], bind, ent, w, edgeOf, k === "binds") as Dict[string];
    if (typeof out.id === "string") out.id = `${out.id}__${ent.id}`;
    return out;
  }
  if (Array.isArray(node)) return node.map((v) => substituteRow(v, bind, ent, w, edgeOf, underBinds));
  if (typeof node !== "string") return node;
  if (node === bind || node === `${bind}.id`) return ent.id;
  if (node.startsWith(`${bind}_edge.`)) {
    if (!edgeOf) return "";
    const rel = String(edgeOf.relation ?? "");
    const [from, to] = "to" in edgeOf ? [ent.id, String(edgeOf.to)] : "from" in edgeOf ? [String(edgeOf.from), ent.id] : ["", ""];
    if (rel === "" || to === "") return "";
    return (w.env.relations.edgeState(rel, from, to) as Dict)[node.slice(bind.length + 6)] ?? "";
  }
  if (node.startsWith(`${bind}.properties.`)) return ent.properties[node.slice(bind.length + 12)] ?? "";
  if (node.startsWith(`${bind}.state.`)) {
    const field = node.slice(bind.length + 7);
    return underBinds ? `${ent.id}.${field}` : ent.getState(field, "");
  }
  return node;
}

/** ControlFactory._apply_format: a `format` with `{}` wraps the text. */
export function applyFormat(text: string, fmt: unknown, ui: UiContext): string {
  if (fmt === undefined || fmt === null) return text;
  const f = ui.text(fmt);
  return f.includes("{}") ? f.replace("{}", text) : text;
}

/** ControlFactory.resolve_pct: pixels, or "25%" of `basis`. */
function pct(v: unknown, basis: number): number {
  if (typeof v === "string") {
    const s = v.trim();
    if (s.endsWith("%")) return (parseFloat(s) / 100) * basis;
    return parseFloat(s) || 0;
  }
  return Number(v ?? 0) || 0;
}

/**
 * ControlFactory._apply_common: anchor, size and offset. Outside a box the
 * control sits at its anchor point, grown from that point as the anchor
 * presets do. Inside a box the box lays it out, and a size is a minimum.
 */
function applyCommon(el: HTMLElement, spec: Dict, parent: HTMLElement, inFlow: boolean): void {
  const vw = innerWidth;
  const vh = innerHeight;
  const hasSize = "width" in spec || "height" in spec;
  if ("width" in spec) el.style[inFlow ? "minWidth" : "width"] = `${pct(spec.width, vw)}px`;
  if ("height" in spec) el.style[inFlow ? "minHeight" : "height"] = `${pct(spec.height, vh)}px`;
  if (inFlow) {
    if (spec.size_flags_h === "expand_fill" || spec.size_flags_h === "expand") el.style.flexGrow = "1";
    return;
  }
  void parent;
  const anchor = String(spec.anchor ?? "").replace(/-/g, "_");
  const ox = pct(spec.x_offset ?? 0, vw);
  const oy = pct(spec.y_offset ?? 0, vh);
  el.style.position = "absolute";
  if (anchor === "fill") {
    el.style.inset = "0";
    return;
  }
  const [ax, ay] = ANCHOR_POINTS[anchor] ?? [0, 0];
  el.style.left = `calc(${ax * 100}% + ${ox}px)`;
  el.style.top = `calc(${ay * 100}% + ${oy}px)`;
  // A centered or end anchor grows the control back over its anchor point.
  el.style.transform = `translate(${-ax * 100}%, ${-ay * 100}%)`;
  if (!hasSize && ax === 0.5) el.style.whiteSpace = el.style.whiteSpace || "nowrap";
}

const ANCHOR_POINTS: Record<string, [number, number]> = {
  top_left: [0, 0],
  top_center: [0.5, 0],
  top_right: [1, 0],
  center_left: [0, 0.5],
  center: [0.5, 0.5],
  center_right: [1, 0.5],
  bottom_left: [0, 1],
  bottom_center: [0.5, 1],
  bottom_right: [1, 1],
};

/** A Godot color string (#rgb, #rrggbb, #rrggbbaa, or a name) as CSS, with an optional alpha. */
export function cssColor(c: string, alpha: number | null = null): string {
  let s = c.trim();
  if (!s.startsWith("#")) return alpha === null ? s : s;
  s = s.slice(1);
  if (s.length === 3) s = s.split("").map((x) => x + x).join("");
  const r = parseInt(s.slice(0, 2), 16);
  const g = parseInt(s.slice(2, 4), 16);
  const b = parseInt(s.slice(4, 6), 16);
  const a = alpha ?? (s.length >= 8 ? parseInt(s.slice(6, 8), 16) / 255 : 1);
  return `rgba(${r},${g},${b},${a})`;
}

/** ScreenFlow._update_bound_elements: visible_if, enabled_if and label `binds`. */
export function updateBound(bound: Bound[], ui: UiContext): void {
  const w = ui.world();
  const ctx = { world: w.env.world };
  for (const { el, cfg, widget } of bound) {
    if (widget) {
      widget.update(w, ui.binding);
      continue;
    }
    if ("visible_if" in cfg) {
      const v = evaluate(String(cfg.visible_if), ctx, w.env);
      el.style.visibility = v === null || v === undefined || Boolean(v) ? "" : "hidden";
    }
    if ("enabled_if" in cfg && el instanceof HTMLButtonElement) {
      const v = evaluate(String(cfg.enabled_if), ctx, w.env);
      el.disabled = !(v === null || v === undefined || Boolean(v));
      el.style.opacity = el.disabled ? "0.45" : "";
      el.style.cursor = el.disabled ? "default" : "pointer";
    }
    if ("binds" in cfg && !(el instanceof HTMLButtonElement)) {
      let v = ui.binding(String(cfg.binds));
      if (v === null || v === undefined) continue;
      if (typeof v === "string" && v.startsWith("@")) v = ui.text(v);
      el.textContent = ui.text(cfg.format ?? "{}").replace("{}", typeof v === "number" ? String(Math.trunc(v)) : String(v));
    }
  }
}
