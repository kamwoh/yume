// node src/cli.ts <game_dir> [<game_dir> ...] [--verbose] [--lib=<lib_dir>]
// Runs each game's tests.json on the TypeScript host and prints the same
// summary line as the Godot scenario runner.
import { basename, resolve } from "node:path";
import { NodeFiles } from "./node_files.ts";
import { RapierPhysics, initRapier } from "./physics_rapier.ts";
import { type PhysicsFactory, runGame } from "./scenario.ts";

const args = process.argv.slice(2);
const verbose = args.includes("--verbose");
const libArg = args.find((a) => a.startsWith("--lib="));
const lib = libArg ? resolve(libArg.slice(6)) : "";
await initRapier();
const physics: PhysicsFactory = (layers, bounds) => new RapierPhysics(layers, bounds);
let failed = 0;
for (const dir of args.filter((a) => !a.startsWith("--"))) {
  const r = runGame(resolve(dir), new NodeFiles(), verbose, lib, physics);
  console.log(`${basename(dir)}: passed: ${r.passed}  failed: ${r.failed}  total: ${r.passed + r.failed}`);
  for (const f of r.failures) console.log(`  ✗ ${f}`);
  for (const e of r.errors) console.log(`  ! ${e}`);
  failed += r.failed;
}
process.exit(failed === 0 ? 0 : 1);
