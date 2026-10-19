// The shell of the viewer (ADR 0095 phase 4): screens, overlays, toasts,
// fades, the hit flash and the camera shake, as HTML over the canvas.
// Mirrors screen_flow.gd (ADR 0011), overlay.gd (ADR 0012) and the event
// drain of game_shell.gd. The core writes each shell effect to
// env.shellEvents (effects.ts). The shell drains that list once each frame.
//
// World state that the shell owns, as in the reference: current_screen,
// screen_freeze_world and overlay_freeze_world. The live clock (live.ts)
// does not tick while either freeze flag is set.
import { apply } from "../effects.ts";
import { type Dict, isDict } from "../value.ts";
import type { World } from "../world.ts";
import { resolveBinding } from "./hud.ts";
import { type Bound, type UiContext, build, cssColor, updateBound } from "./ui.ts";

export type ShellHost = {
  world: () => World;
  /** A reload_scene: boot the game again from its bundle. */
  reload: () => void;
  /** GameShell "shake": the camera shakes by `intensity` for `frames` frames. */
  shake: (intensity: number, frames: number) => void;
  /** GameShell "play_sound", "play_music" and "stop_music", and set_audio_bus_volume (audio.ts). */
  audio: (ev: Dict) => void;
  assetUrl: (path: string) => string;
  /** settings_renderer rows, when the game has settings_schema.json. */
  settingsRows?: (host: HTMLElement, text: (s: unknown) => string) => void;
};

type Screen = { id: string; spec: Dict; layer: HTMLElement; bound: Bound[] };
type Overlay = { id: string; spec: Dict; layer: HTMLElement; elapsed: number };

export class Shell {
  private host: ShellHost;
  private root: HTMLElement;
  private cfg: Dict = {};
  private screens = new Map<string, Dict>();
  private stack: Screen[] = [];
  private overlays: Overlay[] = [];
  private strings: Dict;
  private toastEl: HTMLElement | null = null;
  private toastTimer = 0;
  private fade: HTMLElement;
  private fadeAlpha = 0;
  private fadeTarget = 0;
  private fadeLeft = 0;
  /** GameShell's level fade: out, swap at the midpoint, then in. */
  private fadeLevel = "";
  private fadePhase: "idle" | "out" | "in" = "idle";
  private fadeHalf = 0;
  private flash: HTMLElement;
  private flashLeft = 0;
  private lastHeld = new Set<string>();
  private overlayCount = 0;
  readonly ui: UiContext;

  constructor(root: HTMLElement, screens: Dict, strings: Dict, host: ShellHost) {
    this.root = root;
    this.host = host;
    this.strings = strings;
    this.cfg = screens;
    for (const s of Array.isArray(screens.screens) ? screens.screens : []) if (isDict(s) && "id" in s) this.screens.set(String(s.id), s);
    this.ui = {
      world: host.world,
      text: (s) => this.text(s),
      binding: (p) => resolveBinding(host.world(), p),
      dispatch: (effects) => this.dispatch(effects),
      assetUrl: host.assetUrl,
      settingsRows: host.settingsRows ? (el) => host.settingsRows!(el, (t) => this.text(t)) : undefined,
    };
    this.flash = layerDiv(root, 30, "pointer-events:none;opacity:0");
    this.fade = layerDiv(root, 60, "pointer-events:none;background:#000;opacity:0");
  }

  /** ScreenFlow._ready: push the starting screen before the first tick, so a title shows before the world runs. */
  start(): void {
    const first = String(this.cfg.starting_screen ?? "");
    if (this.screens.has(first)) this.push(first, false);
    else this.applyActive();
  }

  get currentScreen(): string {
    return this.stack.length > 0 ? this.stack[this.stack.length - 1].id : "";
  }

  /**
   * Once for each frame: the event drain, the bound controls, the global
   * inputs, the overlays, the fades. `pressed` holds the key-downs since the
   * last frame, so a tap shorter than one frame still counts.
   */
  update(dt: number, held: Set<string>, pressed: Set<string>): void {
    this.drain();
    const top = this.stack[this.stack.length - 1];
    if (top) updateBound(top.bound, this.ui);
    const edges = new Set([...pressed, ...[...held].filter((a) => !this.lastHeld.has(a))]);
    this.lastHeld = new Set(held);
    this.globalInputs(edges);
    this.advanceOverlay(dt, edges);
    this.moveFocus(edges);
    this.updateFades(dt);
    this.applyFreeze();
  }

  /** ScreenFlow._drain_screen_events, OverlayManager._drain_overlay_events and GameShell._drain_shell_events. */
  drain(): void {
    const env = this.host.world().env;
    if (env.shellEvents.length === 0) return;
    const events = [...env.shellEvents];
    env.shellEvents.length = 0;
    for (const ev of events) {
      const type = String(ev.type ?? "");
      switch (type) {
        case "transition_screen": {
          const target = String(ev.target ?? "");
          if (target === "@previous") this.pop();
          else if (target === "@root") while (this.stack.length > 0) this.pop();
          else if (this.screens.has(target)) this.push(target, this.screens.get(target)!.modal === true);
          else console.warn(`[shell] transition to unknown screen '${target}'`);
          break;
        }
        case "show_toast":
          this.toast(this.text(ev.text ?? ""), Number(ev.duration ?? 2));
          break;
        case "show_overlay":
          this.showOverlay(ev);
          break;
        case "dismiss_overlay":
          this.dismissOverlay(String(ev.id ?? ""), "manual");
          break;
        case "screen_fade": {
          this.fade.style.background = cssColor(String(ev.color ?? "#000000"));
          this.fadeTarget = Math.min(Math.max(Number(ev.alpha ?? 1), 0), 1);
          this.fadeLeft = Math.max(Number(ev.duration ?? 0), 0);
          if (this.fadeLeft <= 0) this.fadeAlpha = this.fadeTarget;
          break;
        }
        case "transition_level_fade_request":
          if (this.fadePhase === "idle") {
            this.fade.style.background = cssColor(String(ev.color ?? "#000000"));
            this.fadeLevel = String(ev.target ?? "");
            this.fadeHalf = Math.max(Number(ev.fade_duration ?? 0.5) / 2, 0);
            this.fadeTarget = 1;
            this.fadeLeft = this.fadeHalf;
            this.fadePhase = "out";
          }
          break;
        case "refresh_screen":
          this.refreshTop();
          break;
        case "reload_scene":
          this.host.reload();
          return;
        case "quit_app":
          // A browser page cannot close itself. The shell shows the end instead.
          while (this.stack.length > 0) this.pop();
          this.toast("The game has ended.", 600);
          break;
        case "emit_shell_event":
          this.shellEvent(ev);
          break;
        case "set_audio_bus_volume":
          this.host.audio(ev);
          break;
      }
    }
  }

  /** GameShell._drain_shell_events for emit_shell_event records. */
  private shellEvent(ev: Dict): void {
    switch (String(ev.event ?? "")) {
      case "shake":
        this.host.shake(Number(ev.intensity ?? 4), Math.trunc(Number(ev.duration ?? 8)));
        break;
      case "flash": {
        // A flash is feedback, never a full wipe: alpha at most 0.5 (HudBuilder.trigger_flash).
        const c = String(ev.color ?? "#ff0000");
        const hasAlpha = /^#[0-9a-f]{8}$/i.test(c);
        const a = hasAlpha ? parseInt(c.slice(7, 9), 16) / 255 : 0.5;
        this.flash.style.background = cssColor(c.slice(0, 7), Math.min(a || 0.5, 0.5));
        this.flashLeft = Math.trunc(Number(ev.duration ?? 8));
        break;
      }
      case "play_sound":
      case "play_music":
      case "stop_music":
        this.host.audio(ev);
        break;
    }
  }

  // ------------------------------------------------------------ screens

  /** ScreenFlow._push_screen: a modal screen stacks, any other replaces the stack. */
  private push(id: string, modal: boolean): void {
    const spec = this.screens.get(id)!;
    if (!modal) while (this.stack.length > 0) this.removeTop();
    const layer = layerDiv(this.root, 20 + this.stack.length, "");
    if ("background_color" in spec || "background_alpha" in spec) {
      layer.style.background = cssColor(String(spec.background_color ?? "#000000"), Number(spec.background_alpha ?? 1));
      layer.style.pointerEvents = "auto";
    }
    const bound: Bound[] = [];
    for (const el of Array.isArray(spec.elements) ? spec.elements : []) if (isDict(el)) build(el, layer, this.ui, bound);
    this.stack.push({ id, spec, layer, bound });
    updateBound(bound, this.ui);
    // _focus_first_interactive: the keyboard reaches the screen with no mouse.
    (layer.querySelector("button:not([disabled])") as HTMLButtonElement | null)?.focus();
    this.applyActive();
    // _sync_global_input_edge_state: a key held through the push is not a new press.
  }

  private pop(): void {
    if (this.stack.length === 0) return;
    this.removeTop();
    this.applyActive();
    const top = this.stack[this.stack.length - 1];
    (top?.layer.querySelector("button:not([disabled])") as HTMLButtonElement | null)?.focus();
  }

  private removeTop(): void {
    this.stack.pop()?.layer.remove();
  }

  /** ScreenFlow._refresh_top_screen: build the top screen again in place. */
  private refreshTop(): void {
    const top = this.stack.pop();
    if (!top) return;
    top.layer.remove();
    this.push(top.id, true);
  }

  /** ScreenFlow._apply_active_screen. */
  private applyActive(): void {
    const ws = this.host.world().env.world;
    const top = this.stack[this.stack.length - 1];
    ws.current_screen = top ? top.id : "";
    ws.screen_freeze_world = top && top.spec.freeze_world === true ? 1 : 0;
  }

  /** ScreenFlow._handle_global_inputs: a press edge fires on_press when if_screen names the top screen ("" = none). */
  private globalInputs(edges: Set<string>): void {
    const globals = Array.isArray(this.cfg.global_inputs) ? this.cfg.global_inputs : [];
    const current = this.currentScreen;
    // The edges are read once for each action, before any entry fires: a paired toggle needs both halves to see one press.
    const fired: unknown[] = [];
    for (const g of globals) {
      if (!isDict(g) || !edges.has(String(g.action ?? ""))) continue;
      if (String(g.if_screen ?? "") !== current) continue;
      fired.push(g.on_press);
    }
    for (const effects of fired) this.dispatch(effects);
  }

  /** ScreenFlow._dispatch_effects: a control's effect chain runs at once, then the shell drains what it wrote. */
  private dispatch(effects: unknown): void {
    if (!Array.isArray(effects)) return;
    const env = this.host.world().env;
    for (const e of effects) if (isDict(e)) apply(e, env, { _rule_id: "screen_flow", _source: "ui" });
    this.host.world().scheduler.flush();
    this.drain();
  }

  /** Godot moves focus between controls with the arrow keys (ui_up, ui_down). */
  private moveFocus(edges: Set<string>): void {
    const top = this.stack[this.stack.length - 1];
    if (!top || this.overlays.length > 0) return;
    const step = edges.has("ui_down") || edges.has("ui_right") ? 1 : edges.has("ui_up") || edges.has("ui_left") ? -1 : 0;
    if (step === 0) return;
    const buttons = [...top.layer.querySelectorAll("button")].filter((b) => !(b as HTMLButtonElement).disabled) as HTMLButtonElement[];
    if (buttons.length === 0) return;
    const i = buttons.indexOf(document.activeElement as HTMLButtonElement);
    buttons[(i + step + buttons.length) % buttons.length].focus();
  }

  // ----------------------------------------------------------- overlays

  /** OverlayManager._show_overlay: a title and a body, with a dim backdrop when the overlay freezes the world. */
  private showOverlay(spec: Dict): void {
    let id = String(spec.id ?? "");
    if (id === "") id = `_overlay_${++this.overlayCount}`;
    // Idempotent: a tick rule may fire the same overlay each tick.
    if (this.overlays.some((o) => o.id === id)) return;
    const freeze = spec.freeze_world !== false;
    const alpha = Number(spec.backdrop_alpha ?? (freeze ? 0.5 : 0));
    const layer = layerDiv(this.root, 40 + this.overlays.length, "display:flex;align-items:center;justify-content:center");
    if (alpha > 0) layer.style.background = cssColor(String(spec.backdrop_color ?? "#000000"), alpha);
    const box = document.createElement("div");
    box.style.cssText = "display:flex;flex-direction:column;gap:16px;align-items:center;text-align:center;font-family:'Open Sans',system-ui,sans-serif";
    const title = this.text(spec.title ?? "");
    if (title !== "") {
      const t = document.createElement("div");
      t.textContent = title;
      t.style.cssText = `font-size:${Number(spec.title_font_size ?? 32)}px;color:${cssColor(String(spec.title_color ?? "#fdd068"))};text-shadow:0 0 4px #000,0 0 4px #000`;
      box.appendChild(t);
    }
    const body = this.text(spec.body ?? "");
    if (body !== "") {
      const b = document.createElement("div");
      b.textContent = body;
      b.style.cssText = `width:540px;max-width:90vw;font-size:${Number(spec.body_font_size ?? 20)}px;color:${cssColor(String(spec.body_color ?? "#f0e0c0"))};text-shadow:0 0 3px #000,0 0 3px #000`;
      box.appendChild(b);
    }
    layer.appendChild(box);
    this.overlays.push({ id, spec, layer, elapsed: 0 });
  }

  /** OverlayManager._dismiss_overlay: remove it, then signal overlay_advanced {id, reason}. */
  private dismissOverlay(id: string, reason: string): void {
    const i = this.overlays.findIndex((o) => o.id === id);
    if (i < 0) return;
    this.overlays[i].layer.remove();
    this.overlays.splice(i, 1);
    this.host.world().env.signalBuffer.push({ name: "overlay_advanced", payload: { id, reason } });
  }

  /** OverlayManager._advance_active_overlay: only the top overlay listens. */
  private advanceOverlay(dt: number, edges: Set<string>): void {
    const top = this.overlays[this.overlays.length - 1];
    if (!top) return;
    top.elapsed += dt;
    const s = top.spec;
    if (s.advance_after_seconds !== undefined && s.advance_after_seconds !== null && top.elapsed >= Number(s.advance_after_seconds)) {
      return this.dismissOverlay(top.id, "timer");
    }
    const action = String(s.advance_action ?? "");
    if (action !== "" && edges.has(action)) return this.dismissOverlay(top.id, "action");
    const sig = String(s.advance_signal ?? "");
    if (sig !== "" && this.host.world().env.signalBuffer.some((x) => x.name === sig)) return this.dismissOverlay(top.id, "signal");
    if (s.skippable !== false && edges.has("ui_cancel")) return this.dismissOverlay(top.id, "skip");
  }

  /** OverlayManager._apply_freeze_state. */
  private applyFreeze(): void {
    this.host.world().env.world.overlay_freeze_world = this.overlays.some((o) => o.spec.freeze_world !== false) ? 1 : 0;
  }

  // ------------------------------------------------- toasts and fades

  /** ScreenFlow._show_toast: one toast at a time, bottom center, fading in the last 0.5 s. */
  private toast(text: string, duration: number): void {
    this.toastEl?.remove();
    clearTimeout(this.toastTimer);
    const el = layerDiv(this.root, 50, "pointer-events:none");
    const t = document.createElement("div");
    t.textContent = text;
    t.style.cssText =
      "position:absolute;bottom:40px;left:50%;transform:translateX(-50%);white-space:nowrap;font:22px 'Open Sans',system-ui,sans-serif;" +
      "color:rgb(255,255,217);text-shadow:0 0 4px #000,0 0 4px #000;transition:opacity 0.5s";
    el.appendChild(t);
    this.toastEl = el;
    this.toastTimer = window.setTimeout(() => {
      t.style.opacity = "0";
      this.toastTimer = window.setTimeout(() => el.remove(), 500);
    }, Math.max(duration - 0.5, 0.1) * 1000);
  }

  /** GameShell._update_fade, and the frame count of the hit flash. */
  private updateFades(dt: number): void {
    if (this.fadeLeft > 0) {
      const k = Math.min(dt / this.fadeLeft, 1);
      this.fadeAlpha += (this.fadeTarget - this.fadeAlpha) * k;
      this.fadeLeft = Math.max(this.fadeLeft - dt, 0);
    } else this.fadeAlpha = this.fadeTarget;
    if (this.fadePhase === "out" && this.fadeLeft <= 0) {
      // The midpoint: swap the level under full black, then fade in.
      this.host.world().env.pendingLevel = this.fadeLevel;
      this.host.world().processPending();
      this.fadePhase = "in";
      this.fadeTarget = 0;
      this.fadeLeft = this.fadeHalf;
    } else if (this.fadePhase === "in" && this.fadeLeft <= 0) this.fadePhase = "idle";
    this.fade.style.opacity = String(this.fadeAlpha);
    if (this.flashLeft > 0) {
      this.flashLeft--;
      this.flash.style.opacity = "1";
    } else this.flash.style.opacity = "0";
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
}

function layerDiv(parent: HTMLElement, z: number, css: string): HTMLElement {
  const d = document.createElement("div");
  d.style.cssText = `position:absolute;inset:0;z-index:${z};pointer-events:none;${css}`;
  parent.appendChild(d);
  return d;
}
