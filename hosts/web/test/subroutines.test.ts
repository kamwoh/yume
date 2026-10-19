// Level subroutines (ADR 0077), zone state (ADR 0031) and actors (ADR 0016) on the TypeScript host.
import { test } from "node:test";
import assert from "node:assert/strict";
import { apply } from "../src/effects.ts";
import { MemoryFiles } from "../src/files.ts";
import { World } from "../src/world.ts";

function game(extra: Record<string, string> = {}): World {
  const files = new MemoryFiles({
    "game/scene.json": "{}",
    "game/game/flow.json": JSON.stringify({ levels: ["town"], starting_level: "town" }),
    "game/levels/town/entities.json": JSON.stringify({ definitions: [{ id: "house", tags: ["house"] }], initial_instances: [{ def: "house", id: "h1" }] }),
    "game/levels/cave/entities.json": JSON.stringify({ definitions: [{ id: "rock", tags: ["rock"] }], initial_instances: [{ def: "rock", id: "r1" }] }),
    ...extra,
  });
  const w = new World("game", files, "lib");
  w.load();
  return w;
}

test("level_call enters an off-progression level, and level_return comes back with the result signal", () => {
  const w = game();
  apply({ type: "level_call", level: "cave", return_signal: "cave_done", args: { floor: "1 + 2" } }, w.env, {});
  assert.deepEqual(w.env.shellEvents.at(-1), { type: "screen_mark" });
  assert.equal(w.env.world._call_args && (w.env.world._call_args as Record<string, unknown>).floor, 3);
  w.processPending();
  assert.equal(w.currentLevel, "cave");
  assert.ok(w.env.entities.has("r1") && !w.env.entities.has("h1"));
  apply({ type: "level_return", result: { haul: "2 * 5" } }, w.env, {});
  assert.deepEqual(w.env.shellEvents.at(-1), { type: "screen_restore" });
  w.processPending();
  assert.equal(w.currentLevel, "town");
  assert.ok(w.env.entities.has("h1"));
  assert.deepEqual(w.env.signalBuffer.at(-1), { name: "cave_done", payload: { haul: 10 } });
});

test("level_return with an empty call stack raises level.return_empty_stack and stays", () => {
  const w = game();
  apply({ type: "level_return" }, w.env, {});
  assert.ok(w.env.errors.some((e) => e.code === "level.return_empty_stack"));
  assert.equal(w.env.pendingLevelReturn, null);
});

test("zone_state effects write the zone store, and formulas read it as zone.<id>.<field>", () => {
  const zones = { zones: [{ id: "kingdom", contains: ["city"], state_init: { unrest: 1 } }, { id: "city", state_init: { rice: 50 } }] };
  const w = game({ "game/world/zones.json": JSON.stringify(zones) });
  apply({ type: "zone_state_add", zone: "city", field: "rice", amount: -60 }, w.env, {});
  apply({ type: "zone_state_clamp", zone: "city", field: "rice", min: 0 }, w.env, {});
  apply({ type: "zone_state_set", zone: "kingdom", field: "unrest", value: "zone.kingdom.unrest + 4" }, w.env, {});
  apply({ type: "zone_state_add", zone: "nowhere", field: "x", amount: 1 }, w.env, {});
  assert.deepEqual(w.env.zones!.bindingSnapshot(), { kingdom: { unrest: 5 }, city: { rice: 0 } });
  assert.ok(w.env.errors.some((e) => e.code === "effect.zone_unknown"));
});

test("actors.json picks the controlled entity, and switch_actor takes effect at the tick boundary", () => {
  const actors = { actors: [{ id: "a1", starting_entity_tag: "house" }, { id: "a2", starting_entity_tag: "car" }], active_actor_id: "a1" };
  const w = game({
    "game/actors.json": JSON.stringify(actors),
    "game/entities/cars.json": JSON.stringify({ definitions: [{ id: "car", tags: ["car"] }], initial_instances: [{ def: "car", id: "c1" }] }),
  });
  assert.equal(w.activeActorId(), "h1");
  apply({ type: "switch_actor", target_id: "a2" }, w.env, {});
  assert.equal(w.env.world.active_actor_id, "a1");
  w.advanceOneTick();
  assert.equal(w.env.world.active_actor_id, "a2");
  assert.equal(w.activeActorId(), "c1");
});
