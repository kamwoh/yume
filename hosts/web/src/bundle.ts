// The game bundle of the browser viewer: one JSON map of path to text. The
// browser loads it into MemoryFiles. Keys: game/<path>, lib/<path>,
// shapes.json, meshes.json and sounds.json, and the GLB bounds table (files.ts
// GLB_BOUNDS_KEY) that collision shapes read.
import { join, relative } from "node:path";
import { GLB_BOUNDS_KEY } from "./files.ts";
import { NodeFiles } from "./node_files.ts";

const files = new NodeFiles();

/** Every .json file under `base`, keyed as `<prefix>/<path relative to base>`, and the bounds of each .glb file. */
function collect(base: string, prefix: string, out: Record<string, string>, bounds: Record<string, number[]>, dir = base): void {
  for (const name of files.list(dir)) {
    if (name.startsWith(".")) continue;
    const full = join(dir, name);
    const key = `${prefix}/${relative(base, full)}`;
    if (files.isDir(full)) collect(base, prefix, out, bounds, full);
    else if (name.endsWith(".json")) out[key] = files.read(full) ?? "";
    else if (name.endsWith(".glb")) {
      const b = files.glbBounds(full);
      if (b) bounds[key] = [...b.min, ...b.max];
    }
  }
}

/** The bundle of `<dataRoot>/<game>`, or null when there is no such game folder. */
export function bundle(dataRoot: string, game: string): Record<string, string> | null {
  const gameDir = join(dataRoot, game);
  if (!/^[\w-]+$/.test(game) || !files.isDir(gameDir)) return null;
  const out: Record<string, string> = {};
  const bounds: Record<string, number[]> = {};
  collect(gameDir, "game", out, bounds);
  collect(join(dataRoot, "lib"), "lib", out, bounds);
  out[GLB_BOUNDS_KEY] = JSON.stringify(bounds);
  for (const lib of ["shapes.json", "meshes.json", "sounds.json"]) {
    const text = files.read(join(dataRoot, lib));
    if (text !== null) out[lib] = text;
  }
  return out;
}
