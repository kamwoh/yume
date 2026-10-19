// The actor registry (ADR 0016). Mirrors actor_manager.gd: actors.json
// lists the actors, and each actor controls the first entity with its
// starting_entity_tag. With no actors.json, the registry holds one
// synthesized actor, "default_player", on the world's actor tag.
// AI policies (ADR 0018, control_mode "ai_policy") are not in this host.
import type { Entity } from "./entity.ts";
import { type Dict, isDict } from "./value.ts";

export class ActorManager {
  actors: Dict[] = [];
  byId = new Map<string, Dict>();
  activeActorId = "";

  /** ActorManager.load_or_synthesize. `data` is the parsed actors.json, or null. */
  static loadOrSynthesize(data: unknown, actorTagFallback: string): ActorManager {
    const am = new ActorManager();
    if (isDict(data)) {
      if (Array.isArray(data.actors)) am.actors = data.actors.filter(isDict);
      am.activeActorId = String(data.active_actor_id ?? "");
      if (am.activeActorId === "" && am.actors.length > 0) am.activeActorId = String(am.actors[0].id ?? "");
    }
    if (am.actors.length === 0) {
      am.actors = [{ id: "default_player", input_device: "keyboard", control_mode: "human", starting_entity_tag: actorTagFallback }];
      am.activeActorId = "default_player";
    }
    for (const a of am.actors) if ("id" in a) am.byId.set(String(a.id), a);
    return am;
  }

  /** ActorManager.resolve_actor_entity: the first entity with the actor's starting_entity_tag. */
  resolveActorEntity(actorId: string, entities: Map<string, Entity>): string {
    if (actorId === "") return "";
    const tag = String(this.byId.get(actorId)?.starting_entity_tag ?? "");
    if (tag === "") return "";
    for (const [id, e] of entities) if (e.hasTag(tag)) return id;
    return "";
  }

  /** ActorManager.resolve_active_entity. */
  resolveActiveEntity(entities: Map<string, Entity>): string {
    return this.resolveActorEntity(this.activeActorId, entities);
  }

  /** ActorManager.set_active: false for an unknown actor id. */
  setActive(actorId: string): boolean {
    if (!this.byId.has(actorId)) return false;
    this.activeActorId = actorId;
    return true;
  }
}
