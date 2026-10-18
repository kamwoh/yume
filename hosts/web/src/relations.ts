// Typed directed edges with optional edge state. Mirrors relation_store.gd,
// including the order of targets and sources (insertion order).
import { type Dict, type Value, deepCopy, toFloat } from "./value.ts";

export type RelationChange = { change: "added" | "removed"; type: string; from: string; to: string };

export class RelationStore {
  private fromIdx = new Map<string, string[]>();
  private toIdx = new Map<string, string[]>();
  private edgeStates = new Map<string, Dict>();
  onChange: ((c: RelationChange) => void) | null = null;

  relate(type: string, from: string, to: string, state: Dict = {}): void {
    const fk = key(type, from);
    const tos = this.fromIdx.get(fk) ?? [];
    this.mergeEdgeState(type, from, to, state);
    if (tos.includes(to)) return;
    if (!this.fromIdx.has(fk)) this.fromIdx.set(fk, tos);
    tos.push(to);
    const tk = key(type, to);
    if (!this.toIdx.has(tk)) this.toIdx.set(tk, []);
    this.toIdx.get(tk)!.push(from);
    this.onChange?.({ change: "added", type, from, to });
  }

  unrelate(type: string, from: string, to: string): void {
    const tos = this.fromIdx.get(key(type, from));
    if (!tos || !tos.includes(to)) return;
    tos.splice(tos.indexOf(to), 1);
    const froms = this.toIdx.get(key(type, to));
    if (froms && froms.includes(from)) froms.splice(froms.indexOf(from), 1);
    this.edgeStates.delete(ekey(type, from, to));
    this.onChange?.({ change: "removed", type, from, to });
  }

  transferTo(type: string, from: string, oldTo: string, newTo: string): void {
    const carried = deepCopy(this.edgeState(type, from, oldTo));
    this.unrelate(type, from, oldTo);
    this.relate(type, from, newTo, carried);
  }

  transferFrom(type: string, oldFrom: string, newFrom: string, to: string): void {
    const carried = deepCopy(this.edgeState(type, oldFrom, to));
    this.unrelate(type, oldFrom, to);
    this.relate(type, newFrom, to, carried);
  }

  clearEntity(id: string): void {
    const drops: [string, string, string][] = [];
    for (const [k, tos] of this.fromIdx) {
      const i = k.indexOf("::");
      const type = k.slice(0, i);
      const src = k.slice(i + 2);
      for (const to of [...tos]) if (src === id || to === id) drops.push([type, src, to]);
    }
    for (const [t, f, to] of drops) this.unrelate(t, f, to);
  }

  edgeState(type: string, from: string, to: string): Dict {
    return this.edgeStates.get(ekey(type, from, to)) ?? {};
  }

  setEdgeField(type: string, from: string, to: string, field: string, value: Value): boolean {
    if (field === "" || !this.hasEdge(type, from, to)) return false;
    const k = ekey(type, from, to);
    if (!this.edgeStates.has(k)) this.edgeStates.set(k, {});
    this.edgeStates.get(k)![field] = value;
    return true;
  }

  addEdgeField(type: string, from: string, to: string, field: string, amount: number): boolean {
    if (field === "" || !this.hasEdge(type, from, to)) return false;
    const k = ekey(type, from, to);
    if (!this.edgeStates.has(k)) this.edgeStates.set(k, {});
    const d = this.edgeStates.get(k)!;
    d[field] = toFloat(d[field] ?? 0) + amount;
    return true;
  }

  clampEdgeField(type: string, from: string, to: string, field: string, lo: number, hi: number): boolean {
    if (field === "" || !this.hasEdge(type, from, to)) return false;
    const d = this.edgeStates.get(ekey(type, from, to));
    if (!d || !(field in d)) return false;
    d[field] = Math.min(Math.max(toFloat(d[field]), lo), hi);
    return true;
  }

  private mergeEdgeState(type: string, from: string, to: string, state: Dict): void {
    if (Object.keys(state).length === 0) return;
    const k = ekey(type, from, to);
    if (!this.edgeStates.has(k)) this.edgeStates.set(k, {});
    Object.assign(this.edgeStates.get(k)!, state);
  }

  targets(type: string, from: string): string[] {
    return [...(this.fromIdx.get(key(type, from)) ?? [])];
  }
  sources(type: string, to: string): string[] {
    return [...(this.toIdx.get(key(type, to)) ?? [])];
  }
  hasEdge(type: string, from: string, to: string): boolean {
    return (this.fromIdx.get(key(type, from)) ?? []).includes(to);
  }
  count(type: string): number {
    let n = 0;
    for (const [k, tos] of this.fromIdx) if (k.startsWith(type + "::")) n += tos.length;
    return n;
  }
}

function key(t: string, id: string): string {
  return t + "::" + id;
}
function ekey(t: string, f: string, to: string): string {
  return t + "::" + f + "::" + to;
}
