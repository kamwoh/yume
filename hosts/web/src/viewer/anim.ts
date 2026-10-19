// Animation (ADR 0035, ADR 0046) for the 3D viewer. Mirrors
// animation_director.gd (the state rules) and animation_translator.gd (the
// `animations` block of a library mesh as clips). three.js's
// AnimationMixer plays the clips, as Godot's AnimationPlayer does.
import * as THREE from "three";
import type { Entity } from "../entity.ts";
import { type Dict, Vec2, Vec3, equals, isDict } from "../value.ts";

/**
 * AnimationDirector._pick_state: the first rule that matches wins, and
 * `default` ends the list. The conditions are if_velocity_gt,
 * if_velocity_lt, if_state_eq, if_state_in and if_tag.
 */
export function pickState(rules: unknown[], e: Entity): string {
  for (const r of rules) {
    if (!isDict(r)) continue;
    if ("default" in r) return typeof r.default === "string" ? r.default : "state" in r ? String(r.state) : "default";
    if ("if_velocity_gt" in r && velLen(e) > Number(r.if_velocity_gt)) return String(r.state ?? "");
    if ("if_velocity_lt" in r && velLen(e) < Number(r.if_velocity_lt)) return String(r.state ?? "");
    if (isDict(r.if_state_eq)) {
      const spec = r.if_state_eq;
      const keys = Object.keys(spec);
      if (keys.length > 0 && keys.every((k) => equals(e.getState(k, null), spec[k]))) return String(r.state ?? "");
    }
    if (isDict(r.if_state_in)) {
      const spec = r.if_state_in;
      const keys = Object.keys(spec);
      if (keys.length > 0 && keys.every((k) => Array.isArray(spec[k]) && (spec[k] as unknown[]).some((v) => equals(v, e.getState(k, null))))) {
        return String(r.state ?? "");
      }
    }
    if ("if_tag" in r && e.hasTag(String(r.if_tag))) return String(r.state ?? "");
  }
  return "";
}

/** AnimationDirector._has_default_rule: the rules need a `default` fallback (animation.no_default). */
export function hasDefault(rules: unknown[]): boolean {
  return rules.some((r) => isDict(r) && "default" in r);
}

/** EntityMesh3D._build_clip_alias_map: state name → the clip name in the GLB. */
export function clipAliases(rules: unknown[]): Map<string, string> {
  const out = new Map<string, string>();
  for (const r of rules) {
    if (!isDict(r)) continue;
    const state = "default" in r ? (typeof r.default === "string" ? r.default : String(r.state ?? "")) : String(r.state ?? "");
    if (state !== "" && "clip_alias" in r) out.set(state, String(r.clip_alias));
  }
  return out;
}

function velLen(e: Entity): number {
  const v = e.getState("velocity", null);
  if (v instanceof Vec2) return Math.hypot(v.x, v.y);
  if (v instanceof Vec3) return Math.hypot(v.x, v.y, v.z);
  return 0;
}

/**
 * AnimationTranslator._build_animation: one clip of a library mesh. Each
 * axis array has N keys spaced evenly over [0, duration]. Translation adds
 * to the piece's rest position. Rotation and scale replace the rest value
 * on their axis. A shorter axis holds its last key.
 */
export function libraryClip(name: string, clip: Dict, root: THREE.Object3D): THREE.AnimationClip | null {
  const duration = Number(clip.duration ?? 1);
  if (!(duration > 0)) return null;
  const interp = String(clip.interp ?? "linear").toLowerCase();
  const mode = interp === "cubic" ? THREE.InterpolateSmooth : interp === "nearest" ? THREE.InterpolateDiscrete : THREE.InterpolateLinear;
  const groups = new Map<string, Dict>();
  for (const t of Array.isArray(clip.tracks) ? clip.tracks : []) {
    if (!isDict(t) || String(t.piece ?? "") === "") continue;
    for (const k of Object.keys(t)) {
      const m = /^(rotation|translation|scale)_([xyz])$/.exec(k);
      if (!m || !Array.isArray(t[k])) continue;
      const gk = `${String(t.piece)}|${m[1]}`;
      if (!groups.has(gk)) groups.set(gk, {});
      groups.get(gk)![m[2]] = t[k];
    }
  }
  const tracks: THREE.KeyframeTrack[] = [];
  for (const [gk, axes] of groups) {
    const [piece, cls] = gk.split("|");
    const node = root.getObjectByName(piece);
    const base =
      cls === "translation"
        ? (node?.position.toArray() ?? [0, 0, 0])
        : cls === "scale"
          ? (node?.scale.toArray() ?? [1, 1, 1])
          : node
            ? [node.rotation.x, node.rotation.y, node.rotation.z]
            : [0, 0, 0];
    const n = Math.max(...["x", "y", "z"].map((a) => (Array.isArray(axes[a]) ? (axes[a] as unknown[]).length : 0)));
    if (n === 0) continue;
    const step = n > 1 ? duration / (n - 1) : 0;
    const times: number[] = [];
    const values: number[] = [];
    for (let i = 0; i < n; i++) {
      const v = [...base];
      ["x", "y", "z"].forEach((a, ai) => {
        const arr = axes[a];
        if (!Array.isArray(arr) || arr.length === 0) return;
        const raw = Number(arr[Math.min(i, arr.length - 1)]);
        v[ai] = cls === "translation" ? base[ai] + raw : raw;
      });
      times.push(i * step);
      if (cls === "rotation") values.push(...new THREE.Quaternion().setFromEuler(new THREE.Euler(v[0], v[1], v[2], "YXZ")).toArray());
      else values.push(...v);
    }
    const path = `${piece}.${cls === "translation" ? "position" : cls === "scale" ? "scale" : "quaternion"}`;
    const track = cls === "rotation" ? new THREE.QuaternionKeyframeTrack(path, times, values) : new THREE.VectorKeyframeTrack(path, times, values);
    track.setInterpolation(cls === "rotation" && mode === THREE.InterpolateSmooth ? THREE.InterpolateLinear : mode);
    tracks.push(track);
  }
  return new THREE.AnimationClip(name, duration, tracks);
}

/** The state machine of one animated entity: the rules pick a state, and the mixer cross-fades to its clip. */
export class Animator {
  private mixer: THREE.AnimationMixer;
  private actions = new Map<string, THREE.AnimationAction>();
  private rules: unknown[];
  private aliases: Map<string, string>;
  private blend: number;
  private clipBlend: Dict;
  private active = "";
  private current: THREE.AnimationAction | null = null;
  private warned = new Set<string>();

  constructor(root: THREE.Object3D, clips: THREE.AnimationClip[], rules: unknown[], blend: number, clipBlend: Dict = {}) {
    this.mixer = new THREE.AnimationMixer(root);
    // Every clip loops: the rules hold a state while its condition holds (EntityMesh3D, 2026-05-18).
    for (const c of clips) this.actions.set(c.name, this.mixer.clipAction(c).setLoop(THREE.LoopRepeat, Infinity));
    this.rules = rules;
    this.aliases = clipAliases(rules);
    this.blend = blend;
    this.clipBlend = clipBlend;
  }

  /** AnimationDirector.tick, then the mixer step. */
  update(e: Entity, dt: number): void {
    const picked = pickState(this.rules, e);
    if (picked !== this.active) {
      this.active = picked;
      const name = this.aliases.get(picked) ?? picked;
      const next = this.actions.get(name) ?? null;
      if (picked === "") {
        this.mixer.stopAllAction();
        this.current = null;
      } else if (!next) {
        if (!this.warned.has(name)) console.warn(`[anim] clip '${name}' is not in the model (state ${picked})`);
        this.warned.add(name);
      } else {
        const c = this.clipBlend[picked];
        const blend = isDict(c) && "blend_seconds" in c ? Number(c.blend_seconds) : this.blend;
        next.reset().play();
        if (this.current && this.current !== next) this.current.crossFadeTo(next, blend, false);
        this.current = next;
      }
    }
    // ADR 0065: a synced anim_phase in [0, 1) sets the clip time, so every view shows one pose.
    const ph = e.getState("anim_phase", null);
    if (this.current && typeof ph === "number") {
      const len = this.current.getClip().duration;
      if (len > 0) this.current.time = (((ph % 1) + 1) % 1) * len;
      this.mixer.update(0);
      return;
    }
    this.mixer.update(dt);
  }
}
