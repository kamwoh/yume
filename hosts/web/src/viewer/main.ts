// The browser viewer (ADR 0095 phase 2). It boots the headless core from a
// bundle, drives it with the keyboard and draws it with three.js.
//
// LiveClock (live.ts) runs the live-play loop of the reference.
//
// URL parameters:
//   game=<folder>            the game to load (default demo_sokoban)
//   press=a,b,c              actions to press, one physics step each, before the first frame
//   ticks=N                  sim ticks to run after those presses
import * as THREE from "three";
import { MemoryFiles } from "../files.ts";
import { GroundHeight } from "../heightmap.ts";
import { LiveClock, PHYSICS_DT } from "../live.ts";
import { type Dict, isDict } from "../value.ts";
import { World } from "../world.ts";
import { Hud } from "./hud.ts";
import { codeToActions } from "./keys.ts";
import { Renderer2D } from "./render2d.ts";
import { Renderer3D, is3D } from "./render3d.ts";

async function boot(): Promise<void> {
  const params = new URLSearchParams(location.search);
  const game = params.get("game") ?? "demo_sokoban";
  const status = document.getElementById("status")!;
  const res = await fetch(`/bundle/${encodeURIComponent(game)}`);
  if (!res.ok) {
    status.textContent = `No game '${game}'.`;
    return;
  }
  const entries = (await res.json()) as Record<string, string>;
  const files = new MemoryFiles(entries);
  const world = new World("game", files, "lib");
  // The physics host (phase 3) loads only for a game that declares bodies or sensors.
  if (Object.entries(entries).some(([k, v]) => k.startsWith("game/") && /"(physics|sensors)"\s*:/.test(v))) {
    const rapier = await import("../physics_rapier.ts");
    await rapier.initRapier();
    world.physicsFactory = (layers, bounds) => new rapier.RapierPhysics(layers, bounds);
  }
  world.load();
  // The camera block may use $extends with a lib preset (lib/cameras.json).
  const scene = world.lib.resolve(parse(files.read("game/scene.json"))) as Dict;
  // Live play mounts the ground collider (GroundRenderer). A scenario run has none.
  const ground = isDict(scene.ground) ? scene.ground : null;
  const hmPath = ground ? GroundHeight.heightmapPath(ground) : "";
  const height = ground && hmPath !== "" ? await loadGroundHeight(ground, `/asset/${encodeURIComponent(game)}/${hmPath}`) : null;
  if (ground) world.env.physics?.addGround(ground, height);
  const canvas = document.getElementById("view") as HTMLCanvasElement;
  const view = is3D(scene)
    ? new Renderer3D(canvas, parse(files.read("meshes.json")), scene, `/asset/${encodeURIComponent(game)}/`)
    : new Renderer2D(canvas, parse(files.read("shapes.json")), scene);
  if (view instanceof Renderer3D && height) view.setGroundHeight(height);
  if (view instanceof Renderer3D) {
    // A click captures the mouse. Motion then turns the actor, as in the reference.
    canvas.addEventListener("click", () => canvas.requestPointerLock());
    document.addEventListener("pointerlockchange", () => {
      view.mouseCaptured = document.pointerLockElement === canvas;
    });
    addEventListener("mousemove", (ev) => {
      if (view.mouseCaptured) {
        view.mouseDelta.x += ev.movementX;
        view.mouseDelta.y += ev.movementY;
      }
    });
  }
  const hudCfg = parse(files.read("game/hud.json"));
  const hud = new Hud(document.getElementById("hud")!, hudCfg, parse(files.read("game/ui/strings.json")));
  // The status line is for games with no HUD. A HUD may use any corner.
  if (Array.isArray(hudCfg.panels) && hudCfg.panels.length > 0) status.style.display = "none";
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
    world.env.physics?.step(PHYSICS_DT);
  }

  const showStatus = () => {
    const level = world.currentLevel !== "" ? `level ${world.currentLevel}` : "";
    const done = world.env.world.all_levels_complete === 1 ? " · all levels complete" : "";
    const last = [...world.env.shellEvents].reverse().find((e) => e.type === "show_overlay" || e.type === "show_toast");
    const note = last ? ` · ${String(last.title ?? last.text ?? last.message ?? "")}` : "";
    status.textContent = `${game} ${level}${done}${note}`;
  };

  /** A trimesh body gets its faces from its GLB (PhysicsBodyBuilder._glb_trimesh_faces). */
  const feedTrimeshes = () => {
    const ph = world.env.physics;
    if (!ph || !(view instanceof Renderer3D)) return;
    for (const { entity, mesh } of ph.pendingTrimeshes()) {
      view.loadModel(mesh).then((root) => {
        if (root) ph.setTrimesh(entity, ...trimeshOf(root));
      });
    }
  };
  feedTrimeshes();

  let last = performance.now();
  const frame = (now: number) => {
    feedTrimeshes();
    // The reference loads every asset before its first physics frame. The clock waits here too.
    if (!(view instanceof Renderer3D) || view.pending === 0) {
      clock.advance((now - last) / 1000);
      world.applyGroundConstraint();
    }
    last = now;
    view.sync(world);
    view.render();
    hud.update(world);
    showStatus();
    // A capture tool waits for data-assets="loaded" (tools/capture.ts).
    if (!(view instanceof Renderer3D) || view.pending === 0) document.body.dataset.assets = "loaded";
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

/** The heightmap of a ground block: the red channel of its image, with no color conversion. */
async function loadGroundHeight(ground: Dict, url: string): Promise<GroundHeight | null> {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const bmp = await createImageBitmap(await res.blob(), { colorSpaceConversion: "none", premultiplyAlpha: "none" });
    const canvas = new OffscreenCanvas(bmp.width, bmp.height);
    const ctx = canvas.getContext("2d")!;
    ctx.drawImage(bmp, 0, 0);
    const px = ctx.getImageData(0, 0, bmp.width, bmp.height).data;
    const red = new Float32Array(bmp.width * bmp.height);
    for (let i = 0; i < red.length; i++) red[i] = px[i * 4] / 255;
    return GroundHeight.of(ground, { width: bmp.width, height: bmp.height, red });
  } catch (e) {
    console.info(`[ground] heightmap did not load: ${String(e)}`);
    return null;
  }
}

/** The faces of a GLB scene in its native space: each mesh with its transform relative to the root. */
function trimeshOf(root: THREE.Object3D): [Float32Array, Uint32Array] {
  root.updateMatrixWorld(true);
  const inv = root.matrixWorld.clone().invert();
  const verts: number[] = [];
  const idx: number[] = [];
  const v = new THREE.Vector3();
  root.traverse((o) => {
    if (!(o instanceof THREE.Mesh)) return;
    const m = inv.clone().multiply(o.matrixWorld);
    const pos = o.geometry.attributes.position;
    const base = verts.length / 3;
    for (let i = 0; i < pos.count; i++) {
      v.fromBufferAttribute(pos, i).applyMatrix4(m);
      verts.push(v.x, v.y, v.z);
    }
    const index = o.geometry.index;
    if (index) for (let i = 0; i < index.count; i++) idx.push(base + index.getX(i));
    else for (let i = 0; i < pos.count; i++) idx.push(base + i);
  });
  return [new Float32Array(verts), new Uint32Array(idx)];
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
