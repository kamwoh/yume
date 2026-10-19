// Files on disk, for the CLI, the tests and the dev server.
import { closeSync, existsSync, openSync, readFileSync, readSync, readdirSync, statSync } from "node:fs";
import type { Files } from "./files.ts";
import { type Bounds, boundsOfGltf, glbJson } from "./glb.ts";

/** The header and JSON chunk of a GLB file. A large model is not read in full. */
export function readGlbHead(path: string): Uint8Array | null {
  if (!existsSync(path) || statSync(path).isDirectory()) return null;
  const fd = openSync(path, "r");
  try {
    const head = new Uint8Array(20);
    if (readSync(fd, head, 0, 20, 0) < 20) return null;
    const len = new DataView(head.buffer).getUint32(12, true);
    const out = new Uint8Array(20 + len);
    out.set(head);
    readSync(fd, out, 20, len, 20);
    return out;
  } finally {
    closeSync(fd);
  }
}

export class NodeFiles implements Files {
  exists(path: string): boolean {
    return existsSync(path);
  }
  isDir(path: string): boolean {
    return existsSync(path) && statSync(path).isDirectory();
  }
  read(path: string): string | null {
    return existsSync(path) && !statSync(path).isDirectory() ? readFileSync(path, "utf8") : null;
  }
  list(dir: string): string[] {
    return existsSync(dir) ? readdirSync(dir).sort() : [];
  }
  private bounds = new Map<string, Bounds | null>();
  glbBounds(path: string): Bounds | null {
    if (!this.bounds.has(path)) {
      const head = readGlbHead(path);
      this.bounds.set(path, head ? boundsOfGltf(glbJson(head)) : null);
    }
    return this.bounds.get(path)!;
  }
}
