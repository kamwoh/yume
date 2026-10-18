// The browser viewer (ADR 0095 phase 2). It boots the headless core from a
// bundle, drives it with the keyboard and draws it with three.js.
//
// LiveClock (live.ts) runs the live-play loop of the reference.
//
// URL parameters:
//   game=<folder>            the game to load (default demo_sokoban)
//   press=a,b,c              actions to press, one physics step each, before the first frame
//   ticks=N                  sim ticks to run after those presses
import { MemoryFiles } from "../files.ts";
import { LiveClock, PHYSICS_DT } from "../live.ts";
import { type Dict, isDict } from "../value.ts";
import { World } from "../world.ts";
import { Hud } from "./hud.ts";
import { codeToActions } from "./keys.ts";
import { Renderer2D } from "./render2d.ts";

async function boot(): Promise<void> {
  const params = new URLSearchParams(location.search);
  const game = params.get("game") ?? "demo_sokoban";
  const status = document.getElementById("status")!;
  const res = await fetch(`/bundle/${encodeURIComponent(game)}`);
  if (!res.ok) {
    status.textContent = `No game '${game}'.`;
    return;
  }
  const files = new MemoryFiles((await res.json()) as Record<string, string>);
  const world = new World("game", files, "lib");
  world.load();
  const scene = parse(files.read("game/scene.json"));
  const canvas = document.getElementById("view") as HTMLCanvasElement;
  const view = new Renderer2D(canvas, parse(files.read("shapes.json")), scene);
  const hud = new Hud(document.getElementById("hud")!, parse(files.read("game/hud.json")), parse(files.read("game/ui/strings.json")));
  const resize = () => view.renderer.setSize(innerWidth, innerHeight, false);
  addEventListener("resize", resize);
  resize();

  const clock = new LiveClock(world);
  const byCode = codeToActions(world.actionKeys);
  addEventListener("keydown", (ev) => {
    const actions = byCode.get(ev.code);
    if (!actions) return;
    ev.preventDefault();
    if (!ev.repeat) for (const a of actions) clock.keyDown(a);
  });
  addEventListener("keyup", (ev) => {
    for (const a of byCode.get(ev.code) ?? []) clock.keyUp(a);
  });
  addEventListener("blur", () => clock.held.clear());

  // Scripted input for captures: each press is one key-down for one physics step.
  for (const a of (params.get("press") ?? "").split(",").filter((x) => x !== "")) {
    clock.keyDown(a);
    clock.physicsStep();
    clock.keyUp(a);
    // Let the tick that consumes the press run.
    for (let i = 0; i < Math.ceil(world.tickSeconds / PHYSICS_DT); i++) clock.physicsStep();
  }
  for (let i = 0; i < Number(params.get("ticks") ?? 0); i++) {
    world.advanceOneTick();
    world.processPending();
  }

  const showStatus = () => {
    const level = world.currentLevel !== "" ? `level ${world.currentLevel}` : "";
    const done = world.env.world.all_levels_complete === 1 ? " · all levels complete" : "";
    const last = [...world.env.shellEvents].reverse().find((e) => e.type === "show_overlay" || e.type === "show_toast");
    const note = last ? ` · ${String(last.title ?? last.text ?? last.message ?? "")}` : "";
    status.textContent = `${game} ${level}${done}${note}`;
  };

  let last = performance.now();
  const frame = (now: number) => {
    clock.advance((now - last) / 1000);
    last = now;
    view.sync(world);
    view.render();
    hud.update(world);
    showStatus();
    requestAnimationFrame(frame);
  };
  view.sync(world);
  view.render();
  hud.update(world);
  showStatus();
  document.body.dataset.ready = "1";
  requestAnimationFrame(frame);
  (globalThis as unknown as { yume: unknown }).yume = { world };
}

function parse(text: string | null): Dict {
  try {
    const v = JSON.parse(text ?? "{}");
    return isDict(v) ? v : {};
  } catch {
    return {};
  }
}

boot().catch((e) => {
  document.getElementById("status")!.textContent = `Boot failed: ${String(e)}`;
  console.error(e);
});
