// Two UI widgets that the HUD and screens share. Mirrors:
//   minimap_widget.gd   colored dots of entities by tag, a bigger player
//                       dot, and an optional view cone
//   control_factory.gd  _build_slot_grid and update_slot_grid: a grid of
//                       cells bound to an array, with an active cell
import type { Entity } from "../entity.ts";
import { type Dict, isDict } from "../value.ts";
import type { World } from "../world.ts";
import { cssColor } from "./ui.ts";

/** A widget that redraws from world state each frame. */
export interface LiveWidget {
  el: HTMLElement;
  update(world: World, resolve: (path: string) => unknown): void;
}

/** MinimapWidget: size [w, h], world_bounds [x0, z0, x1, z1] or a fit to the entities with 5% padding. */
export class Minimap implements LiveWidget {
  el: HTMLCanvasElement;
  private w: number;
  private h: number;
  private bounds: number[] | null;
  private bg: string;
  private border: string;
  private tags: [string, string][] = [];
  private playerTag: string;
  private dot: number;
  private playerDot: number;
  private cone: { radius: number; half: number; color: string } | null;

  constructor(cfg: Dict) {
    const size = Array.isArray(cfg.size) && cfg.size.length === 2 ? cfg.size.map(Number) : [180, 180];
    [this.w, this.h] = size;
    this.el = document.createElement("canvas");
    this.el.width = this.w;
    this.el.height = this.h;
    this.el.style.cssText = `width:${this.w}px;height:${this.h}px;display:block`;
    this.bounds = Array.isArray(cfg.world_bounds) && cfg.world_bounds.length === 4 ? cfg.world_bounds.map(Number) : null;
    this.bg = cssColor(String(cfg.background ?? "#0c0a08"));
    this.border = cssColor(String(cfg.border ?? "#807060"));
    // The order of tag_colors is the order of the first-match test. "_" keys are comments.
    if (isDict(cfg.tag_colors)) for (const k of Object.keys(cfg.tag_colors)) if (!k.startsWith("_")) this.tags.push([k, cssColor(String(cfg.tag_colors[k]))]);
    this.playerTag = String(cfg.player_tag ?? "player");
    this.dot = Number(cfg.dot_radius ?? 2);
    this.playerDot = Number(cfg.player_radius ?? 4);
    const coneColor = cssColor(String(cfg.view_cone_color ?? "#ffd040"), Number(cfg.view_cone_alpha ?? 0.25));
    this.cone = cfg.show_view_cone === true ? { radius: Number(cfg.view_cone_radius ?? 30), half: Number(cfg.view_cone_half_angle ?? 0.524), color: coneColor } : null;
  }

  update(world: World): void {
    const g = this.el.getContext("2d")!;
    g.fillStyle = this.bg;
    g.fillRect(0, 0, this.w, this.h);
    g.strokeStyle = this.border;
    g.lineWidth = 1.5;
    g.strokeRect(0.75, 0.75, this.w - 1.5, this.h - 1.5);
    const ents = [...world.env.entities.values()];
    const b = this.bounds ?? fitBounds(ents);
    if (!b) return;
    const bw = Math.max(b[2] - b[0], 0.001);
    const bh = Math.max(b[3] - b[1], 0.001);
    let player: { x: number; y: number; facing: number } | null = null;
    for (const e of ents) {
      const p = e.planarPosition();
      const x = ((p.x - b[0]) / bw) * this.w;
      const y = ((p.y - b[1]) / bh) * this.h;
      if (e.hasTag(this.playerTag)) {
        player = { x, y, facing: Number(e.getState("facing", 0)) };
        continue;
      }
      const c = this.tags.find(([t]) => e.hasTag(t));
      if (!c) continue;
      g.fillStyle = c[1];
      g.beginPath();
      g.arc(x, y, this.dot, 0, Math.PI * 2);
      g.fill();
    }
    if (!player) return;
    if (this.cone) {
      // facing 0 looks to -Z (screen up). A larger facing turns the view to the left.
      const fwd = -player.facing - Math.PI / 2;
      g.fillStyle = this.cone.color;
      g.beginPath();
      g.moveTo(player.x, player.y);
      g.lineTo(player.x + Math.cos(fwd - this.cone.half) * this.cone.radius, player.y + Math.sin(fwd - this.cone.half) * this.cone.radius);
      g.lineTo(player.x + Math.cos(fwd + this.cone.half) * this.cone.radius, player.y + Math.sin(fwd + this.cone.half) * this.cone.radius);
      g.fill();
    }
    g.fillStyle = this.tags.find(([t]) => t === this.playerTag)?.[1] ?? "#ffd040";
    g.beginPath();
    g.arc(player.x, player.y, this.playerDot, 0, Math.PI * 2);
    g.fill();
  }
}

/** MinimapWidget._resolve_bounds: the entity extent, padded 5% on each side. */
export function fitBounds(ents: Entity[]): number[] | null {
  if (ents.length === 0) return null;
  let x0 = Infinity, z0 = Infinity, x1 = -Infinity, z1 = -Infinity;
  for (const e of ents) {
    const p = e.planarPosition();
    x0 = Math.min(x0, p.x);
    z0 = Math.min(z0, p.y);
    x1 = Math.max(x1, p.x);
    z1 = Math.max(z1, p.y);
  }
  const px = (x1 - x0) * 0.05;
  const pz = (z1 - z0) * 0.05;
  return [x0 - px, z0 - pz, x1 + px, z1 + pz];
}

/** ControlFactory slot_grid: cell_count cells in `columns`, bound to an array (`binds`) with one active cell (`active_binds`). */
export class SlotGrid implements LiveWidget {
  el: HTMLElement;
  private cfg: Dict;
  private cells: { box: HTMLElement; content: HTMLElement }[] = [];

  constructor(cfg: Dict) {
    this.cfg = cfg;
    const n = Math.trunc(Number(cfg.cell_count ?? 4));
    const cols = Math.max(1, Math.trunc(Number(cfg.columns ?? n)));
    const size = Array.isArray(cfg.cell_size) ? cfg.cell_size.map(Number) : [56, 48];
    const gap = Number(cfg.gap ?? 4);
    this.el = document.createElement("div");
    this.el.style.cssText = `display:grid;grid-template-columns:repeat(${cols}, ${size[0] ?? 56}px);gap:${gap}px`;
    for (let i = 0; i < n; i++) {
      const box = document.createElement("div");
      box.style.cssText = `position:relative;width:${size[0] ?? 56}px;height:${size[1] ?? 48}px;border-radius:3px;box-sizing:border-box;border:${Number(cfg.border_width ?? 2)}px solid`;
      if (cfg.show_index !== false) {
        const idx = document.createElement("div");
        idx.textContent = String(cfg.index_format ?? "{}").replace("{}", String(i + 1));
        idx.style.cssText = `position:absolute;left:4px;top:2px;font-size:${Number(cfg.index_font_size ?? 10)}px;color:${cssColor(String(cfg.index_color ?? "#807060"))};text-shadow:0 0 2px #000`;
        box.appendChild(idx);
      }
      const content = document.createElement("div");
      if (cfg.cell_content_type === "item_icon") content.style.cssText = "position:absolute;inset:4px";
      else {
        content.style.cssText = `position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:${Number(cfg.font_size ?? 14)}px;color:${cssColor(String(cfg.text_color ?? "#e0d0a0"))};text-shadow:0 0 3px #000`;
        content.textContent = String(cfg.empty_text ?? "");
      }
      box.appendChild(content);
      this.el.appendChild(box);
      this.cells.push({ box, content });
    }
  }

  /** ControlFactory.update_slot_grid. An item icon takes the held def's properties.inventory_icon_color. */
  update(_world: World, resolve: (path: string) => unknown): void {
    const c = this.cfg;
    const bv = "binds" in c ? resolve(String(c.binds)) : null;
    const values = Array.isArray(bv) ? bv : [];
    const av = "active_binds" in c ? resolve(String(c.active_binds)) : null;
    const active = av === null || av === undefined ? -1 : Math.trunc(Number(av));
    const fmt = String(c.cell_format ?? "{}");
    const empty = String(c.empty_text ?? "");
    this.cells.forEach(({ box, content }, i) => {
      const on = i === active;
      box.style.background = cssColor(String(on ? (c.bg_active_color ?? "#3a3220") : (c.bg_color ?? "#22201a")));
      box.style.borderColor = cssColor(String(on ? (c.border_active_color ?? "#ffd040") : (c.border_color ?? "#403828")));
      const s = i < values.length ? String(values[i] ?? "") : "";
      if (c.cell_content_type === "item_icon") {
        const col = s === "" ? null : resolve(`def.${s}.properties.inventory_icon_color`);
        const pick = col === null || col === undefined || col === "" ? (c.default_icon_color ?? "#a09080") : col;
        content.style.background = s === "" ? "transparent" : cssColor(String(pick));
      } else content.textContent = s === "" ? empty : fmt.replace("{}", s);
    });
  }
}
