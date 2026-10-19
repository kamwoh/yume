// The zone-state store (ADR 0031). Mirrors zone_store.gd: a flat map of
// zone id to {type, state, contains, parent}, loaded from world/zones.json.
// The store adds no aggregation: a write to a child zone does not reach its
// parent.
import type { Env } from "./env.ts";
import { raise } from "./env.ts";
import { type Dict, type Value, deepCopy, isDict, toFloat } from "./value.ts";

type Zone = { type: string; state: Dict; contains: string[]; parent: string };

export class ZoneStore {
  zones = new Map<string, Zone>();

  /** ZoneStore.load_from_dict: register the zones, link the parents, then look for a cycle. */
  loadFromDict(cfg: unknown, env: Env): void {
    this.zones.clear();
    if (!isDict(cfg) || !Array.isArray(cfg.zones)) return;
    for (const raw of cfg.zones) {
      if (!isDict(raw)) {
        raise(env, "zone.invalid_entry", "zone entry not a dict");
        continue;
      }
      const id = String(raw.id ?? "");
      if (id === "") {
        raise(env, "zone.missing_id", "zone missing id");
        continue;
      }
      if (this.zones.has(id)) {
        raise(env, "zone.duplicate_id", `duplicate zone id: '${id}'`);
        continue;
      }
      const state = isDict(raw.state_init) ? (deepCopy(raw.state_init) as Dict) : {};
      const contains = Array.isArray(raw.contains) ? raw.contains.map(String) : [];
      this.zones.set(id, { type: String(raw.type ?? ""), state, contains, parent: "" });
    }
    for (const [id, z] of this.zones) {
      for (const cid of z.contains) {
        const child = this.zones.get(cid);
        if (!child) {
          raise(env, "zone.unknown_contained", `zone '${id}' lists unknown child '${cid}' in contains`);
          continue;
        }
        if (child.parent !== "") {
          raise(env, "zone.multi_parent", `zone '${cid}' contained by both '${child.parent}' and '${id}'`);
          continue;
        }
        child.parent = id;
      }
    }
    for (const id of this.zones.keys()) {
      const cycle = this.detectCycle(id, []);
      if (cycle !== "") {
        raise(env, "zone.cycle_detected", `zone hierarchy contains a cycle: ${cycle}`);
        break;
      }
    }
  }

  private detectCycle(start: string, path: string[]): string {
    const i = path.indexOf(start);
    if (i >= 0) return [...path.slice(i), start].join(" → ");
    const z = this.zones.get(start);
    if (!z) return "";
    for (const cid of z.contains) {
      const sub = this.detectCycle(cid, [...path, start]);
      if (sub !== "") return sub;
    }
    return "";
  }

  has(id: string): boolean {
    return this.zones.has(id);
  }

  setField(id: string, field: string, v: Value): void {
    const z = this.zones.get(id);
    if (z) z.state[field] = v;
  }

  /** ZoneStore.add_field: a missing field starts at 0. */
  addField(id: string, field: string, delta: number): void {
    const z = this.zones.get(id);
    if (z) z.state[field] = toFloat(z.state[field] ?? 0) + delta;
  }

  /** ZoneStore.clamp_field: a missing field stays missing. */
  clampField(id: string, field: string, lo: number, hi: number): void {
    const z = this.zones.get(id);
    if (!z || !(field in z.state)) return;
    const x = toFloat(z.state[field]);
    z.state[field] = Math.min(Math.max(x, lo), hi);
  }

  /** ZoneStore.binding_snapshot: {zone id: state}, the `zone` root of a formula. */
  bindingSnapshot(): Dict {
    const out: Dict = {};
    for (const [id, z] of this.zones) out[id] = z.state;
    return out;
  }
}
