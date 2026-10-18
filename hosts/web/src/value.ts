// Values of the spec: JSON values plus 2D and 3D vectors. A position or a
// velocity becomes a vector, as in the reference interpreter.

export class Vec2 {
  x: number;
  y: number;
  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
  add(o: Vec2): Vec2 {
    return new Vec2(this.x + o.x, this.y + o.y);
  }
  distanceTo(o: Vec2): number {
    return Math.hypot(this.x - o.x, this.y - o.y);
  }
}

export class Vec3 {
  x: number;
  y: number;
  z: number;
  constructor(x: number, y: number, z: number) {
    this.x = x;
    this.y = y;
    this.z = z;
  }
}

export type Value =
  | null
  | boolean
  | number
  | string
  | Vec2
  | Vec3
  | Value[]
  | { [k: string]: Value };

export type Dict = { [k: string]: Value };

export function isDict(v: unknown): v is Dict {
  return typeof v === "object" && v !== null && !Array.isArray(v) && !(v instanceof Vec2) && !(v instanceof Vec3);
}

export function isNum(v: unknown): v is number {
  return typeof v === "number";
}

/** A 2- or 3-element array becomes a vector. Anything else is the zero 2D vector. */
export function normalizePosition(v: unknown): Vec2 | Vec3 {
  if (v instanceof Vec2 || v instanceof Vec3) return v;
  if (Array.isArray(v)) {
    if (v.length === 2) return new Vec2(toFloat(v[0]), toFloat(v[1]));
    if (v.length === 3) return new Vec3(toFloat(v[0]), toFloat(v[1]), toFloat(v[2]));
  }
  return new Vec2(0, 0);
}

/** The reference float(): a bool is 1 or 0, a numeric string is parsed, else 0. */
export function toFloat(v: unknown): number {
  if (typeof v === "number") return v;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (typeof v === "string") {
    const n = parseFloat(v);
    return Number.isNaN(n) ? 0 : n;
  }
  return 0;
}

/** The reference int(): truncate toward zero. */
export function toInt(v: unknown): number {
  return Math.trunc(toFloat(v));
}

/** Value equality of the reference interpreter: deep for arrays, dicts and vectors. */
export function equals(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a === "number" && typeof b === "number") return a === b;
  if (a instanceof Vec2 && b instanceof Vec2) return a.x === b.x && a.y === b.y;
  if (a instanceof Vec3 && b instanceof Vec3) return a.x === b.x && a.y === b.y && a.z === b.z;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((x, i) => equals(x, b[i]));
  }
  if (isDict(a) && isDict(b)) {
    const ka = Object.keys(a);
    if (ka.length !== Object.keys(b).length) return false;
    return ka.every((k) => k in b && equals(a[k], b[k]));
  }
  return false;
}

/** An ordered comparison. Only two numbers or two strings compare. */
export function lessThan(a: unknown, b: unknown): boolean | null {
  if (typeof a === "number" && typeof b === "number") return a < b;
  if (typeof a === "string" && typeof b === "string") return a < b;
  return null;
}

export function deepCopy<T>(v: T): T {
  if (v instanceof Vec2) return new Vec2(v.x, v.y) as T;
  if (v instanceof Vec3) return new Vec3(v.x, v.y, v.z) as T;
  if (Array.isArray(v)) return v.map((x) => deepCopy(x)) as T;
  if (isDict(v)) {
    const out: Dict = {};
    for (const k of Object.keys(v)) out[k] = deepCopy(v[k]);
    return out as T;
  }
  return v;
}

/** The reference str() for ids and messages. */
export function str(v: unknown): string {
  if (v === null || v === undefined) return "<null>";
  if (typeof v === "string") return v;
  if (typeof v === "number") return Number.isInteger(v) ? String(v) : String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (v instanceof Vec2) return `(${v.x}, ${v.y})`;
  if (v instanceof Vec3) return `(${v.x}, ${v.y}, ${v.z})`;
  return JSON.stringify(v);
}
