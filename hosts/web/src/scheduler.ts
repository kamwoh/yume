// The four-phase tick loop and the effect write buffer. Mirrors
// phase_scheduler.gd: input → decide → commit → react, with the same
// flush points, signal drains, chance rolls (ADR 0095) and once ledger.
// Not in this host yet: lod, scope tiers, overlap events.
import type { Env } from "./env.ts";
import { raise } from "./env.ts";
import { apply, pushSignal } from "./effects.ts";
import { type Ctx, matches, run } from "./query.ts";
import { SpecRandom } from "./random.ts";
import type { RelationChange } from "./relations.ts";
import { Rule } from "./rule.ts";
import { type Dict, isDict, toInt } from "./value.ts";

const FIRED_RULES_KEY = "_fired_rules";
const CALENDAR_UNITS_KEY = "calendar_units";

type Queued = { effect: Dict; ctx: Ctx };

export class PhaseScheduler {
  env: Env;
  rulesByTrigger = new Map<string, Rule[]>();
  tickCount = 0;
  inputQueue: { action: string; params: Dict }[] = [];
  effectBuffer: Queued[] = [];
  private relationChanges: RelationChange[] = [];
  private advancing = false;
  private topoWarned = false;

  constructor(env: Env) {
    this.env = env;
    env.dispatchLifecycle = (kind, id) => this.dispatchLifecycle(kind, id);
    env.advanceCalendar = (units) => this.advanceCalendar(units);
    env.relations.onChange = (c) => this.relationChanges.push(c);
  }

  registerRules(rules: Rule[]): void {
    this.rulesByTrigger.clear();
    this.appendRules(rules);
  }

  appendRules(rules: Rule[]): void {
    for (const r of rules) {
      const tt = r.triggerType();
      if (!this.rulesByTrigger.has(tt)) this.rulesByTrigger.set(tt, []);
      this.rulesByTrigger.get(tt)!.push(r);
    }
    for (const bucket of this.rulesByTrigger.values()) this.topoSort(bucket);
  }

  ruleById(id: string): Rule | null {
    for (const b of this.rulesByTrigger.values()) for (const r of b) if (r.id === id) return r;
    return null;
  }

  /** The bubble pass of _topo_sort_bucket: swap neighbours until stable. */
  private topoSort(bucket: Rule[]): void {
    const maxPasses = bucket.length * bucket.length + 1;
    let passes = 0;
    let changed = true;
    while (changed && passes < maxPasses) {
      changed = false;
      for (let i = 0; i < bucket.length - 1; i++) {
        const a = bucket[i];
        const b = bucket[i + 1];
        if (a.runsAfter(b) && !b.runsAfter(a)) {
          bucket[i] = b;
          bucket[i + 1] = a;
          changed = true;
        }
      }
      passes++;
    }
    if (changed && !this.topoWarned) {
      raise(this.env, "scheduler.topo_cycle", "before/after hints may contain a cycle", "warning");
      this.topoWarned = true;
    }
  }

  queueInput(action: string, params: Dict = {}): void {
    const actor = String(params.actor ?? "");
    for (const ev of this.inputQueue) {
      if (ev.action === action && String(ev.params.actor ?? "") === actor) return;
    }
    this.inputQueue.push({ action, params });
  }

  tick(): void {
    this.tickCount++;
    this.env.world.tick = this.tickCount;
    this.phaseInput();
    this.flush();
    this.drainSignals("decide");
    this.phaseDecide();
    this.flush();
    this.drainSignals("react");
    this.flush();
    this.phaseReact();
    this.flush();
  }

  advanceCalendar(units: number): void {
    if (units <= 0) return;
    if (this.advancing) {
      raise(this.env, "time.reentrant_advance", "advance_time called from inside a scheduled rule — ignored", "warning");
      return;
    }
    this.advancing = true;
    const rules = this.rulesByTrigger.get("scheduled") ?? [];
    for (let i = 0; i < units; i++) {
      const now = toInt(this.env.world[CALENDAR_UNITS_KEY] ?? 0) + 1;
      this.env.world[CALENDAR_UNITS_KEY] = now;
      for (const r of rules) {
        const every = toInt(r.param("every", 1));
        if (every <= 0 || now % every !== 0) continue;
        this.fireScan(r);
      }
      this.flush();
    }
    this.advancing = false;
    pushSignal(this.env, "time_advanced", { units });
  }

  private dispatchLifecycle(kind: string, id: string): void {
    for (const r of this.rulesByTrigger.get(kind) ?? []) this.fireLifecycle(r, id, "commit");
  }

  private phaseInput(): void {
    if (this.inputQueue.length === 0) return;
    const events = [...this.inputQueue];
    this.inputQueue = [];
    const rules = this.rulesByTrigger.get("input") ?? [];
    for (const ev of events) {
      for (const r of rules) {
        if (String(r.param("action", "")) !== ev.action) continue;
        this.firePayload(r, { ...ev.params }, "input");
      }
    }
  }

  private phaseDecide(): void {
    for (const r of this.rulesByTrigger.get("tick") ?? []) {
      const interval = toInt(r.param("interval", 1));
      if (interval <= 0 || this.tickCount % interval !== 0) continue;
      this.fireScan(r);
    }
  }

  private phaseReact(): void {
    for (const r of this.rulesByTrigger.get("contact") ?? []) this.fireContact(r);
    if (this.relationChanges.length > 0) {
      const changes = [...this.relationChanges];
      this.relationChanges = [];
      const rules = this.rulesByTrigger.get("relation_changed") ?? [];
      for (const ch of changes) {
        for (const r of rules) {
          if ("relation" in r.trigger && String(r.trigger.relation) !== ch.type) continue;
          if ("change" in r.trigger && String(r.trigger.change) !== ch.change) continue;
          this.firePayload(r, { from: ch.from, to: ch.to, self: ch.from }, "react");
        }
      }
    }
  }

  private fireContact(r: Rule): void {
    if (r.chance >= 1 && this.onceSpent(r)) return;
    const q = r.query;
    if (!q || !isDict(q.a) || !isDict(q.b)) return;
    const radius = "radius" in q ? Number(q.radius) : 1;
    const oncePerA = Boolean(q.once_per_a ?? false);
    for (const a of run(q.a, this.env, {})) {
      const bSpec: Dict = { ...q.b, radius };
      for (const b of run(bSpec, this.env, { _origin_position: a.planarPosition(), self: a.id })) {
        if (a === b) continue;
        if (r.chance < 1 && SpecRandom.shared.randf() > r.chance) continue;
        const ctx: Ctx = { a: a.id, b: b.id, a_entity: a, b_entity: b, _phase: "react" };
        if (r.require && !this.requireOk(r.require, ctx)) continue;
        this.fireEffects(r, ctx);
        if (oncePerA) break;
      }
    }
  }

  private drainSignals(phase: string): void {
    if (this.env.signalBuffer.length === 0) return;
    const sigs = [...this.env.signalBuffer];
    this.env.signalBuffer.length = 0;
    const rules = this.rulesByTrigger.get("signal") ?? [];
    for (const s of sigs) {
      for (const r of rules) {
        if (String(r.param("name", "")) !== s.name) continue;
        this.firePayload(r, { ...s.payload }, phase);
      }
    }
  }

  fireScan(r: Rule): void {
    if (r.chance < 1 && SpecRandom.shared.randf() > r.chance) return;
    if (this.onceSpent(r)) return;
    const base: Ctx = { _phase: "decide" };
    if (r.query) {
      for (const e of run(r.query, this.env, base)) {
        const ctx: Ctx = { ...base, self: e.id, self_entity: e };
        if (r.require && !this.requireOk(r.require, ctx)) continue;
        this.fireEffects(r, ctx);
      }
    } else {
      if (r.require && !this.requireOk(r.require, base)) return;
      this.fireEffects(r, base);
    }
  }

  private firePayload(r: Rule, payload: Ctx, phase: string): void {
    if (r.chance < 1 && SpecRandom.shared.randf() > r.chance) return;
    if (this.onceSpent(r)) return;
    const base: Ctx = { ...payload, _phase: phase };
    if (r.require && !this.requireOk(r.require, base)) return;
    if (r.query) {
      for (const e of run(r.query, this.env, base)) this.fireEffects(r, { ...base, self: e.id, self_entity: e });
    } else {
      this.fireEffects(r, base);
    }
  }

  private fireLifecycle(r: Rule, id: string, phase: string): void {
    const e = this.env.entities.get(id);
    if (!e) return;
    const ctx: Ctx = { self: id, self_entity: e, _phase: phase };
    if (r.query && !matches(e, r.query, this.env, ctx)) return;
    if (r.require && !this.requireOk(r.require, ctx)) return;
    if (r.chance < 1 && SpecRandom.shared.randf() > r.chance) return;
    this.fireEffects(r, ctx);
  }

  private requireOk(req: Dict, ctx: Ctx): boolean {
    for (const name of Object.keys(req)) {
      const id = ctx[name];
      if (id === null || id === undefined) return false;
      const e = this.env.entities.get(typeof id === "string" ? id : String(id));
      if (!e) return false;
      if (!matches(e, isDict(req[name]) ? (req[name] as Dict) : {}, this.env, ctx)) return false;
    }
    return true;
  }

  private fireEffects(r: Rule, ctx: Ctx): void {
    if (!this.claimOnce(r, ctx)) return;
    for (const e of r.effects) this.effectBuffer.push({ effect: e, ctx: { ...ctx, _rule_id: r.id } });
  }

  private onceSpent(r: Rule): boolean {
    if (!r.once) return false;
    const ledger = this.env.world[FIRED_RULES_KEY];
    return isDict(ledger) && r.id in ledger;
  }

  private claimOnce(r: Rule, ctx: Ctx): boolean {
    if (!r.once && r.oncePer === "") return true;
    let ledger = this.env.world[FIRED_RULES_KEY];
    if (!isDict(ledger)) ledger = {};
    if (r.once) {
      if (r.id in ledger) return false;
      ledger[r.id] = true;
      this.env.world[FIRED_RULES_KEY] = ledger;
      return true;
    }
    const subject = ctx[r.oncePer];
    const s = subject === undefined || subject === null ? "" : String(subject);
    if (s === "") return true;
    let per = ledger[r.id];
    if (!isDict(per)) per = {};
    if (s in per) return false;
    per[s] = true;
    ledger[r.id] = per;
    this.env.world[FIRED_RULES_KEY] = ledger;
    return true;
  }

  /** Apply the buffered effects. Effects queued while applying wait for the next flush. */
  flush(): void {
    if (this.effectBuffer.length === 0) return;
    const batch = this.effectBuffer;
    this.effectBuffer = [];
    for (const q of batch) apply(q.effect, this.env, q.ctx);
  }
}
