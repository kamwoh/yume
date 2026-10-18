// The game bundle of the browser viewer: one JSON map of path to text. The
// browser loads it into MemoryFiles. Keys: game/<path>, lib/<path>,
// shapes.json and meshes.json.
import { join, relative } from "node:path";
import { NodeFiles } from "./node_files.ts";

const files = new NodeFiles();

/** Every .json file under `base`, keyed as `<prefix>/<path relative to base>`. */
function collect(base: string, prefix: string, out: Record<string, string>, dir = base): void {
  for (const name of files.list(dir)) {
    if (name.startsWith(".")) continue;
    const full = join(dir, name);
    if (files.isDir(full)) collect(base, prefix, out, full);
    else if (name.endsWith(".json")) out[`${prefix}/${relative(base, full)}`] = files.read(full) ?? "";
  }
}

/** The bundle of `<dataRoot>/<game>`, or null when there is no such game folder. */
export function bundle(dataRoot: string, game: string): Record<string, string> | null {
  const gameDir = join(dataRoot, game);
  if (!/^[\w-]+$/.test(game) || !files.isDir(gameDir)) return null;
  const out: Record<string, string> = {};
  collect(gameDir, "game", out);
  collect(join(dataRoot, "lib"), "lib", out);
  for (const lib of ["shapes.json", "meshes.json"]) {
    const text = files.read(join(dataRoot, lib));
    if (text !== null) out[lib] = text;
  }
  return out;
}
