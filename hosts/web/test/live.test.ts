import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { LiveClock } from "../src/live.ts";
import { MemoryFiles } from "../src/files.ts";
import { NodeFiles } from "../src/node_files.ts";
import { Vec2, Vec3 } from "../src/value.ts";
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

// world.gd snap: a tick_seconds within 0.5% of the physics step is one
// tick for each step. Without it, 0.0167 against 1/60 skips a tick every 8 s.
test("a tick_seconds of 0.0167 runs one tick for each physics step", () => {
  const w = new World("game", new MemoryFiles({ "game/scene.json": JSON.stringify({ tick_seconds: 0.0167 }) }), "lib");
  w.load();
  const clock = new LiveClock(w);
  for (let i = 0; i < 600; i++) clock.physicsStep();
  assert.equal(w.simTick, 600);
});

// GroundConstraint, once for each live frame: below ground.y, a projectile
// leaves the world and a creature goes back up to the ground.
test("the ground constraint removes projectiles and clamps creatures", () => {
  const game = {
    definitions: [
      { id: "bolt", tags: ["projectile"] },
      { id: "imp", tags: ["creature"] },
      { id: "rock", tags: [] },
    ],
    initial_instances: [
      { def: "bolt", id: "bolt_1", position: [0, -0.5, 0] },
      { def: "imp", id: "imp_1", position: [1, -0.5, 2] },
      { def: "rock", id: "rock_1", position: [0, -0.5, 0] },
    ],
  };
  const w = new World(
    "game",
    new MemoryFiles({ "game/scene.json": JSON.stringify({ ground: { y: 0 } }), "game/entities/all.json": JSON.stringify(game) }),
    "lib",
  );
  w.load();
  w.applyGroundConstraint();
  assert.ok(!w.env.entities.has("bolt_1"), "the projectile left the world");
  const imp = w.env.entities.get("imp_1")!.state.position as Vec3;
  assert.deepEqual([imp.x, imp.y, imp.z], [1, 0, 2], "the creature stands on the ground");
  assert.equal((w.env.entities.get("rock_1")!.state.position as Vec3).y, -0.5, "an untagged entity stays");
});

// world.gd: a screen or an overlay with freeze_world stops the sim, and a
// press made during the freeze does not fire when the freeze ends.
test("a freeze stops the ticks and drops the presses made during it", () => {
  const w = boot();
  const clock = new LiveClock(w);
  w.env.world.screen_freeze_world = 1;
  clock.keyDown("move_north");
  clock.advance(1.0);
  clock.keyUp("move_north");
  assert.equal(w.simTick, 0, "no tick while frozen");
  w.env.world.screen_freeze_world = 0;
  w.env.world.overlay_freeze_world = 1;
  clock.advance(0.5);
  assert.equal(w.simTick, 0, "an overlay freeze stops it too");
  w.env.world.overlay_freeze_world = 0;
  // One advance runs at most 0.25 s.
  for (let i = 0; i < 4; i++) clock.advance(0.25);
  assert.equal(w.simTick, 10, "ticks run again");
  assert.deepEqual([player(w).x, player(w).y], [48, 80], "the press made during the freeze did not move the player");
});
