// Saves (ADR 0010). Mirrors save_state.gd and save_load_coordinator.gd.
// Where a save lives is host-defined (ADR 0086): Godot writes
// user://saves/<game>/slot_N.json. This host takes a SaveStore. A
// scenario run keeps the saves in memory for the whole process. The
// browser viewer keeps them in localStorage.
import type { Env } from "./env.ts";
import { type Dict, Vec2, Vec3, isDict } from "./value.ts";

export interface SaveStore {
  read(game: string, slot: number): string | null;
  write(game: string, slot: number, text: string): void;
}

/** Saves in memory, shared by every world of one process, as Godot's user:// is shared by every run. */
export class MemorySaveStore implements SaveStore {
  static readonly shared = new MemorySaveStore();
  private slots = new Map<string, string>();
  read(game: string, slot: number): string | null {
    return this.slots.get(`${game}/${slot}`) ?? null;
  }
  write(game: string, slot: number, text: string): void {
    this.slots.set(`${game}/${slot}`, text);
  }
}

/** SaveState.has_any_save. */
export function hasAnySave(store: SaveStore, game: string, slots: number): boolean {
  for (let s = 0; s < slots; s++) if (store.read(game, s) !== null) return true;
  return false;
}

/** SaveState.save_to_slot: the payload of one save. */
export function buildPayload(env: Env, policy: Dict, game: string, tick: number): Dict {
  const ws: Dict = {};
  for (const k of Array.isArray(policy.world_state_keys) ? policy.world_state_keys.map(String) : []) {
    if (k in env.world) ws[k] = toJson(env.world[k]) as Dict[string];
  }
  const ents: Dict[] = [];
  const tags = Array.isArray(policy.entity_tags_persistent) ? policy.entity_tags_persistent.map(String) : [];
  const blacklist = Array.isArray(policy.entity_state_blacklist) ? policy.entity_state_blacklist.map(String) : [];
  if (tags.length > 0) {
    for (const [id, e] of env.entities) {
      if (!tags.some((t) => e.hasTag(t))) continue;
      const state: Dict = {};
      for (const f of Object.keys(e.state)) if (!matchesGlob(f, blacklist)) state[f] = toJson(e.state[f]) as Dict[string];
      ents.push({ id, def: e.defId, position: toJson(e.position()) as Dict[string], state });
    }
  }
  const rels: Dict[] = [];
  for (const t of Array.isArray(policy.relations_persistent) ? policy.relations_persistent.map(String) : []) {
    for (const p of env.relations.allOfType(t)) rels.push({ type: t, from: p.from, to: p.to });
  }
  return {
    version: Number(policy.version ?? 1),
    _meta: { game, tick },
    world_state: ws,
    persistent_entities: ents,
    relations: rels,
    zone_state: {},
  };
}

/** SaveState.read_slot: the payload, or the reason it is not usable. */
export function readSlot(store: SaveStore, game: string, slot: number, policy: Dict): { ok: boolean; error: string; payload: Dict } {
  const text = store.read(game, slot);
  if (text === null) return { ok: false, error: "no_such_save", payload: {} };
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return { ok: false, error: "invalid_json", payload: {} };
  }
  if (!isDict(data)) return { ok: false, error: "invalid_json", payload: {} };
  // Refuse a version mismatch: no migrations (ADR 0010).
  if (Number(data.version ?? -1) !== Number(policy.version ?? 1)) return { ok: false, error: "version_mismatch", payload: data };
  return { ok: true, error: "", payload: data };
}

/** SaveState._matches_any_glob: "x*" a prefix, "*x" a suffix, else the whole name. */
function matchesGlob(s: string, patterns: string[]): boolean {
  return patterns.some((p) => (p.endsWith("*") ? s.startsWith(p.slice(0, -1)) : p.startsWith("*") ? s.endsWith(p.slice(1)) : s === p));
}

/** A value as JSON: a vector becomes an array, as JSON.stringify of a Godot vector does in a save. */
function toJson(v: unknown): unknown {
  if (v instanceof Vec2) return [v.x, v.y];
  if (v instanceof Vec3) return [v.x, v.y, v.z];
  if (Array.isArray(v)) return v.map(toJson);
  if (isDict(v)) {
    const out: Dict = {};
    for (const k of Object.keys(v)) out[k] = toJson(v[k]) as Dict[string];
    return out;
  }
  return v;
}
