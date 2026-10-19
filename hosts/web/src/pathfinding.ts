// NPC pathfinding (ADR 0024). Mirrors pathfinding.gd for its data: the
// walkable_floor and pathfinding_obstacle rectangles, cut into a 1 m grid,
// with each cell whose center is inside an obstacle left out.
//
// Navigation is host-defined (ADR 0086). Godot asks NavigationServer3D for
// the next path point. This host runs A* over the same grid and steers
// toward the center of the next cell. With no walkable_floor entity, both
// hosts do nothing, which is the case for every current game.
import type { Entity } from "./entity.ts";
import type { Env } from "./env.ts";
import { Vec2, Vec3, toFloat } from "./value.ts";

const CELL_SIZE = 1.0;
/** NavigationAgent3D.target_desired_distance (DEFAULT_TARGET_DESIRED_DISTANCE). */
const TARGET_DESIRED_DISTANCE = 0.5;

type Rect = { minX: number; maxX: number; minZ: number; maxZ: number; y: number };

export type NavGrid = { x0: number; z0: number; w: number; h: number; y: number; open: Uint8Array };

/** Pathfinding._collect_rects. */
function collectRects(env: Env): { walk: Rect[]; obs: Rect[] } {
  const walk: Rect[] = [];
  const obs: Rect[] = [];
  for (const e of env.entities.values()) {
    const isWalk = e.hasTag("walkable_floor");
    const isObs = e.hasTag("pathfinding_obstacle");
    if (!isWalk && !isObs) continue;
    const ext = e.properties.aabb_extents;
    if (ext === null || ext === undefined) continue;
    const [ex, , ez] = vec3Of(ext);
    const p = e.position();
    if (!(p instanceof Vec3) && !(p instanceof Vec2)) continue;
    const px = p.x;
    const py = p instanceof Vec3 ? p.y : 0;
    const pz = p instanceof Vec3 ? p.z : p.y;
    const r = { minX: px - ex, maxX: px + ex, minZ: pz - ez, maxZ: pz + ez, y: py };
    if (isWalk) walk.push(r);
    if (isObs) obs.push(r);
  }
  return { walk, obs };
}

/** Vec3Util.from_world_pos for an extents value. */
function vec3Of(v: unknown): [number, number, number] {
  if (v instanceof Vec3) return [v.x, v.y, v.z];
  if (Array.isArray(v) && v.length >= 3) return [toFloat(v[0]), toFloat(v[1]), toFloat(v[2])];
  if (Array.isArray(v) && v.length === 2) return [toFloat(v[0]), 0, toFloat(v[1])];
  if (typeof v === "number") return [v, v, v];
  return [0, 0, 0];
}

const inside = (x: number, z: number, rects: Rect[]) => rects.some((r) => x >= r.minX && x <= r.maxX && z >= r.minZ && z <= r.maxZ);

/** Pathfinding.build_navmesh_for_level: no walkable_floor entity leaves the grid empty. */
export function buildNavGrid(env: Env): void {
  env.navGrid = null;
  const { walk, obs } = collectRects(env);
  if (walk.length === 0) return;
  const x0 = Math.min(...walk.map((r) => r.minX));
  const z0 = Math.min(...walk.map((r) => r.minZ));
  const w = Math.max(1, Math.ceil((Math.max(...walk.map((r) => r.maxX)) - x0) / CELL_SIZE));
  const h = Math.max(1, Math.ceil((Math.max(...walk.map((r) => r.maxZ)) - z0) / CELL_SIZE));
  const open = new Uint8Array(w * h);
  for (let j = 0; j < h; j++) {
    for (let i = 0; i < w; i++) {
      const cx = x0 + (i + 0.5) * CELL_SIZE;
      const cz = z0 + (j + 0.5) * CELL_SIZE;
      open[j * w + i] = inside(cx, cz, walk) && !inside(cx, cz, obs) ? 1 : 0;
    }
  }
  env.navGrid = { x0, z0, w, h, y: walk[0].y, open };
}

/** Pathfinding.teardown_navmesh. */
export function teardownNavGrid(env: Env): void {
  env.navGrid = null;
}

/** Pathfinding.tick_pathfind: the velocity toward the next path point, or zero at the target. */
export function tickPathfind(env: Env, ent: Entity, dx: number, dy: number, dz: number, speed: number): void {
  const pos = ent.position();
  if (!(pos instanceof Vec3)) return;
  const g = env.navGrid;
  if (!g) return;
  const dest = new Vec3(dx, dy, dz);
  if (Math.hypot(dest.x - pos.x, dest.y - pos.y, dest.z - pos.z) <= TARGET_DESIRED_DISTANCE) {
    ent.setVelocity(new Vec3(0, 0, 0));
    return;
  }
  const next = nextPoint(g, pos, dest);
  const tx = next.x - pos.x;
  const ty = next.y - pos.y;
  const tz = next.z - pos.z;
  const len = Math.hypot(tx, ty, tz);
  if (len < 0.0001) {
    ent.setVelocity(new Vec3(0, 0, 0));
    return;
  }
  ent.setVelocity(new Vec3((tx / len) * speed, (ty / len) * speed, (tz / len) * speed));
}

function cellOf(g: NavGrid, x: number, z: number): number {
  const i = Math.floor((x - g.x0) / CELL_SIZE);
  const j = Math.floor((z - g.z0) / CELL_SIZE);
  if (i < 0 || j < 0 || i >= g.w || j >= g.h) return -1;
  return j * g.w + i;
}

/** The center of the second cell of an 8-neighbour A* path, or the destination when it is one cell away or no path exists. */
function nextPoint(g: NavGrid, from: Vec3, dest: Vec3): Vec3 {
  const s = cellOf(g, from.x, from.z);
  const t = cellOf(g, dest.x, dest.z);
  if (s < 0 || t < 0 || s === t || !g.open[t]) return dest;
  const n = g.w * g.h;
  const cost = new Float64Array(n).fill(Infinity);
  const prev = new Int32Array(n).fill(-1);
  const closed = new Uint8Array(n);
  const tj = Math.floor(t / g.w);
  const ti = t % g.w;
  const heur = (c: number) => Math.hypot((c % g.w) - ti, Math.floor(c / g.w) - tj);
  const openList: number[] = [s];
  cost[s] = 0;
  while (openList.length > 0) {
    let best = 0;
    for (let k = 1; k < openList.length; k++) if (cost[openList[k]] + heur(openList[k]) < cost[openList[best]] + heur(openList[best])) best = k;
    const c = openList.splice(best, 1)[0];
    if (c === t) break;
    closed[c] = 1;
    const ci = c % g.w;
    const cj = Math.floor(c / g.w);
    for (let dj = -1; dj <= 1; dj++) {
      for (let di = -1; di <= 1; di++) {
        if (di === 0 && dj === 0) continue;
        const ni = ci + di;
        const nj = cj + dj;
        if (ni < 0 || nj < 0 || ni >= g.w || nj >= g.h) continue;
        const nc = nj * g.w + ni;
        if (closed[nc] || (!g.open[nc] && nc !== s)) continue;
        // A diagonal step needs both side cells open, so the path does not cut a corner.
        if (di !== 0 && dj !== 0 && (!g.open[cj * g.w + ni] || !g.open[nj * g.w + ci])) continue;
        const nCost = cost[c] + (di !== 0 && dj !== 0 ? Math.SQRT2 : 1);
        if (nCost < cost[nc]) {
          cost[nc] = nCost;
          prev[nc] = c;
          if (!openList.includes(nc)) openList.push(nc);
        }
      }
    }
  }
  if (prev[t] < 0) return dest;
  let c = t;
  while (prev[c] !== s && prev[c] >= 0) c = prev[c];
  if (c === t) return dest;
  return new Vec3(g.x0 + ((c % g.w) + 0.5) * CELL_SIZE, g.y, g.z0 + (Math.floor(c / g.w) + 0.5) * CELL_SIZE);
}
