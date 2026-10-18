// `@lib.` references, `$extends` and `$include`. Mirrors lib_resolver.gd.
// The library is the `lib/` folder next to the game folder.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { deepCopy, isDict } from "./value.ts";

const MAX_DEPTH = 8;

export class LibResolver {
  private cache = new Map<string, unknown>();

  constructor(libRoot: string) {
    if (existsSync(libRoot)) this.walk(libRoot, "");
  }

  private walk(dir: string, prefix: string): void {
    for (const entry of readdirSync(dir).sort()) {
      if (entry.startsWith(".")) continue;
      const full = join(dir, entry);
      if (statSync(full).isDirectory()) {
        this.walk(full, prefix === "" ? entry : `${prefix}.${entry}`);
      } else if (entry.endsWith(".json") && entry !== "manifest.json") {
        const base = entry.slice(0, -5);
        try {
          this.cache.set(prefix === "" ? base : `${prefix}.${base}`, JSON.parse(readFileSync(full, "utf8")));
        } catch {
          // A file that does not parse is skipped, as in the reference.
        }
      }
    }
  }

  resolve(value: unknown, depth = 0, visited: string[] = []): unknown {
    if (depth > MAX_DEPTH) return value;
    if (typeof value === "string") return value.startsWith("@lib.") ? this.ref(value, depth, visited) : value;
    if (isDict(value)) {
      if ("$extends" in value) return this.extendsOf(value, depth, visited);
      const out: Record<string, unknown> = {};
      for (const k of Object.keys(value)) out[k] = this.resolve(value[k], depth, visited);
      return out;
    }
    if (Array.isArray(value)) {
      const out: unknown[] = [];
      for (const item of value) {
        if (isDict(item) && "$include" in item) this.includeInto(out, item, depth, visited);
        else out.push(this.resolve(item, depth, visited));
      }
      return out;
    }
    return value;
  }

  private ref(ref: string, depth: number, visited: string[]): unknown {
    if (visited.includes(ref)) return null;
    const parts = ref.slice(5).split(".");
    for (let cut = parts.length; cut > 0; cut--) {
      const key = parts.slice(0, cut).join(".");
      if (!this.cache.has(key)) continue;
      let val: unknown = this.cache.get(key);
      for (let i = cut; i < parts.length; i++) {
        if (!isDict(val)) return ref;
        val = val[parts[i]];
        if (val === undefined || val === null) return ref;
      }
      const resolved = this.resolve(deepCopy(val), depth + 1, [...visited, ref]);
      if (isDict(resolved)) resolved._origin = ref;
      return resolved;
    }
    return ref;
  }

  private extendsOf(d: Record<string, unknown>, depth: number, visited: string[]): unknown {
    const base = this.resolve(d.$extends, depth + 1, visited);
    if (!isDict(base)) return d;
    const merged: Record<string, unknown> = deepCopy(base);
    for (const k of Object.keys(d)) {
      if (k === "$extends") continue;
      merged[k] = this.resolve(d[k], depth + 1, visited);
    }
    merged._origin = "$extends:" + String(d.$extends);
    return merged;
  }

  private includeInto(out: unknown[], item: Record<string, unknown>, depth: number, visited: string[]): void {
    const inc = item.$include;
    const refs = typeof inc === "string" ? [inc] : Array.isArray(inc) ? inc : [];
    for (const r of refs) {
      const resolved = this.resolve(r, depth + 1, visited);
      if (Array.isArray(resolved)) for (const el of resolved) out.push(this.resolve(el, depth + 1, visited));
    }
  }
}
