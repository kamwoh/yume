// The procedural sounds (audio_bus.gd): the same synthesis at 22050 Hz.
import { test } from "node:test";
import assert from "node:assert/strict";
import { synthesize, synthesizeMelody } from "../src/viewer/audio.ts";

test("a sound has duration × 22050 samples, a linear attack and a decay to silence", () => {
  const pcm = synthesize({ wave: "sine", freq_start: 440, duration: 0.2, attack: 0.01, decay: 0.5, volume: 0.5 });
  assert.equal(pcm.length, 4410);
  assert.equal(pcm[0], 0, "the attack starts at 0");
  const peak = Math.max(...pcm.map(Math.abs));
  assert.ok(peak > 0.45 && peak <= 0.5, `the peak is the volume (${peak})`);
  assert.ok(Math.abs(pcm[pcm.length - 1]) < 0.01, "the decay ends near silence");
});

test("a square wave holds ±volume, and samples are 16-bit steps", () => {
  const pcm = synthesize({ wave: "square", freq_start: 100, duration: 0.05, attack: 0, decay: 0, volume: 0.25 });
  // Float32 keeps each 16-bit level to within a small fraction of one step.
  for (const s of pcm) assert.ok(Math.abs(s * 32767 - Math.round(s * 32767)) < 0.01, "a 16-bit level");
  assert.ok(Math.abs(pcm[10]) > 0.2, "the square wave is near the volume at the start");
});

test("a melody joins its notes, each with its own length", () => {
  const pcm = synthesizeMelody({ wave: "sine", volume: 0.4, notes: [{ freq: 440, dur: 0.1 }, { freq: 660, dur: 0.2 }] });
  assert.equal(pcm.length, 2205 + 4410);
});

test("a settings row value is clamped to its type (SettingsManager._clamp_value)", async () => {
  const { clampValue } = await import("../src/viewer/settings.ts");
  assert.equal(clampValue({ type: "slider", min: 0, max: 1 }, 1.4), 1);
  assert.equal(clampValue({ type: "bool" }, 1), true);
  assert.equal(clampValue({ type: "enum", options: ["off", "on"] }, "nope"), "off");
  assert.equal(clampValue({ type: "key_binding" }, 5), "5");
});
