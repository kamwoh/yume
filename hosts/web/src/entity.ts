// The Entity primitive: id, def, tags, properties, state. Mirrors
// godot/scripts/engine/core/entity.gd.
import { type Dict, type Value, Vec2, Vec3, deepCopy, isDict, normalizePosition, toFloat } from "./value.ts";

export class Entity {
  defId = "";
  id = "";
  properties: Dict = {};
  state: Dict = {};
  tags: string[] = [];
  visual: Dict = {};

  static create(def: Dict, id: string, overrides: Dict = {}): Entity {
    const e = new Entity();
    e.defId = String(def.id ?? "");
    e.id = id;
    e.properties = deepCopy(isDict(def.properties) ? def.properties : {});
    e.state = deepCopy(isDict(def.state_init) ? def.state_init : {});
    for (const t of Array.isArray(def.tags) ? def.tags : []) e.tags.push(String(t));
    e.visual = deepCopy(isDict(def.visual) ? def.visual : {});
    e.state.position = "position" in e.state ? normalizePosition(e.state.position) : new Vec2(0, 0);
    if ("velocity" in e.state) e.state.velocity = normalizePosition(e.state.velocity);
    if (Object.keys(overrides).length > 0) e.applyOverrides(overrides);
    return e;
  }

  private applyOverrides(o: Dict): void {
    if (isDict(o.state)) {
      for (const k of Object.keys(o.state)) {
        let v = o.state[k];
        if ((k === "position" || k === "velocity") && Array.isArray(v)) v = normalizePosition(v);
        this.state[k] = v;
      }
    }
    if (isDict(o.properties)) for (const k of Object.keys(o.properties)) this.properties[k] = o.properties[k];
    if (Array.isArray(o.tags)) {
      for (const t of o.tags) if (!this.tags.includes(String(t))) this.tags.push(String(t));
    }
    if (isDict(o.visual)) {
      for (const k of Object.keys(o.visual)) {
        const v = o.visual[k];
        if (k === "params" && isDict(v) && isDict(this.visual.params)) Object.assign(this.visual.params, v);
        else this.visual[k] = v;
      }
    }
    if ("position" in o) this.state.position = normalizePosition(o.position);
  }

  hasTag(t: string): boolean {
    return this.tags.includes(t);
  }
  addTag(t: string): void {
    if (!this.hasTag(t)) this.tags.push(t);
  }
  removeTag(t: string): void {
    const i = this.tags.indexOf(t);
    if (i >= 0) this.tags.splice(i, 1);
  }
  getState(f: string, d: Value = null): Value {
    return f in this.state ? this.state[f] : d;
  }
  setState(f: string, v: Value): void {
    this.state[f] = v;
  }
  addState(f: string, delta: number): void {
    this.state[f] = toFloat(this.getState(f, 0)) + delta;
  }
  position(): Value {
    return this.getState("position", new Vec2(0, 0));
  }
  setPosition(p: Value): void {
    this.state.position = normalizePosition(p);
  }
  setVelocity(v: Value): void {
    this.state.velocity = normalizePosition(v);
  }
  planarPosition(): Vec2 {
    const p = this.state.position;
    if (p instanceof Vec2) return p;
    if (p instanceof Vec3) return new Vec2(p.x, p.z);
    if (Array.isArray(p) && p.length >= 2) return new Vec2(toFloat(p[0]), toFloat(p[1]));
    return new Vec2(0, 0);
  }
}
