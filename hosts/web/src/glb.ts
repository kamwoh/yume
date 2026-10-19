// GLB bounds for collision shapes (ADR 0095 phase 3). Mirrors
// PhysicsBodyBuilder._glb_bbox_uncached: the union of the min and max of
// each POSITION accessor, read from the JSON chunk. Node transforms do not
// apply, as in the reference.

export type Bounds = { min: [number, number, number]; max: [number, number, number] };

const MAGIC = 0x46546c67; // "glTF"
const CHUNK_JSON = 0x4e4f534a; // "JSON"

/** The JSON chunk of a GLB file, or null when the bytes are not a GLB. */
export function glbJson(bytes: Uint8Array): unknown {
  if (bytes.length < 20) return null;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (dv.getUint32(0, true) !== MAGIC) return null;
  const len = dv.getUint32(12, true);
  if (dv.getUint32(16, true) !== CHUNK_JSON || 20 + len > bytes.length) return null;
  try {
    return JSON.parse(new TextDecoder().decode(bytes.subarray(20, 20 + len)));
  } catch {
    return null;
  }
}

/** The bounds of the POSITION accessors of a glTF JSON document, or null. */
export function boundsOfGltf(doc: unknown): Bounds | null {
  if (typeof doc !== "object" || doc === null) return null;
  const d = doc as { meshes?: { primitives?: { attributes?: { POSITION?: number } }[] }[]; accessors?: { min?: number[]; max?: number[] }[] };
  const acc = d.accessors ?? [];
  const mn: [number, number, number] = [Infinity, Infinity, Infinity];
  const mx: [number, number, number] = [-Infinity, -Infinity, -Infinity];
  let found = false;
  for (const m of d.meshes ?? []) {
    for (const p of m.primitives ?? []) {
      const i = p.attributes?.POSITION;
      if (i === undefined || i >= acc.length) continue;
      const a = acc[i];
      if (!Array.isArray(a.min) || !Array.isArray(a.max) || a.min.length < 3 || a.max.length < 3) continue;
      for (let k = 0; k < 3; k++) {
        mn[k] = Math.min(mn[k], a.min[k]);
        mx[k] = Math.max(mx[k], a.max[k]);
      }
      found = true;
    }
  }
  return found ? { min: mn, max: mx } : null;
}
