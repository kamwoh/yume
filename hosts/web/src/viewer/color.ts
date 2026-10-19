// Color parsing shared by the 2D and 3D renderers. Mirrors _parse_color in
// entity_sprite_2d.gd and mesh_lib.gd: "#rgb", "#rrggbb", "#rrggbbaa", a
// named color, or [r, g, b(, a)] in 0..1. Content colors are sRGB.
import * as THREE from "three";
import { toFloat } from "../value.ts";

export type RGBA = THREE.Color & { alpha?: number };

export function colorOf(v: unknown, fallback = "#b3b3b3"): RGBA {
  const c = new THREE.Color() as RGBA;
  c.set(fallback);
  if (typeof v === "string") {
    const hex = v.replace(/^#/, "");
    if (/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(hex)) {
      c.setRGB(parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255, THREE.SRGBColorSpace);
      if (hex.length === 8) c.alpha = parseInt(hex.slice(6, 8), 16) / 255;
    } else if (/^[0-9a-fA-F]{3}$/.test(hex)) {
      c.set(`#${hex}`);
    } else {
      try {
        c.setStyle(v);
      } catch {
        // An unknown name keeps the fallback.
      }
    }
  } else if (Array.isArray(v) && v.length >= 3) {
    c.setRGB(toFloat(v[0]), toFloat(v[1]), toFloat(v[2]), THREE.SRGBColorSpace);
    if (v.length >= 4) c.alpha = toFloat(v[3]);
  }
  return c;
}
