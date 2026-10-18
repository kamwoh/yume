// The Rule primitive. Mirrors rule.gd: {id, trigger, query, require,
// chance, effect, before, after, scope, once, once_per}.
import { type Dict, deepCopy, isDict, toFloat } from "./value.ts";

export const VALID_TRIGGERS = [
  "tick", "frame_tick", "contact", "signal", "input", "spawn", "despawn",
  "relation_changed", "scheduled", "overlap",
];

export class Rule {
  id = "";
  trigger: Dict = {};
  query: Dict | null = null;
  require: Dict | null = null;
  chance = 1;
  effects: Dict[] = [];
  before: string[] = [];
  after: string[] = [];
  scope = "";
  once = false;
  oncePer = "";

  static fromDict(d: Dict): Rule {
    const r = new Rule();
    r.id = String(d.id ?? "");
    r.trigger = isDict(d.trigger) ? deepCopy(d.trigger) : {};
    if (isDict(d.query)) r.query = deepCopy(d.query);
    if (isDict(d.require)) r.require = deepCopy(d.require);
    r.chance = "chance" in d ? toFloat(d.chance) : 1;
    const e = d.effect;
    r.effects = isDict(e) ? [deepCopy(e)] : Array.isArray(e) ? (deepCopy(e).filter(isDict) as Dict[]) : [];
    r.before = asStrings(d.before);
    r.after = asStrings(d.after);
    r.scope = String(d.scope ?? "");
    r.once = Boolean(d.once ?? false);
    r.oncePer = String(d.once_per ?? "");
    return r;
  }

  triggerType(): string {
    return String(this.trigger.type ?? "");
  }
  param(k: string, d: unknown = null): unknown {
    return k in this.trigger ? this.trigger[k] : d;
  }
  runsAfter(o: Rule): boolean {
    return this.after.includes(o.id) || o.before.includes(this.id);
  }
}

function asStrings(v: unknown): string[] {
  if (typeof v === "string") return [v];
  if (Array.isArray(v)) return v.map((x) => String(x));
  return [];
}
