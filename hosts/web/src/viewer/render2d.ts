// The 2D renderer of the viewer. Mirrors entity_sprite_2d.gd (the shape
// interpreter) and the top-down 2D mode of camera_director.gd.
//
// three.js draws each entity as flat meshes under one group with y flipped,
// so the content keeps the reference convention: x right, y down, in pixels.
import * as THREE from "three";
import type { Entity } from "../entity.ts";
import { type RGBA, colorOf } from "./color.ts";
import { type Dict, isDict, toFloat } from "../value.ts";
import type { World } from "../world.ts";

const FALLBACK_COLOR = "#b3b3b3";
const FALLBACK_RADIUS = 8;
/** Godot's default clear color, Color(0.3, 0.3, 0.3). */
const CLEAR_COLOR = 0x4d4d4d;

type Sprite = { group: THREE.Group; seq: number };

export class Renderer2D {
  readonly renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private root = new THREE.Group();
  private camera = new THREE.OrthographicCamera(-1, 1, 1, -1, -1000, 1000);
  private sprites = new Map<Entity, Sprite>();
  private seq = 0;
  private shapes: Dict;
  private camCfg: Dict;
  private camPos = new THREE.Vector2(0, 0);
  private zoom = 1;
  private snap = true;

  constructor(canvas: HTMLCanvasElement, shapes: Dict, scene: Dict) {
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
    this.renderer.setClearColor(CLEAR_COLOR);
    this.root.scale.y = -1;
    this.scene.add(this.root);
    this.shapes = isDict(shapes.shapes) ? shapes.shapes : {};
    this.camCfg = isDict(scene.camera) ? scene.camera : {};
  }

  /** Add new entities, drop removed ones, and move each sprite to its entity. */
  sync(world: World): void {
    const live = new Set<Entity>();
    for (const e of world.env.entities.values()) {
      if (e.id === "_engine" || e.visual.hidden === true) continue;
      live.add(e);
      let s = this.sprites.get(e);
      if (!s) {
        s = { group: this.build(e), seq: this.seq++ };
        this.sprites.set(e, s);
        this.root.add(s.group);
      }
      const p = e.planarPosition();
      s.group.position.set(p.x, p.y, 0);
      const yaw = e.getState("yaw", null);
      if (yaw !== null && e.visual.rotate_with_velocity !== true) s.group.rotation.z = toFloat(yaw);
      const z = Math.trunc(toFloat(e.visual.z_index ?? 0));
      // Godot draws by z_index, then by tree order. Later spawns draw on top.
      s.group.traverse((o) => {
        o.renderOrder = z * 1_000_000 + s.seq * 16 + (o.userData.op ?? 0);
      });
    }
    for (const [e, s] of this.sprites) {
      if (live.has(e)) continue;
      this.root.remove(s.group);
      disposeGroup(s.group);
      this.sprites.delete(e);
    }
    this.updateCamera(world);
  }

  render(): void {
    const size = this.renderer.getSize(new THREE.Vector2());
    const hw = size.x / (2 * this.zoom);
    const hh = size.y / (2 * this.zoom);
    // The root group flips y, so the camera sits at (x, -y).
    this.camera.left = this.camPos.x - hw;
    this.camera.right = this.camPos.x + hw;
    this.camera.top = -this.camPos.y + hh;
    this.camera.bottom = -this.camPos.y - hh;
    this.camera.updateProjectionMatrix();
    this.renderer.render(this.scene, this.camera);
  }

  /** camera_director._camera_top_down_2d: center_on_tag with fit_padding, or follow_tag. */
  private updateCamera(world: World): void {
    const cfg = this.camCfg;
    const size = this.renderer.getSize(new THREE.Vector2());
    if ("center_on_tag" in cfg) {
      const tag = String(cfg.center_on_tag);
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (const e of world.env.entities.values()) {
        if (!e.hasTag(tag)) continue;
        const p = e.planarPosition();
        minX = Math.min(minX, p.x);
        maxX = Math.max(maxX, p.x);
        minY = Math.min(minY, p.y);
        maxY = Math.max(maxY, p.y);
      }
      if (minX === Infinity) return;
      const center = new THREE.Vector2((minX + maxX) / 2, (minY + maxY) / 2);
      this.camPos = this.snap ? center : this.camPos.lerp(center, toFloat(cfg.lerp ?? 0.08));
      if ("fit_padding" in cfg) {
        const pad = toFloat(cfg.fit_padding);
        const w = Math.max(maxX - minX + 2 * pad, 1);
        const h = Math.max(maxY - minY + 2 * pad, 1);
        const target = Math.min(Math.max(Math.min(size.x / w, size.y / h), 0.25), 4);
        this.zoom = this.snap ? target : this.zoom + (target - this.zoom) * toFloat(cfg.zoom_lerp ?? 0.08);
      }
      this.snap = false;
      return;
    }
    const tag = String(cfg.follow_tag ?? "");
    if (tag === "") return;
    for (const e of world.env.entities.values()) {
      if (!e.hasTag(tag)) continue;
      const p = e.planarPosition();
      this.camPos.lerp(new THREE.Vector2(p.x, p.y), this.snap ? 1 : toFloat(cfg.lerp ?? 0.08));
      this.snap = false;
      return;
    }
  }

  /** The three tiers of entity_sprite_2d: a sprite asset (not in this host yet), a library shape, a bare circle. */
  private build(e: Entity): THREE.Group {
    const group = new THREE.Group();
    const v = e.visual;
    const shapeName = String(v.shape ?? "");
    const shape = shapeName !== "" && isDict(this.shapes[shapeName]) ? (this.shapes[shapeName] as Dict) : null;
    if (shape) {
      const params: Dict = { ...(isDict(shape.params) ? shape.params : {}), ...(isDict(v.params) ? v.params : {}) };
      const prims = Array.isArray(shape.primitives) ? shape.primitives : [];
      prims.forEach((p, i) => {
        if (!isDict(p)) return;
        const mesh = primitive(p, params);
        if (mesh) {
          mesh.userData.op = Math.min(i, 15);
          group.add(mesh);
        }
      });
      return group;
    }
    group.add(circle(0, 0, toFloat(v.radius ?? FALLBACK_RADIUS), colorOf(v.color ?? FALLBACK_COLOR)));
    return group;
  }
}

/** One shape primitive: circle, rect, polygon, line. `text` and `texture` draw nothing, as in the reference. */
function primitive(p: Dict, params: Dict): THREE.Object3D | null {
  const param = (x: unknown) => (typeof x === "string" && x.startsWith("$") ? (params[x.slice(1)] ?? x) : x);
  const color = colorOf(param(p.color ?? "#fff"));
  const [px, py] = vec2(p.pos);
  switch (String(p.op ?? "")) {
    case "circle":
      return circle(px, py, toFloat(param(p.radius ?? 5)), color);
    case "rect": {
      const [w, h] = vec2(p.size ?? [10, 10]);
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(w, h), material(color));
      mesh.position.set(px + w / 2, py + h / 2, 0);
      return mesh;
    }
    case "polygon": {
      const pts = (Array.isArray(p.points) ? p.points : []).map((q) => new THREE.Vector2(...vec2(q)));
      if (pts.length < 3) return null;
      return new THREE.Mesh(new THREE.ShapeGeometry(new THREE.Shape(pts)), material(color));
    }
    case "line": {
      const [x0, y0] = vec2(p.from ?? [0, 0]);
      const [x1, y1] = vec2(p.to ?? [10, 0]);
      const width = toFloat(param(p.width ?? 1));
      const len = Math.hypot(x1 - x0, y1 - y0);
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(len, width), material(color));
      mesh.position.set((x0 + x1) / 2, (y0 + y1) / 2, 0);
      mesh.rotation.z = Math.atan2(y1 - y0, x1 - x0);
      return mesh;
    }
  }
  return null;
}

function circle(x: number, y: number, r: number, color: RGBA): THREE.Mesh {
  const mesh = new THREE.Mesh(new THREE.CircleGeometry(r, 48), material(color));
  mesh.position.set(x, y, 0);
  return mesh;
}

function material(color: RGBA): THREE.MeshBasicMaterial {
  const alpha = color.alpha ?? 1;
  return new THREE.MeshBasicMaterial({
    color,
    side: THREE.DoubleSide,
    depthTest: false,
    depthWrite: false,
    transparent: alpha < 1,
    opacity: alpha,
  });
}

function vec2(v: unknown): [number, number] {
  return Array.isArray(v) && v.length >= 2 ? [toFloat(v[0]), toFloat(v[1])] : [0, 0];
}

function disposeGroup(g: THREE.Group): void {
  g.traverse((o) => {
    if (o instanceof THREE.Mesh) {
      o.geometry.dispose();
      (o.material as THREE.Material).dispose();
    }
  });
}
