// The DOM-free screen stack (screen_flow.ts) that the viewer draws and the
// scenario runner clicks.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MemoryFiles } from "../src/files.ts";
import { ScreenFlow } from "../src/screen_flow.ts";
import { type Dict } from "../src/value.ts";
import { World } from "../src/world.ts";

const SCREENS: Dict = {
  starting_screen: "board",
  global_inputs: [{ action: "ui_cancel", if_screen: "help", on_press: [{ type: "transition_screen", target: "@previous" }] }],
  screens: [
    {
      id: "board",
      elements: [
        { type: "button", id: "btn_help", text: "@strings.help", on_click: [{ type: "transition_screen", target: "help" }] },
        {
          type: "list",
          from: { tags_all: ["contract"] },
          item: { type: "hbox", children: [{ type: "button", id: "btn_take", text: "row.properties.name", on_click: [{ type: "tag_add", target: "row", tag: "taken" }, { type: "refresh_screen" }] }] },
          empty: { type: "label", text: "none" },
        },
      ],
    },
    { id: "help", modal: true, elements: [{ type: "button", id: "btn_close", text: "Close", on_click: [{ type: "transition_screen", target: "@previous" }] }] },
  ],
};

function boot(): { w: World; flow: ScreenFlow } {
  const entities = {
    definitions: [{ id: "contract", tags: ["contract"], properties: { name: "Tally" }, visual: { hidden: true } }],
    initial_instances: [
      { def: "contract", id: "c_a" },
      { def: "contract", id: "c_b" },
    ],
  };
  const w = new World("game", new MemoryFiles({ "game/entities/e.json": JSON.stringify(entities) }), "lib");
  w.load();
  const flow = new ScreenFlow(() => w, SCREENS, { help: "Help" });
  flow.start();
  return { w, flow };
}

test("the starting screen opens at once and owns current_screen", () => {
  const { w, flow } = boot();
  assert.equal(flow.currentScreen, "board");
  assert.equal(w.env.world.current_screen, "board");
});

test("a list stamps one row for each match, and each row id carries the entity id", () => {
  const { flow } = boot();
  assert.equal(flow.findControls({ id: "btn_take__c_a" }).length, 1);
  assert.equal(flow.findControls({ id: "btn_take__c_b" }).length, 1);
  assert.equal(flow.findControls({ id: "btn_take" }).length, 0);
  assert.equal(flow.findControls({ text: "Tally" }).length, 2, "a text selector sees both rows");
  assert.equal(flow.findControls({ text: "Help" }).length, 1, "a text selector reads the shown @strings text");
});

test("a row's on_click names its own entity, and refresh_screen builds the rows again", () => {
  const { w, flow } = boot();
  flow.press(flow.findControls({ id: "btn_take__c_b" })[0]);
  assert.ok(w.env.entities.get("c_b")!.hasTag("taken"));
  assert.ok(!w.env.entities.get("c_a")!.hasTag("taken"));
  assert.equal(flow.stack.length, 1, "the refresh keeps one copy of the screen");
});

test("a modal stacks over the screen, and @previous and a global input pop it", () => {
  const { w, flow } = boot();
  flow.press(flow.findControls({ id: "btn_help" })[0]);
  assert.deepEqual(flow.stack.map((e) => e.id), ["board", "help"]);
  assert.equal(flow.findControls({ id: "btn_take__c_a" }).length, 1, "the controls under a modal stay findable");
  flow.globalInputs(new Set(["ui_cancel"]));
  assert.equal(flow.currentScreen, "board");
  flow.press(flow.findControls({ id: "btn_help" })[0]);
  flow.press(flow.findControls({ id: "btn_close" })[0]);
  assert.equal(w.env.world.current_screen, "board");
});

test("screen_restore pops back to the depth of its screen_mark, not to an empty stack", () => {
  const { w, flow } = boot();
  w.env.shellEvents.push({ type: "screen_mark" }, { type: "transition_screen", target: "help" });
  flow.drain();
  assert.equal(flow.stack.length, 2);
  w.env.shellEvents.push({ type: "screen_restore" });
  flow.drain();
  assert.deepEqual(flow.stack.map((e) => e.id), ["board"]);
});

test("an open list queries again after a world reset (World.world_loaded)", () => {
  const { w, flow } = boot();
  w.env.entities.delete("c_a");
  flow.drain();
  assert.equal(flow.findControls({ id: "btn_take__c_a" }).length, 1, "with no load, the rows keep their snapshot");
  w.doReset();
  flow.drain();
  assert.equal(flow.findControls({ id: "btn_take__c_a" }).length, 1, "the reset spawns c_a again");
  w.env.entities.delete("c_a");
  w.env.entities.delete("c_b");
  w.loadCount++;
  flow.drain();
  assert.equal(flow.findControls({ text: "Tally" }).length, 0);
});
