// The shared environment that rules, queries and effects read. Mirrors the
// env Dictionary of the reference interpreter (world.gd _build_env).
import type { Entity } from "./entity.ts";
import type { PhysicsHost } from "./physics.ts";
import type { RelationStore } from "./relations.ts";
import type { Dict } from "./value.ts";

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
  /** env._pending_level_transition: set by transition_level, drained after the tick. */
  pendingLevel: string;
  /** env._pending_world_reset: set by reset_world, drained after the tick. */
  pendingReset: boolean;
  /** ADR 0070: area overlaps from the physics host, drained in the react phase. */
  overlapEvents: { a: string; b: string; change: "enter" | "exit" }[];
  /** The physics host (ADR 0095 phase 3), or null for a world with no bodies. */
  physics: PhysicsHost | null;
}

export function raise(env: Env, code: string, message: string, severity: "error" | "warning" = "error"): void {
  env.errors.push({ code, message, severity });
}
