// The file access of the core. The core never imports node:fs, so the same
// code runs in Node and in a browser. Node uses NodeFiles (node_files.ts).
// The browser uses MemoryFiles, filled from one JSON bundle.
import type { Bounds } from "./glb.ts";

/** The bundle entry that holds the bounds of each GLB file: path → [min x, y, z, max x, y, z]. */
export const GLB_BOUNDS_KEY = "glb_bounds.json";

export interface Files {
  exists(path: string): boolean;
  isDir(path: string): boolean;
  /** The text of a file, or null when there is no file. */
  read(path: string): string | null;
  /** The entry names of a folder, sorted. */
  list(dir: string): string[];
  /** The POSITION bounds of a GLB file (glb.ts), or null. Collision shapes read it (phase 3). */
  glbBounds(path: string): Bounds | null;
}

/** POSIX join: one slash between parts, no "." or ".." handling. */
export function join(...parts: string[]): string {
  return parts
    .filter((p) => p !== "")
    .map((p, i) => (i === 0 ? p.replace(/\/+$/, "") : p.replace(/^\/+|\/+$/g, "")))
    .join("/");
}

export function dirname(path: string): string {
  const p = path.replace(/\/+$/, "");
  const i = p.lastIndexOf("/");
  return i <= 0 ? (i === 0 ? "/" : ".") : p.slice(0, i);
}

/** Files from a map of path to text. A folder exists when a file sits under it. */
export class MemoryFiles implements Files {
  private files: Map<string, string>;
  private dirs = new Map<string, Set<string>>();

  constructor(entries: Record<string, string>) {
    this.files = new Map(Object.entries(entries));
    for (const path of this.files.keys()) {
      let child = path;
      let dir = dirname(path);
      while (dir !== "." && dir !== "/") {
        if (!this.dirs.has(dir)) this.dirs.set(dir, new Set());
        this.dirs.get(dir)!.add(child.slice(dir.length + 1));
        child = dir;
        dir = dirname(dir);
      }
    }
  }

  exists(path: string): boolean {
    return this.files.has(path) || this.dirs.has(path);
  }
  isDir(path: string): boolean {
    return this.dirs.has(path);
  }
  read(path: string): string | null {
    return this.files.get(path) ?? null;
  }
  list(dir: string): string[] {
    return [...(this.dirs.get(dir.replace(/\/+$/, "")) ?? [])].sort();
  }

  private boundsTable: Record<string, number[]> | null = null;

  glbBounds(path: string): Bounds | null {
    if (this.boundsTable === null) {
      try {
        this.boundsTable = JSON.parse(this.files.get(GLB_BOUNDS_KEY) ?? "{}");
      } catch {
        this.boundsTable = {};
      }
    }
    const b = this.boundsTable![path];
    return Array.isArray(b) && b.length === 6 ? { min: [b[0], b[1], b[2]], max: [b[3], b[4], b[5]] } : null;
  }
}
