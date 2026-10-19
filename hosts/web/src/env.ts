// The shared environment that rules, queries and effects read. Mirrors the
// env Dictionary of the reference interpreter (world.gd _build_env).
import type { Entity } from "./entity.ts";
import type { NavGrid } from "./pathfinding.ts";
import type { PhysicsHost } from "./physics.ts";
import type { RelationStore } from "./relations.ts";
import type { Dict } from "./value.ts";
import type { ZoneStore } from "./zones.ts";

export type Signal = { name: string; payload: Dict };

export type EngineErrorRecord = { code: string; message: string; severity: "error" | "warning" };

export interface Env {
  entities: Map<string, Entity>;
  defs: Map<string, Dict>;
  relations: RelationStore;
  world: Dict;
  signalBuffer: Signal[];
  nextId: { n: number };
  errors: EngineErrorRecord[];
  /** Shell effects (screens, toasts, save) write here and change nothing else (ADR 0095 phase 1). */
  shellEvents: Dict[];
  dispatchLifecycle: ((kind: "spawn" | "despawn", id: string) => void) | null;
  advanceCalendar: ((units: number) => void) | null;
  /** PhaseScheduler.queue_input, for queue_input_for_actor (ADR 0016). */
  queueInput: ((action: string, params: Dict) => void) | null;
  /** env._pending_level_transition: set by transition_level, drained after the tick. */
  pendingLevel: string;
  /** env._pending_world_reset: set by reset_world, drained after the tick. */
  pendingReset: boolean;
  /** env._pending_save and env._pending_load: a slot number, drained after the tick. */
  pendingSave: number | null;
  pendingLoad: number | null;
  /** ADR 0070: area overlaps from the physics host, drained in the react phase. */
  overlapEvents: { a: string; b: string; change: "enter" | "exit" }[];
  /** The physics host (ADR 0095 phase 3), or null for a world with no bodies. */
  physics: PhysicsHost | null;
  /** env._pending_level_call (ADR 0077): the sub-level that level_call enters, drained after the tick. */
  pendingLevelCall: string;
  /** env._pending_level_return (ADR 0077): {level, return_signal, result}, drained after the tick. */
  pendingLevelReturn: Dict | null;
  /** env._pending_active_actor (ADR 0016): set by switch_actor, drained after the tick. */
  pendingActiveActor: string | null;
  /** env.zone_store (ADR 0031), or null before world/zones.json loads. */
  zones: ZoneStore | null;
  /** env._navigation_region (ADR 0024): the walkable grid of the level, or null. */
  navGrid: NavGrid | null;
}

export function raise(env: Env, code: string, message: string, severity: "error" | "warning" = "error"): void {
  env.errors.push({ code, message, severity });
}
