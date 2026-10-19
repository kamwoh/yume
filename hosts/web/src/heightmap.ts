// The displaced ground of a `scene.json` ground block (ADR 0095 phase 3).
// Mirrors GroundRenderer.sample_y, the CPU twin of the displace shaders:
// the heightmap spans the whole plane once, with no V flip, and
//   y = (bilinear red sample + height_offset) * height_scale.
// The physics floor and the drawn ground both read this one function.
import { type Dict, isDict, toFloat } from "./value.ts";

/** The red channel of a heightmap image, each value in [0, 1], row by row. */
export type HeightImage = { width: number; height: number; red: Float32Array };

export class GroundHeight {
  readonly planeSize: number;
  private img: HeightImage;
  private strength: number;
  private offset: number;

  constructor(img: HeightImage, planeSize: number, strength: number, offset: number) {
    this.img = img;
    this.planeSize = planeSize;
    this.strength = strength;
    this.offset = offset;
  }

  /**
   * The heightmap path of a ground block, or "" when the ground is flat. The
   * reference displaces only with a ground shader, a heightmap and a height_scale other than 0.
   */
  static heightmapPath(ground: Dict): string {
    const mesh = isDict(ground.mesh) ? ground.mesh : null;
    if (!mesh || String(mesh.shader ?? "").trim() === "") return "";
    const p = isDict(mesh.shader_params) ? mesh.shader_params : {};
    return typeof p.heightmap === "string" && toFloat(p.height_scale ?? 0) !== 0 ? p.heightmap : "";
  }

  /** The sampler of a ground block with its decoded heightmap. */
  static of(ground: Dict, img: HeightImage): GroundHeight {
    const mesh = ground.mesh as Dict;
    const p = mesh.shader_params as Dict;
    return new GroundHeight(img, planeSize(mesh), toFloat(p.height_scale), toFloat(p.height_offset ?? -0.5));
  }

  /** GroundRenderer.sample_y. */
  sampleY(x: number, z: number): number {
    const ps = this.planeSize;
    const { width: w, height: h, red } = this.img;
    const u = Math.min(Math.max((x + ps * 0.5) / ps, 0), 1);
    const v = Math.min(Math.max((z + ps * 0.5) / ps, 0), 1);
    const px = u * (w - 1);
    const py = v * (h - 1);
    const x0 = Math.trunc(px);
    const y0 = Math.trunc(py);
    const x1 = Math.min(x0 + 1, w - 1);
    const y1 = Math.min(y0 + 1, h - 1);
    const fx = px - x0;
    const fy = py - y0;
    const at = (xx: number, yy: number) => red[yy * w + xx];
    const s = at(x0, y0) * (1 - fx) * (1 - fy) + at(x1, y0) * fx * (1 - fy) + at(x0, y1) * (1 - fx) * fy + at(x1, y1) * fx * fy;
    return (s + this.offset) * this.strength;
  }

  /** GroundRenderer._hm_collider_n: 1 m cells, from 33 to 401 points for each axis. */
  colliderPoints(): number {
    return Math.min(Math.max(Math.round(this.planeSize) + 1, 33), 401);
  }
}

/** The plane size of a ground mesh: max(width, depth), as the shader uniform. */
export function planeSize(mesh: Dict): number {
  const size = Array.isArray(mesh.size) ? mesh.size : [400, 400];
  const w = toFloat(size[0] ?? 400);
  const d = size.length >= 2 ? toFloat(size[1]) : w;
  return Math.max(w, d);
}
