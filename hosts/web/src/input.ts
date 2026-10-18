// The input poll. Mirrors InputRegistrar.poll. The scenario runner calls it
// before each tick, and the viewer calls it once per physics step (ADR 0069).
//
// Each held hold-edge action queues. A press-edge action queues once, on
// the step of its key-down. A held move_* key on one axis keeps that axis
// moving. With no key on an axis and a velocity on it, the active actor
// gets stop_x or stop_y.
import { Vec2, Vec3 } from "./value.ts";
import type { World } from "./world.ts";

export function pollInput(w: World, held: Set<string>, justPressed: Set<string>): void {
  const actor = w.activeActorId();
  if (actor === "") return;
  let ns = false;
  let ew = false;
  let anyMove = false;
  for (const a of w.actionsHold) {
    if (!held.has(a)) continue;
    w.scheduler.queueInput(a, { actor });
    if (a.startsWith("move_")) {
      anyMove = true;
      if (a === "move_north" || a === "move_south") ns = true;
      else if (a === "move_east" || a === "move_west") ew = true;
    }
  }
  for (const a of w.actionsPress) if (justPressed.has(a)) w.scheduler.queueInput(a, { actor });
  justPressed.clear();
  const ent = w.env.entities.get(actor);
  if (ent) {
    const v = ent.getState("velocity", new Vec2(0, 0));
    const vx = v instanceof Vec2 || v instanceof Vec3 ? v.x : 0;
    const vy = v instanceof Vec2 ? v.y : v instanceof Vec3 ? v.z : 0;
    if (!ew && Math.abs(vx) > 0.001) w.scheduler.queueInput("stop_x", { actor });
    if (!ns && Math.abs(vy) > 0.001) w.scheduler.queueInput("stop_y", { actor });
    const stop = w.stopActionOnIdle;
    if (stop !== "" && !anyMove && stop !== "stop_x" && stop !== "stop_y") {
      const nonzero = v instanceof Vec2 ? v.x !== 0 || v.y !== 0 : v instanceof Vec3 ? v.x !== 0 || v.y !== 0 || v.z !== 0 : false;
      if (nonzero) w.scheduler.queueInput(stop, { actor });
    }
  }
}
