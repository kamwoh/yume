import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { LiveClock } from "../src/live.ts";
import { NodeFiles } from "../src/node_files.ts";
import { Vec2 } from "../src/value.ts";
import { World } from "../src/world.ts";

const data = fileURLToPath(new URL("../../../godot/data", import.meta.url));

function boot(): World {
  const w = new World(`${data}/demo_sokoban`, new NodeFiles(), `${data}/lib`);
  w.load();
  return w;
}

function player(w: World): Vec2 {
  for (const e of w.env.entities.values()) if (e.hasTag("player")) return e.planarPosition();
  throw new Error("no player");
}

// Live play (ADR 0069): a press-edge action fires once for one key-down,
// however long the key stays down and however many ticks pass.
test("a held press-edge key moves the player once", () => {
  const w = boot();
  const clock = new LiveClock(w);
  clock.keyDown("move_north");
  clock.advance(1.0);
  clock.keyUp("move_north");
  assert.deepEqual([player(w).x, player(w).y], [48, 48]);
});

// A key-down between two sim ticks waits in the input queue for the next tick.
test("a short tap between ticks still fires on the next tick", () => {
  const w = boot();
  const clock = new LiveClock(w);
  clock.keyDown("move_north");
  clock.advance(1 / 60);
  clock.keyUp("move_north");
  assert.equal(w.simTick, 0);
  clock.advance(0.2);
  assert.deepEqual([player(w).x, player(w).y], [48, 48]);
  clock.keyDown("move_south");
  clock.advance(0.05);
  clock.keyUp("move_south");
  clock.advance(0.2);
  assert.deepEqual([player(w).x, player(w).y], [48, 80]);
});

test("the sim ticks at tick_seconds, not at the physics rate", () => {
  const w = boot();
  const clock = new LiveClock(w);
  clock.advance(0.25);
  clock.advance(0.25);
  clock.advance(0.25);
  clock.advance(0.25);
  assert.equal(w.simTick, 10);
});
