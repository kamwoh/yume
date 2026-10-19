// The screen stack of the shell (ADR 0011), with no DOM. Mirrors
// screen_flow.gd: the push and pop of screens, @previous and @root,
// refresh_screen, screen_mark and screen_restore (ADR 0077), the global
// inputs and the effect dispatch of a control. It also expands each `list`
// element into its rows (ControlFactory._build_list, ADR 0076).
//
// The viewer draws this stack (viewer/shell.ts), and the scenario runner
// clicks its buttons (scenario.ts). So a live game and a headless scenario
// read one model, as Godot's ScreenFlow serves both.
//
// World state that the stack owns, as in the reference: current_screen and
// screen_freeze_world.
import { apply } from "./effects.ts";
import type { Entity } from "./entity.ts";
import { run } from "./query.ts";
import { type Dict, isDict } from "./value.ts";
import type { World } from "./world.ts";

/** One open screen. `elements` holds the screen's elements with each list expanded into `_rows`. */
export type ScreenEntry = { id: string; spec: Dict; elements: Dict[]; loadCount: number };

/** The view of the stack: the viewer draws it. A headless run has none. */
export interface ScreenView {
  /** A screen opened on top of the stack. */
  pushed(entry: ScreenEntry): void;
  /** A screen left the stack. */
  removed(entry: ScreenEntry): void;
  /** The rows of an open screen changed (World.world_loaded). Draw it again. */
  rebuilt(entry: ScreenEntry): void;
  /** Any other shell record: a toast, an overlay, a fade, audio. Return false to stop the drain (reload_scene). */
  event(ev: Dict): boolean | void;
}

/** ControlFactory.LIST_DEFAULT_LIMIT. */
const LIST_DEFAULT_LIMIT = 50;

/** The element types that are a BaseButton in the reference, so a click selector can match them. */
const PRESSABLE = ["button", "checkbox", "option_button"];

export class ScreenFlow {
  readonly stack: ScreenEntry[] = [];
  readonly cfg: Dict;
  view: ScreenView | null = null;
  private world: () => World;
  private strings: Dict;
  private screens = new Map<string, Dict>();
  /** ScreenFlow._screen_marks: the stack depth at each level_call. */
  private marks: number[] = [];

  constructor(world: () => World, cfg: Dict, strings: Dict) {
    this.world = world;
    this.cfg = cfg;
    this.strings = strings;
    for (const s of Array.isArray(cfg.screens) ? cfg.screens : []) if (isDict(s) && "id" in s) this.screens.set(String(s.id), s);
  }

  /** ScreenFlow._ready: push the starting screen, so a title shows before the first tick. */
  start(): void {
    const first = String(this.cfg.starting_screen ?? "");
    if (this.screens.has(first)) this.push(first, false);
    else this.applyActive();
  }

  get currentScreen(): string {
    return this.stack.length > 0 ? this.stack[this.stack.length - 1].id : "";
  }

  /**
   * ScreenFlow._drain_screen_events. The stack takes the screen records, and
   * the view gets every other record in order. Then each open list builds
   * its rows again if the world loaded since (World.world_loaded).
   */
  drain(): void {
    const env = this.world().env;
    // One snapshot, as in the reference: a record that the drain itself writes waits for the next drain.
    const events = [...env.shellEvents];
    env.shellEvents.length = 0;
    for (const ev of events) {
      switch (String(ev.type ?? "")) {
        case "transition_screen": {
          const target = String(ev.target ?? "");
          if (target === "@previous") this.pop();
          else if (target === "@root") this.popAll();
          else if (this.screens.has(target)) this.push(target, this.screens.get(target)!.modal === true);
          else console.warn(`[screen_flow] transition to unknown screen '${target}'`);
          break;
        }
        case "refresh_screen":
          this.refreshTop();
          break;
        case "screen_mark":
          this.marks.push(this.stack.length);
          break;
        case "screen_restore": {
          // Pop back to the depth of the matching mark, not to an empty stack:
          // in a menu-driven game the base screen IS the town view.
          const want = this.marks.length > 0 ? this.marks.pop()! : 0;
          for (let guard = 0; this.stack.length > want && guard < 32; guard++) this.pop();
          break;
        }
        default:
          if (this.view?.event(ev) === false) {
            // reload_scene: the rest of the chain dies with the scene.
            env.shellEvents.length = 0;
            return;
          }
      }
    }
    this.refreshLists();
  }

  /** ScreenFlow._dispatch_effects: a control's effect chain runs at once, then the stack drains what it wrote. */
  dispatch(effects: unknown): void {
    if (!Array.isArray(effects)) return;
    const w = this.world();
    for (const e of effects) if (isDict(e)) apply(e, w.env, { _rule_id: "screen_flow", _source: "ui" });
    w.scheduler.flush();
    this.drain();
  }

  /**
   * ScreenFlow._handle_global_inputs: a press edge fires on_press when
   * if_screen names the top screen ("" = none). The edges are read once for
   * each action, before any entry fires: a paired toggle needs both halves
   * to see one press.
   */
  globalInputs(edges: Set<string>): void {
    const globals = Array.isArray(this.cfg.global_inputs) ? this.cfg.global_inputs : [];
    const current = this.currentScreen;
    const fired: unknown[] = [];
    for (const g of globals) {
      if (!isDict(g) || !edges.has(String(g.action ?? ""))) continue;
      if (String(g.if_screen ?? "") !== current) continue;
      fired.push(g.on_press);
    }
    for (const effects of fired) this.dispatch(effects);
  }

  /**
   * StepRunner._find_controls: the pressable controls of every open screen
   * that match `sel` by `id` or by its shown `text`, lowest screen first.
   * Hidden and disabled controls match too, as in the reference.
   */
  findControls(sel: Dict): Dict[] {
    const out: Dict[] = [];
    const walk = (nodes: unknown[]): void => {
      for (const n of nodes) {
        if (!isDict(n)) continue;
        if (PRESSABLE.includes(String(n.type ?? ""))) {
          const byId = "id" in sel && String(n.id ?? "") === String(sel.id);
          const byText = "text" in sel && this.text(n.text ?? "") === String(sel.text);
          if (byId || byText) out.push(n);
        }
        if (Array.isArray(n.children)) walk(n.children);
        if (Array.isArray(n._rows)) walk(n._rows);
      }
    };
    for (const entry of this.stack) walk(entry.elements);
    return out;
  }

  /** Button.pressed: a button runs its on_click chain. The other pressable types run nothing on a press. */
  press(control: Dict): void {
    if (String(control.type ?? "") === "button" && control.on_click !== undefined) this.dispatch(control.on_click);
  }

  /** `@strings.a.b` → ui/strings.json. A number shows as an integer (ControlFactory._resolve_text). */
  text(v: unknown): string {
    if (typeof v === "number") return String(Math.trunc(v));
    const s = String(v ?? "");
    if (!s.startsWith("@strings.")) return s;
    let cur: unknown = this.strings;
    for (const seg of s.slice("@strings.".length).split(".")) {
      if (!isDict(cur) || !(seg in cur)) return s;
      cur = cur[seg];
    }
    return typeof cur === "string" ? cur : s;
  }

  /** quit_app in a page: the stack empties. */
  popAll(): void {
    while (this.stack.length > 0) this.pop();
  }

  // ------------------------------------------------------------ the stack

  /** ScreenFlow._push_screen: a modal screen stacks, any other replaces the stack. */
  private push(id: string, modal: boolean): void {
    const spec = this.screens.get(id)!;
    if (!modal) while (this.stack.length > 0) this.view?.removed(this.stack.pop()!);
    const w = this.world();
    const entry: ScreenEntry = { id, spec, elements: expandElements(spec.elements, w), loadCount: w.loadCount };
    this.stack.push(entry);
    this.view?.pushed(entry);
    this.applyActive();
  }

  /** ScreenFlow._pop_screen. */
  private pop(): void {
    const top = this.stack.pop();
    if (!top) return;
    this.view?.removed(top);
    this.applyActive();
  }

  /** ScreenFlow._refresh_top_screen: build the top screen again, the stack below it untouched. */
  private refreshTop(): void {
    const top = this.stack.pop();
    if (!top || !this.screens.has(top.id)) return;
    this.view?.removed(top);
    this.push(top.id, true);
  }

  /** ControlFactory._build_list: each open list queries again on World.world_loaded. */
  private refreshLists(): void {
    const w = this.world();
    for (const entry of this.stack) {
      if (entry.loadCount === w.loadCount) continue;
      entry.loadCount = w.loadCount;
      if (!hasList(entry.spec.elements)) continue;
      entry.elements = expandElements(entry.spec.elements, w);
      this.view?.rebuilt(entry);
    }
  }

  /** ScreenFlow._apply_active_screen. */
  private applyActive(): void {
    const ws = this.world().env.world;
    const top = this.stack[this.stack.length - 1];
    ws.current_screen = top ? top.id : "";
    ws.screen_freeze_world = top && top.spec.freeze_world === true ? 1 : 0;
  }
}

function hasList(nodes: unknown): boolean {
  if (!Array.isArray(nodes)) return false;
  return nodes.some((n) => isDict(n) && (n.type === "list" || hasList(n.children)));
}

/** A copy of `nodes` where each `list` carries `_rows`: its expanded item copies, or its `empty` element. */
export function expandElements(nodes: unknown, w: World): Dict[] {
  if (!Array.isArray(nodes)) return [];
  const out: Dict[] = [];
  for (const n of nodes) {
    if (!isDict(n)) continue;
    const copy: Dict = { ...n };
    if (Array.isArray(n.children)) copy.children = expandElements(n.children, w);
    if (n.type === "list") copy._rows = expandElements(listRows(n, w), w);
    out.push(copy);
  }
  return out;
}

/**
 * ControlFactory._populate_list (ADR 0076): one copy of `item` for each
 * entity that `from` matches, at most `limit`. In the copy, "row" or
 * "row.id" is the entity id, "row.state.f" and "row.properties.f" its
 * values, and "row_edge.f" a field of its `edge_of` relation edge. Under
 * `binds`, a "row.state.f" stays live as "<id>.f". Each `id` gets the
 * suffix "__<id>". No match gives `empty`.
 */
export function listRows(spec: Dict, w: World): Dict[] {
  const item = isDict(spec.item) ? spec.item : null;
  const from = isDict(spec.from) ? spec.from : null;
  if (!item || !from) {
    console.warn("[screen_flow] a list needs both `from` (a query) and `item` (a template): rendering nothing");
    return [];
  }
  let matches = run(from, w.env, {});
  const limit = Math.trunc(Number(spec.limit ?? LIST_DEFAULT_LIMIT));
  if (limit > 0 && matches.length > limit) {
    // Truncation is never silent: a list that drops rows reads as "that is everything".
    console.warn(`[screen_flow] list: the query matched ${matches.length} entities, rendering ${limit} (limit)`);
    matches = matches.slice(0, limit);
  }
  if (matches.length === 0) return isDict(spec.empty) ? [spec.empty] : [];
  const bind = String(spec.bind ?? "row");
  const edgeOf = isDict(spec.edge_of) ? spec.edge_of : null;
  return matches.map((ent) => substituteRow(item, bind, ent, w, edgeOf, false) as Dict);
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
