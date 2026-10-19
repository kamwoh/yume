// The 3D renderer of the viewer. Mirrors, for the parts in phase 2:
//   entity_mesh_3d.gd     a mesh-library mesh or a bare box for each entity,
//                         position, y_offset, scale and yaw
//   ground_renderer.gd    the scene.json ground plane (flat color)
//   lighting_director.gd  sun, ambient, procedural sky, fog, tonemap
//   camera_director.gd    the 3D modes: top_down_3d, isometric_3d,
//                         third_person_3d, first_person_3d
//
// Rendering is host-defined (ADR 0086). A light energy of 1 in the reference
// lights a white surface to white. three.js needs an intensity of pi for
// the same result, so each energy is multiplied by pi.
//
// A GLB model loads from /asset/<game>/<path>. One with no animations is
// scaled to unit height with its base at the origin, as _normalize_glb does.
//
// An articulated body (ADR 0091) draws one node for each link at the pose
// that the physics host reads back, as _mount_links and _sync_links do.
//
// Animation (anim.ts): a GLB's clips under visual.animation_state_rules,
// and the `animations` block of a library mesh, as the reference does.
//
// A ground shader graph (shader_dag) compiles at load in shader_dag.ts.
// The sky_clouds sky and the two ground shaders come from shaders.ts. The
// water_stylized surface comes from water.ts.
//
// The first-person viewmodel (camera.viewmodel) hangs under the camera.
//
// Glow runs in the post chain (renderPost), as an approximation. SSAO
// does not: the reference's gl_compatibility renderer ignores it.
//
// Not in this host yet: the toon shader, reflection probes.
import * as THREE from "three";
import { type GLTF, GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { clone as cloneSkinned } from "three/addons/utils/SkeletonUtils.js";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { ShaderPass } from "three/addons/postprocessing/ShaderPass.js";
import { GTAOPass } from "three/addons/postprocessing/GTAOPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import type { Entity } from "../entity.ts";
import type { GroundHeight } from "../heightmap.ts";
import { shapeTransform } from "../physics.ts";
import { type Dict, Vec2, Vec3, isDict, toFloat } from "../value.ts";
import type { World } from "../world.ts";
import { colorOf } from "./color.ts";
import { Animator, hasDefault, libraryClip } from "./anim.ts";
import { MeshLib } from "./mesh_lib.ts";
import { groundMaterial, setTime, skyCloudsMaterial } from "./shaders.ts";
import { buildWater } from "./water.ts";
import { dagMaterial } from "./shader_dag.ts";

// Godot 4's depth fog is exponential in the view-space distance:
// 1 - exp(-density * distance). three.js's FogExp2 squares the distance, so
// the host patches its fog chunks once.
THREE.ShaderChunk.fog_vertex = THREE.ShaderChunk.fog_vertex.replace("vFogDepth = - mvPosition.z;", "vFogDepth = length( mvPosition.xyz );");
THREE.ShaderChunk.fog_fragment = THREE.ShaderChunk.fog_fragment.replace(
  "float fogFactor = 1.0 - exp( - fogDensity * fogDensity * vFogDepth * vFogDepth );",
  "float fogFactor = 1.0 - exp( - fogDensity * vFogDepth );",
);

/** The fields of LightingDirector.FIELDS["lighting"] that this host draws. */
export const LIGHTING_DONE = ["directional_light", "ambient", "sky", "fog", "tonemap", "adjustments", "glow", "ssao"];

/**
 * Godot's tonemap curves (servers/rendering tonemap.glsl), as three.js's
 * CustomToneMapping. 0 linear, 1 Reinhard, 2 filmic, 3 ACES.
 */
function godotToneMapping(mode: number, white: number): string {
  const w = white.toFixed(6);
  return `vec3 CustomToneMapping( vec3 color ) {
  color *= toneMappingExposure;
  float white = ${w};
  ${
    mode === 1
      ? "return (white * color + color) / (color * white + white);"
      : mode === 2
        ? `const float bias = 2.0;
  const float A = 0.22 * bias * bias; const float B = 0.30 * bias; const float C = 0.10; const float D = 0.20; const float E = 0.01; const float F = 0.30;
  vec3 c = ((color * (A * color + C * B) + D * E) / (color * (A * color + B) + D * F)) - E / F;
  float wt = ((white * (A * white + C * B) + D * E) / (white * (A * white + B) + D * F)) - E / F;
  return c / wt;`
        : mode === 3
          ? `const float bias = 1.8;
  const float A = 0.0245786; const float B = 0.000090537; const float C = 0.983729; const float D = 0.432951; const float E = 0.238081;
  const mat3 rgb_to_rrt = mat3(vec3(0.59719, 0.35458, 0.04823) * bias, vec3(0.07600, 0.90834, 0.01566) * bias, vec3(0.02840, 0.13383, 0.83777) * bias);
  const mat3 odt_to_rgb = mat3(vec3(1.60475, -0.53108, -0.07367), vec3(-0.10208, 1.10813, -0.00605), vec3(-0.00327, -0.07276, 1.07602));
  color *= rgb_to_rrt;
  vec3 c = (color * (color + A) - B) / (color * (C * color + D) + E);
  c *= odt_to_rgb;
  float wb = white * bias;
  float wt = (wb * (wb + A) - B) / (wb * (C * wb + D) + E);
  return c / wt;`
          : "return color;"
  }
}`;
}

/** The share of the light that SSAO may darken. Godot's SSAO darkens only the ambient light; GTAO darkens all of it. */
const AO_AMBIENT_SHARE = 0.3;
/** Godot's gl_compatibility renderer ignores Environment.ssao_enabled. */
const REFERENCE_DRAWS_SSAO = false;

/** Godot's default clear color, Color(0.3, 0.3, 0.3). */
const CLEAR_COLOR = 0x4d4d4d;
const FALLBACK_COLOR = "#b3b3b3";
const FALLBACK_SIZE = 0.5;
const HOURS_PER_DAY = 24;
/** A mesh on this layer casts shadows but the camera does not draw it. */
const SHADOW_ONLY_LAYER = 1;
const MODES_3D = ["top_down_3d", "isometric_3d", "third_person_3d", "first_person_3d", "free_cam"];

/** A scene renders in 3D when its camera mode is a 3D mode (camera_director.gd). */
export function is3D(scene: Dict): boolean {
  return isDict(scene.camera) && MODES_3D.includes(String(scene.camera.mode ?? ""));
}

type Node = { group: THREE.Group; mode: "mesh" | "bare" | "glb" | "links"; normalized: boolean; links?: Map<string, THREE.Group>; animator?: Animator };

export class Renderer3D {
  readonly renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera = new THREE.PerspectiveCamera(75, 16 / 9, 0.05, 4000);
  private ortho = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.05, 4000);
  private active: THREE.Camera = this.camera;
  private nodes = new Map<Entity, Node>();
  private lib: MeshLib;
  private positionScale: number;
  private cam: Dict;
  private lighting: Dict;
  private sun: THREE.DirectionalLight | null = null;
  private ambient: THREE.HemisphereLight | null = null;
  private sky: THREE.Mesh | null = null;
  /** True for the sky_clouds shader, false for the procedural sky. */
  private skyShader = false;
  /** The sky alone, for the environment map (Godot's AMBIENT_SOURCE_SKY and sky reflections). */
  private skyScene: THREE.Scene | null = null;
  private pmrem: THREE.PMREMGenerator | null = null;
  private envTarget: THREE.WebGLRenderTarget | null = null;
  private envKey = "";
  private envBuiltAt = -Infinity;
  private snap = true;
  private camPos = new THREE.Vector3();
  /** Mouse motion since the last frame, as env.mouse_delta in the reference. */
  mouseDelta = new THREE.Vector2();
  mouseCaptured = false;
  private assetBase: string;
  private gltf = new GLTFLoader();
  /** One load for each URL, as Godot loads a resource once. Each entity gets a clone. */
  private gltfCache = new Map<string, Promise<GLTF>>();
  private textures = new THREE.TextureLoader();
  /** GLB files still loading. A capture waits until this is 0. */
  pending = 0;

  /** `assetBase` is the URL prefix of the game's asset files, for example "/asset/demo_x/". */
  /** The shader-graph primitives (lib/shaders/primitives), by id. */
  private primitives: Map<string, Dict>;

  constructor(canvas: HTMLCanvasElement, meshes: Dict, scene: Dict, assetBase: string, primitives: Map<string, Dict> = new Map()) {
    this.primitives = primitives;
    this.assetBase = assetBase;
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
    this.renderer.setClearColor(CLEAR_COLOR);
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.lib = new MeshLib(meshes);
    const r = isDict(scene.renderer) ? scene.renderer : {};
    // entity_mesh_3d.gd: position_scale defaults to 0.05.
    this.positionScale = "position_scale" in r ? toFloat(r.position_scale) : 0.05;
    this.cam = isDict(scene.camera) ? scene.camera : {};
    this.lighting = isDict(scene.lighting) ? scene.lighting : {};
    this.camera.layers.enable(0);
    this.ortho.layers.enable(0);
    this.buildGround(scene);
    if (isDict(scene.water)) {
      this.water = buildWater(scene.water, (p, srgb) => this.loadTexture(p, srgb));
      if (this.water) this.scene.add(this.water);
    }
    this.buildLighting();
  }

  // ---------------------------------------------------------------- ground

  /** GroundRenderer.build: a plane of ground.mesh.size at y = 0. A ground shader falls back to the color. */
  private buildGround(scene: Dict): void {
    const ground = isDict(scene.ground) ? scene.ground : {};
    const cfg = isDict(ground.mesh) ? ground.mesh : null;
    if (!cfg) return;
    const size = Array.isArray(cfg.size) ? cfg.size : [400, 400];
    const w = toFloat(size[0] ?? 400);
    const d = size.length >= 2 ? toFloat(size[1]) : w;
    // GroundRenderer: a named ground shader replaces the flat material. plane_size is max(width, depth).
    const shaded = groundMaterial(String(cfg.shader ?? "").trim(), isDict(cfg.shader_params) ? cfg.shader_params : {}, Math.max(w, d), (p, srgb) =>
      this.loadTexture(p, srgb),
    );
    if (!shaded && "shader" in cfg) console.info(`[ground] shader '${String(cfg.shader ?? "")}' is not in this host yet: flat color`);
    let mat = shaded;
    let segments = 1;
    if (!mat && isDict(cfg.shader_dag)) {
      // ADR 0058: the graph compiles at load (shader_dag.ts). It displaces on the GPU,
      // so the plane takes the subdivision of Godot's PlaneMesh (subdivide N: N + 1 segments).
      try {
        mat = dagMaterial(cfg, this.primitives, (p, srgb) => this.loadTexture(p, srgb));
        segments = Math.max(Math.trunc(toFloat(cfg.subdivide ?? 0)) + 1, 1);
      } catch (e) {
        console.warn(`[ground] shader_dag did not compile: ${String(e)}`);
      }
    }
    if (!mat) {
      // StandardMaterial3D: color × albedo_texture, a normal map, both tiled uv1_scale times.
      const m = new THREE.MeshStandardMaterial({
        color: colorOf(cfg.color ?? "#808080"),
        roughness: toFloat(cfg.roughness ?? 0.9),
        metalness: toFloat(cfg.metallic ?? 0),
      });
      const tile = toFloat(cfg.uv1_scale ?? 1);
      const tiled = (t: THREE.Texture | null) => {
        if (t) t.repeat.set(tile, tile);
        return t;
      };
      const albedo = String(cfg.albedo_texture ?? "").trim();
      if (albedo !== "") m.map = tiled(this.loadTexture(albedo, true));
      const normal = String(cfg.normal_texture ?? "").trim();
      if (normal !== "") m.normalMap = tiled(this.loadTexture(normal, false));
      mat = m;
    }
    const mesh = new THREE.Mesh(new THREE.PlaneGeometry(w, d, segments, segments).rotateX(-Math.PI / 2), mat);
    mesh.receiveShadow = true;
    mesh.name = "Ground";
    this.scene.add(mesh);
    this.ground = { mesh, w, d, subdivide: Math.trunc(toFloat(cfg.subdivide ?? 0)) };
  }

  private ground: { mesh: THREE.Mesh; w: number; d: number; subdivide: number } | null = null;

  /** A texture of the game, by asset path. A source_color texture is sRGB, any other is raw data. */
  private loadTexture(path: string, srgb: boolean): THREE.Texture | null {
    const url = this.assetUrl(path);
    if (url === "") return null;
    this.pending++;
    const tex = this.textures.load(
      url,
      () => this.pending--,
      undefined,
      () => {
        this.pending--;
        console.info(`[render3d] texture not found: ${path}`);
      },
    );
    tex.colorSpace = srgb ? THREE.SRGBColorSpace : THREE.NoColorSpace;
    tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
    // Godot's UV (0, 0) is the top-left of the image. three.js flips images unless told not to.
    tex.flipY = false;
    return tex;
  }

  /**
   * The displaced ground: the vertex heights come from sample_y, the same
   * function as the physics floor. The displace shader's colors are not in
   * this host yet.
   */
  setGroundHeight(h: GroundHeight): void {
    if (!this.ground) return;
    const { mesh, w, d } = this.ground;
    const seg = Math.min(Math.max(this.ground.subdivide, 64), 400);
    const geo = new THREE.PlaneGeometry(w, d, seg, seg).rotateX(-Math.PI / 2);
    const pos = geo.attributes.position;
    for (let i = 0; i < pos.count; i++) pos.setY(i, h.sampleY(pos.getX(i), pos.getZ(i)));
    geo.computeVertexNormals();
    mesh.geometry.dispose();
    mesh.geometry = geo;
  }

  private decor: THREE.Object3D[] = [];

  /** Ground decoration (grass.ts): drawn as it is, its TIME uniform advanced each frame. */
  addDecor(objs: THREE.Object3D[]): void {
    for (const o of objs) {
      this.scene.add(o);
      this.decor.push(o);
    }
  }

  /** The scene of a GLB file in its native space, for a trimesh collider. It counts toward `pending`. */
  loadModel(path: string): Promise<THREE.Object3D | null> {
    const url = this.assetUrl(path);
    if (url === "") return Promise.resolve(null);
    this.pending++;
    let load = this.gltfCache.get(url);
    if (!load) {
      load = this.gltf.loadAsync(url);
      this.gltfCache.set(url, load);
    }
    return load.then(
      (g) => {
        this.pending--;
        return g.scene;
      },
      () => {
        this.pending--;
        return null;
      },
    );
  }

  // -------------------------------------------------------------- lighting

  /** LightingDirector._attach_lighting_nodes. With no lighting block the reference adds no lights. */
  private buildLighting(): void {
    const cfg = this.lighting;
    // Name each lighting field this host does not draw, so a missing feature
    // shows at load (2026-10-19: lanterns' `adjustments` was ignored with no note,
    // and the frame looked washed out against the Godot capture).
    for (const k of Object.keys(cfg)) {
      if (k.startsWith("_")) continue;
      if (!LIGHTING_DONE.includes(k)) console.info(`[lighting] '${k}' is not in this host yet`);
      else if (k === "adjustments" && isDict(cfg.adjustments) && "color_correction" in cfg.adjustments) {
        console.info("[lighting] 'adjustments.color_correction' is not in this host yet");
      }
    }
    if (Object.keys(cfg).length === 0) return;
    const dl = isDict(cfg.directional_light) ? cfg.directional_light : {};
    if (dl.enabled !== false) {
      this.sun = new THREE.DirectionalLight(0xffffff, Math.PI);
      this.sun.castShadow = dl.shadow_enabled !== false;
      const sh = this.sun.shadow;
      sh.mapSize.set(2048, 2048);
      sh.camera.near = 0.5;
      sh.camera.far = 200;
      const half = 40;
      Object.assign(sh.camera, { left: -half, right: half, top: half, bottom: -half });
      sh.camera.layers.enable(SHADOW_ONLY_LAYER);
      sh.bias = -0.0005;
      this.scene.add(this.sun, this.sun.target);
    }
    if ("ambient" in cfg && !("sky" in cfg)) {
      this.ambient = new THREE.HemisphereLight(0xffffff, 0xffffff, 0);
      this.scene.add(this.ambient);
    }
    if ("sky" in cfg) {
      const sky = isDict(cfg.sky) ? cfg.sky : {};
      const shader = String(sky.shader ?? "").trim();
      if (shader !== "" && shader !== "sky_clouds") console.info(`[sky] shader '${shader}' is not in this host yet: procedural sky`);
      const mat = withSkyFog(shader === "sky_clouds" ? skyCloudsMaterial(isDict(sky.shader_params) ? sky.shader_params : {}) : skyMaterial());
      this.skyShader = shader === "sky_clouds";
      this.sky = new THREE.Mesh(new THREE.SphereGeometry(3000, 32, 16), mat);
      this.sky.renderOrder = -1;
      this.scene.add(this.sky);
      this.skyScene = new THREE.Scene();
      this.skyScene.add(new THREE.Mesh(new THREE.SphereGeometry(100, 32, 16), mat));
      this.pmrem = new THREE.PMREMGenerator(this.renderer);
    }
    const fog = isDict(cfg.fog) ? cfg.fog : null;
    if (fog && fog.enabled !== false) {
      // The density is linear here: the fog chunks above follow Godot's formula.
      this.scene.fog = new THREE.FogExp2(colorOf(fog.light_color ?? "#8a9bb5"), toFloat(fog.density ?? 0.01));
    }
    const tm = isDict(cfg.tonemap) ? cfg.tonemap : null;
    if (tm) {
      // Godot's own curves (tonemap.glsl): exposure, then linear, Reinhard, filmic or ACES, each with its white point.
      const mode = String(tm.mode ?? "linear").toLowerCase();
      const id = mode === "filmic" ? 2 : mode === "aces" ? 3 : mode.startsWith("reinhard") ? 1 : 0;
      THREE.ShaderChunk.tonemapping_pars_fragment = THREE.ShaderChunk.tonemapping_pars_fragment.replace(
        /vec3 CustomToneMapping\( vec3 color \) \{[^}]*\}/,
        godotToneMapping(id, toFloat(tm.white ?? 1)),
      );
      this.renderer.toneMapping = THREE.CustomToneMapping;
      this.renderer.toneMappingExposure = toFloat(tm.exposure ?? 1);
    }
  }

  /** LightingDirector._update_lighting: the sun and the environment at the time of day. */
  private updateLighting(world: World, focus: THREE.Vector3): void {
    const cfg = this.lighting;
    if (Object.keys(cfg).length === 0) return;
    const t = mod(this.timeOfDay(world), HOURS_PER_DAY);
    const f = dayFactor(t);
    if (this.sun) {
      const dl = isDict(cfg.directional_light) ? cfg.directional_light : {};
      const dir = sunDirectionAt(t);
      // The light shines along `dir`. Keep its shadow box on the camera focus.
      this.sun.target.position.copy(focus);
      this.sun.position.copy(focus).addScaledVector(dir, -100);
      const cNoon = colorOf(dl.color_at_noon ?? "#fff8e0");
      const cHorizon = colorOf(dl.color_at_dawn_dusk ?? "#ff9060");
      const cNight = colorOf(dl.color_at_night ?? "#3050a0");
      this.sun.color.copy(f < 0.25 ? cNight.lerp(cHorizon, f / 0.25) : cHorizon.lerp(cNoon, (f - 0.25) / 0.75));
      const eNoon = toFloat(dl.energy_noon ?? 1);
      const eHorizon = toFloat(dl.energy_horizon ?? 0.7);
      const eNight = toFloat(dl.energy_night ?? 0.05);
      const e = f < 0.25 ? lerp(eNight, eHorizon, f / 0.25) : lerp(eHorizon, eNoon, (f - 0.25) / 0.75);
      this.sun.intensity = e * Math.PI;
    }
    // ProceduralSkyMaterial: the director sets the horizon colors only. The
    // top and bottom colors keep Godot's defaults.
    // A shader sky (not in this host yet) still gives its colors: the
    // day/night pairs of SKY_DAY_NIGHT, with the shader_params as the day value.
    const sky = isDict(cfg.sky) ? cfg.sky : {};
    const shaderSky = String(sky.shader ?? "").trim() !== "";
    const top = shaderSky ? skyColorAt(sky, "sky_top_color", f) : linear(0.385, 0.454, 0.55);
    const horizon = shaderSky
      ? skyColorAt(sky, "sky_horizon_color", f)
      : colorOf(sky.horizon_night ?? "#101020").lerp(colorOf(sky.horizon_day ?? "#80a0e0"), f);
    const groundH =
      "ground_day" in sky && "ground_night" in sky
        ? colorOf(sky.ground_night).lerp(colorOf(sky.ground_day), f)
        : linear(0.6463, 0.6558, 0.6708);
    const groundB = linear(0.2, 0.169, 0.133);
    if (this.sky) {
      const u = (this.sky.material as THREE.ShaderMaterial).uniforms;
      if (this.skyShader) {
        // LightingDirector: each SKY_DAY_NIGHT uniform of the shader sky, each frame.
        for (const name of Object.keys(SKY_DAY_NIGHT)) u[name].value.copy(skyColorAt(sky, name, f));
        setTime(this.sky.material as THREE.Material, performance.now() / 1000);
      } else {
        u.top.value.copy(top);
        u.horizon.value.copy(horizon);
        u.groundHorizon.value.copy(groundH);
        u.groundBottom.value.copy(groundB);
      }
    }
    const fogCfg = isDict(cfg.fog) ? cfg.fog : null;
    if (this.scene.fog && fogCfg) {
      // Environment.fog_light_color × fog_light_energy, pulled toward the sky by
      // fog_aerial_perspective. The host takes the horizon color as the sky in the view direction.
      const base = colorOf(fogCfg.light_color ?? "#8a9bb5").multiplyScalar(toFloat(fogCfg.light_energy ?? 1));
      const ap = Math.min(Math.max(toFloat(fogCfg.aerial_perspective ?? 0), 0), 1);
      this.scene.fog.color.copy(base.clone().lerp(horizon, ap));
      if (this.sky) {
        // The sky's own fog (sky.glsl fog_process): the same mix, with the
        // sky color of each pixel, plus the sun scatter toward the sun.
        const u = (this.sky.material as THREE.ShaderMaterial).uniforms;
        u.skyFogOn.value = 1;
        u.skyFogColor.value.copy(base);
        u.skyFogAerial.value = ap;
        u.skyFogScatter.value = this.sun ? toFloat(fogCfg.sun_scatter ?? 0) : 0;
        if (this.sun) {
          u.skySunDir.value.copy(sunDirectionAt(t)).negate();
          u.skySunColor.value.copy(this.sun.color).multiplyScalar(this.sun.intensity / Math.PI);
        }
      }
    }
    if (this.ground) {
      setTime(this.ground.mesh.material as THREE.Material, performance.now() / 1000);
      const du = (this.ground.mesh.material as THREE.Material).userData.uniforms?.dagTime;
      if (du) du.value = performance.now() / 1000;
    }
    for (const d of this.decor) if (d instanceof THREE.Mesh) setTime(d.material as THREE.Material, performance.now() / 1000);
    const amb = isDict(cfg.ambient) ? cfg.ambient : {};
    const energy = lerp(toFloat(amb.energy_night ?? 1), toFloat(amb.energy_day ?? 1), f);
    if (this.skyScene && this.pmrem) {
      // With a sky, the reference takes ambient light and reflections from
      // the sky (AMBIENT_SOURCE_SKY). The ambient colors are then unused, and
      // so is the energy: Godot applies ambient_light_energy only when
      // ambient_light_sky_contribution is below 1, and the director leaves it at 1.
      this.scene.environmentIntensity = 1;
      const key = [top, horizon, groundH, groundB].map((c) => c.getHexString()).join();
      // A day clock changes the sky a little on most frames. Rebuild the map
      // at most once per second of real time.
      const now = performance.now();
      if (key !== this.envKey && now - this.envBuiltAt > 1000) {
        this.envKey = key;
        this.envBuiltAt = now;
        this.envTarget?.dispose();
        // The radiance pass of the reference draws the sky without fog.
        const fu = (this.sky!.material as THREE.ShaderMaterial).uniforms.skyFogOn;
        const on = fu.value;
        fu.value = 0;
        this.envTarget = this.pmrem.fromScene(this.skyScene, 0, 0.1, 1000);
        fu.value = on;
        this.scene.environment = this.envTarget.texture;
      }
    } else if (this.ambient) {
      const c = colorOf(amb.color_night ?? "#202040").lerp(colorOf(amb.color_day ?? "#a0a0c0"), f);
      this.ambient.color.copy(c);
      this.ambient.groundColor.copy(c);
      this.ambient.intensity = energy * Math.PI;
    }
  }

  /** LightingDirector._resolve_time_of_day: world state first, then the bound entity, then noon. */
  private timeOfDay(world: World): number {
    const dl = isDict(this.lighting.directional_light) ? this.lighting.directional_light : {};
    const bind = String(dl.binds_to ?? "world_clock.time_of_day");
    const dot = bind.indexOf(".");
    const tag = dot > 0 ? bind.slice(0, dot) : "world_clock";
    const field = dot > 0 ? bind.slice(dot + 1) : "time_of_day";
    if (field in world.env.world) return toFloat(world.env.world[field]);
    for (const e of world.env.entities.values()) {
      if (e.hasTag(tag) && field in e.state) return toFloat(e.state[field]);
    }
    return 12;
  }

  // -------------------------------------------------------------- entities

  private frameClock = new THREE.Clock();

  sync(world: World): void {
    const dt = Math.min(this.frameClock.getDelta(), 0.25);
    const live = new Set<Entity>();
    for (const e of world.env.entities.values()) {
      if (e.id === "_engine" || e.visual.hidden === true) continue;
      live.add(e);
      let n = this.nodes.get(e);
      const poses = world.env.physics?.linkPoses(e) ?? null;
      if (!n) {
        n = poses ? this.buildLinks(world.env.defs.get(e.defId) ?? {}) : this.build(e);
        this.nodes.set(e, n);
        this.scene.add(n.group);
      }
      if (poses && n.links) {
        const s = this.positionScale;
        for (const [name, g] of n.links) {
          const pose = poses.get(name);
          if (!pose) continue;
          g.position.set(pose.p[0] * s, pose.p[1] * s, pose.p[2] * s);
          g.quaternion.set(...pose.q);
        }
      } else this.place(e, n.group, n.normalized);
      n.animator?.update(e, dt);
    }
    for (const [e, n] of this.nodes) {
      if (live.has(e)) continue;
      this.scene.remove(n.group);
      this.nodes.delete(e);
    }
    const focus = this.updateCamera(world);
    this.updateLighting(world, focus);
    if (this.sky) this.sky.position.copy(this.camPos);
  }

  /** EntityMesh3D._ready: a GLB model, a library mesh, or a bare box. */
  private build(e: Entity): Node {
    const group = new THREE.Group();
    group.name = e.id;
    const v = e.visual;
    const meshField = String(v.mesh ?? "");
    // model_3d draws the file as it is. A .glb in `mesh` is normalized (_load_glb_mesh).
    if ("model_3d" in v) {
      const node: Node = { group, mode: "glb", normalized: false };
      this.loadGlb(e, node, String(v.model_3d), false);
      return node;
    }
    if (meshField.endsWith(".glb") || meshField.endsWith(".gltf")) {
      const node: Node = { group, mode: "glb", normalized: false };
      this.loadGlb(e, node, meshField, v.normalize !== false);
      return node;
    }
    const name = String(v.mesh ?? v.shape ?? "");
    if (name !== "" && this.lib.has(name)) {
      const def = this.lib.get(name);
      const prims = Array.isArray(def.primitives) ? def.primitives : [];
      this.lib.buildInto(group, prims, MeshLib.mergeParams(def, v.params), def.cast_shadow !== false);
      this.applyShadowOnly(e, group);
      const node: Node = { group, mode: "mesh", normalized: false };
      // AnimationTranslator.build_library + AnimationDirector: the mesh's clips, picked by its state rules.
      if (isDict(def.animations) && Array.isArray(def.animation_state_rules)) {
        const rules = def.animation_state_rules;
        if (!hasDefault(rules)) console.warn(`[render3d] mesh '${name}': animation_state_rules has no 'default' fallback`);
        else {
          const anims = def.animations;
          const clips = Object.keys(anims).flatMap((k) => (isDict(anims[k]) ? [libraryClip(k, anims[k] as Dict, group)] : [])).filter((c) => c !== null);
          node.animator = new Animator(group, clips, rules, Number(def.animation_blend_seconds ?? 0.15), anims);
        }
      }
      return node;
    }
    this.addBareBox(e, group);
    return { group, mode: "bare", normalized: false };
  }

  /** EntityMesh3D._mount_links: a link visual names a library mesh, or gives a color for the link shape. */
  private buildLinks(def: Dict): Node {
    const group = new THREE.Group();
    const links = new Map<string, THREE.Group>();
    const cfg = isDict(def.physics) && isDict(def.physics.links) ? def.physics.links : {};
    for (const name of Object.keys(cfg)) {
      const link = cfg[name];
      if (!isDict(link)) continue;
      const g = new THREE.Group();
      g.name = `link_${name}`;
      const visual = isDict(link.visual) ? link.visual : {};
      const meshName = String(visual.mesh ?? "");
      if (meshName !== "" && this.lib.has(meshName)) {
        const md = this.lib.get(meshName);
        this.lib.buildInto(g, Array.isArray(md.primitives) ? md.primitives : [], MeshLib.mergeParams(md, visual.params), md.cast_shadow !== false);
      } else {
        const mesh = linkShapeMesh(isDict(link.shape) ? link.shape : {}, visual.color ?? FALLBACK_COLOR);
        if (mesh) g.add(mesh);
      }
      group.add(g);
      links.set(name, g);
    }
    return { group, mode: "links", normalized: false, links };
  }

  private addBareBox(e: Entity, group: THREE.Group): void {
    const v = e.visual;
    const size = toFloat(v.size ?? FALLBACK_SIZE);
    const box = new THREE.Mesh(new THREE.BoxGeometry(size, size, size), new THREE.MeshStandardMaterial({ color: colorOf(v.color ?? FALLBACK_COLOR) }));
    box.castShadow = true;
    box.receiveShadow = true;
    group.add(box);
    this.applyShadowOnly(e, group);
  }

  /** EntityMesh3D._load_glb_mesh. A missing or broken file falls back to a bare box. */
  private loadGlb(e: Entity, node: Node, path: string, normalize: boolean): void {
    const url = this.assetUrl(path);
    if (url === "") {
      this.addBareBox(e, node.group);
      return;
    }
    this.pending++;
    let load = this.gltfCache.get(url);
    if (!load) {
      load = this.gltf.loadAsync(url);
      this.gltfCache.set(url, load);
    }
    load.then(
      (gltf) => {
        this.pending--;
        // The clone shares geometry, materials and textures with the cached scene.
        const imported = cloneSkinned(gltf.scene);
        imported.traverse((o) => {
          if (o instanceof THREE.Mesh) {
            o.castShadow = true;
            o.receiveShadow = true;
          }
        });
        const overrides = e.visual.material_overrides;
        if (isDict(overrides)) this.applyMaterialOverrides(imported, overrides);
        const norm = new THREE.Group();
        norm.name = "GlbNormalizer";
        norm.add(imported);
        node.group.add(norm);
        const rules = e.visual.animation_state_rules;
        if (gltf.animations.length > 0) {
          // An animated model keeps its authored scale and pivot. Its clips play under the state rules.
          if (Array.isArray(rules)) {
            if (hasDefault(rules)) node.animator = new Animator(imported, gltf.animations, rules, Number(e.visual.animation_blend_seconds ?? 0.15));
            else console.warn(`[render3d] '${e.id}': animation_state_rules has no 'default' fallback`);
          }
        } else if (normalize) {
          const box = new THREE.Box3().setFromObject(imported);
          const size = box.getSize(new THREE.Vector3());
          if (size.y > 0.0001) {
            const k = 1 / size.y;
            norm.scale.setScalar(k);
            norm.position.set(-(box.min.x + size.x / 2) * k, -box.min.y * k, -(box.min.z + size.z / 2) * k);
            node.normalized = true;
          }
        }
        this.applyShadowOnly(e, node.group);
      },
      () => {
        this.pending--;
        console.info(`[render3d] '${e.id}': GLB not found at ${path}, bare box`);
        this.addBareBox(e, node.group);
      },
    );
  }

  /** AssetPath.resolve: a path relative to the game folder, or @lib/<path>. */
  private assetUrl(path: string): string {
    const p = path.trim();
    if (p === "" || p.includes("://") || p.startsWith("/") || p.split("/").includes("..")) {
      console.error(`asset_path.not_neutral: '${p}' (ADR 0087)`);
      return "";
    }
    return this.assetBase + p.split("/").map(encodeURIComponent).join("/");
  }

  /** EntityMesh3D._apply_material_overrides: by material name, else by "surface_<i>". */
  private applyMaterialOverrides(root: THREE.Object3D, overrides: Dict): void {
    root.traverse((o) => {
      if (!(o instanceof THREE.Mesh)) return;
      const mats = Array.isArray(o.material) ? o.material : [o.material];
      const out = mats.map((m: THREE.Material, i: number) => {
        const key = m.name !== "" && m.name in overrides ? m.name : `surface_${i}` in overrides ? `surface_${i}` : "";
        if (key === "") return m;
        const dup = m instanceof THREE.MeshStandardMaterial ? m.clone() : new THREE.MeshStandardMaterial();
        const od = overrides[key];
        if (!isDict(od)) {
          dup.color = colorOf(od);
          return dup;
        }
        if ("albedo_color" in od) dup.color = colorOf(od.albedo_color);
        if ("albedo_texture" in od) {
          const url = this.assetUrl(String(od.albedo_texture));
          if (url !== "") {
            const tex = this.textures.load(url);
            tex.colorSpace = THREE.SRGBColorSpace;
            tex.flipY = false;
            dup.map = tex;
          }
        }
        if ("normal_texture" in od) {
          const url = this.assetUrl(String(od.normal_texture));
          if (url !== "") {
            const tex = this.textures.load(url);
            tex.flipY = false;
            dup.normalMap = tex;
          }
        }
        if ("roughness" in od) {
          dup.roughness = toFloat(od.roughness);
          dup.roughnessMap = null;
        }
        if ("metallic" in od) {
          dup.metalness = toFloat(od.metallic);
          dup.metalnessMap = null;
        }
        return dup;
      });
      o.material = Array.isArray(o.material) ? out : out[0];
    });
  }

  /** CameraDirector._apply_mesh_visibility_for_mode: the first-person actor casts a shadow only. */
  private applyShadowOnly(e: Entity, group: THREE.Group): void {
    const followTag = String(this.cam.follow_tag ?? "player");
    if (e.visual.hide_for_camera_attach !== true || !e.hasTag(followTag)) return;
    if (String(this.cam.mode ?? "") !== "first_person_3d") return;
    group.traverse((o) => o.layers.set(SHADOW_ONLY_LAYER));
  }

  /** EntityMesh3D._sync_position, _sync_yaw and _sync_scale. */
  private place(e: Entity, g: THREE.Group, normalized: boolean): void {
    const p = e.position();
    const s = this.positionScale;
    if (p instanceof Vec3) g.position.set(p.x * s, p.y * s, p.z * s);
    else if (p instanceof Vec2) g.position.set(p.x * s, 0, p.y * s);
    const v = e.visual;
    if ("y_offset_mesh" in v) g.position.y += toFloat(v.y_offset_mesh) * yScale(e);
    else if ("y_offset" in v) g.position.y += toFloat(v.y_offset);
    const yaw = e.getState("yaw", null) ?? e.getState("facing", null);
    if (yaw !== null) g.rotation.y = toFloat(yaw) + toFloat(e.properties.mesh_yaw_offset ?? 0);
    const sc = e.getState("scale", null);
    if (sc === null) return;
    if (normalized) {
      // A normalized GLB is one unit tall. Its scale is the height (scale.y).
      g.scale.setScalar(typeof sc === "number" ? sc : sc instanceof Vec3 ? sc.y : Array.isArray(sc) && sc.length >= 2 ? toFloat(sc[1]) : 1);
      return;
    }
    if (typeof sc === "number") g.scale.setScalar(sc);
    else if (sc instanceof Vec3) g.scale.set(sc.x, sc.y, sc.z);
    else if (Array.isArray(sc)) {
      if (sc.length === 3) g.scale.set(toFloat(sc[0]), toFloat(sc[1]), toFloat(sc[2]));
      else if (sc.length === 2) g.scale.set(toFloat(sc[0]), toFloat(sc[0]), toFloat(sc[1]));
    }
  }

  // ---------------------------------------------------------------- camera

  /** CameraDirector.update_follow for the 3D modes. Returns the focus point for the sun's shadow box. */
  private updateCamera(world: World): THREE.Vector3 {
    const cfg = this.cam;
    const mode = String(cfg.mode ?? "");
    const actor = this.followEntity(world);
    if (!actor) return this.camPos.clone();
    const p = actor.position();
    const target = p instanceof Vec3 ? new THREE.Vector3(p.x, p.y, p.z) : p instanceof Vec2 ? new THREE.Vector3(p.x, 0, p.y) : new THREE.Vector3();
    const lerpT = toFloat(cfg.lerp ?? 0.1);
    const moveTo = (desired: THREE.Vector3) => {
      if (this.snap) this.camPos.copy(desired);
      else this.camPos.lerp(desired, lerpT);
      this.snap = false;
    };
    switch (mode) {
      case "top_down_3d": {
        moveTo(target.clone().add(new THREE.Vector3(0, toFloat(cfg.height ?? 20), 0)));
        this.useProjection(true);
        this.active.position.copy(this.camPos);
        this.active.up.set(0, 0, -1);
        this.active.lookAt(target);
        break;
      }
      case "isometric_3d": {
        const d = toFloat(cfg.distance ?? 16);
        const desired = target.clone().add(new THREE.Vector3(d * 0.6, d * 0.7, d * 0.6));
        moveTo(desired);
        this.useProjection(true);
        this.active.position.copy(this.camPos);
        this.active.up.set(0, 1, 0);
        // Fixed orientation against the final position (engine-scripts.md, camera stability).
        this.active.lookAt(this.camPos.clone().add(target.clone().sub(desired)));
        break;
      }
      case "third_person_3d": {
        this.drainMouse(actor);
        const facing = heading(actor, cfg);
        const pitch = toFloat(actor.getState("pitch", 0));
        const dDefault = toFloat(cfg.distance ?? 12);
        const dmin = toFloat(cfg.distance_min ?? dDefault);
        const dmax = toFloat(cfg.distance_max ?? dDefault);
        const distance = Math.min(Math.max(toFloat(actor.getState("camera_distance", dDefault)), dmin), dmax);
        const height = toFloat(cfg.height ?? 5);
        const ph = height - Math.sin(pitch) * distance;
        const pd = distance * Math.cos(pitch);
        const fx = -Math.sin(facing);
        const fz = -Math.cos(facing);
        const shoulder = toFloat(cfg.shoulder_offset ?? 0);
        const right = new THREE.Vector3(Math.cos(facing), 0, -Math.sin(facing));
        const desired = target.clone().add(new THREE.Vector3(-fx * pd, ph, -fz * pd)).addScaledVector(right, shoulder);
        moveTo(desired);
        this.useProjection(false);
        this.active.position.copy(this.camPos);
        this.active.up.set(0, 1, 0);
        const look = target.clone().add(new THREE.Vector3(0, toFloat(cfg.eye_height ?? 1.6), 0)).addScaledVector(right, shoulder);
        this.active.lookAt(look);
        break;
      }
      case "first_person_3d": {
        this.drainMouse(actor);
        const facing = heading(actor, cfg);
        const pitch = toFloat(actor.getState("pitch", 0));
        this.camPos.copy(target).add(new THREE.Vector3(0, toFloat(cfg.eye_height ?? 1.7), 0));
        this.useProjection(false);
        this.active.position.copy(this.camPos);
        this.active.rotation.set(pitch, facing, 0, "YXZ");
        this.updateViewmodel(actor);
        break;
      }
      default:
        console.info(`[camera] mode '${mode}' is not in this host yet`);
    }
    return target;
  }

  private viewmodel: THREE.Group | null = null;
  private viewmodelMeshes = new Map<string, THREE.Group>();

  /**
   * ViewmodelDirector.setup and update: one library mesh for each weapon,
   * at `offset` in camera space. The mesh whose key is the actor's
   * follow_state value shows, and the others hide.
   */
  private updateViewmodel(actor: Entity): void {
    const vm = this.cam.viewmodel;
    if (!isDict(vm)) return;
    if (!this.viewmodel) {
      const weapons = isDict(vm.weapons) ? vm.weapons : {};
      if (Object.keys(weapons).length === 0) return;
      this.viewmodel = new THREE.Group();
      this.viewmodel.name = "Viewmodel";
      const off = Array.isArray(vm.offset) && vm.offset.length >= 3 ? vm.offset.map(toFloat) : [0.3, -0.25, -0.5];
      this.viewmodel.position.set(off[0], off[1], off[2]);
      for (const key of Object.keys(weapons)) {
        const w = weapons[key];
        const name = isDict(w) ? String(w.mesh ?? "") : "";
        if (name === "" || !this.lib.has(name)) continue;
        const def = this.lib.get(name);
        const g = new THREE.Group();
        g.name = `vm_${key}`;
        g.visible = false;
        this.lib.buildInto(g, Array.isArray(def.primitives) ? def.primitives : [], MeshLib.mergeParams(def, isDict(w) ? w.params : {}));
        this.viewmodel.add(g);
        this.viewmodelMeshes.set(key, g);
      }
      this.camera.add(this.viewmodel);
      // A camera's children render only when the camera is in the scene.
      if (!this.camera.parent) this.scene.add(this.camera);
    }
    const field = String(vm.follow_state ?? "");
    if (field === "") return;
    const v = actor.getState(field, "");
    const current = typeof v === "number" ? String(Math.trunc(v)) : String(v);
    for (const [k, g] of this.viewmodelMeshes) g.visible = k === current;
  }

  /** CameraDirector._apply_ortho: the mode default, then `projection`, ortho_size, fov or focal_length_mm. */
  private useProjection(wantOrtho: boolean): void {
    const cfg = this.cam;
    const proj = String(cfg.projection ?? "").toLowerCase();
    const ortho = proj === "orthographic" || proj === "ortho" ? true : proj === "perspective" || proj === "persp" ? false : wantOrtho;
    const near = toFloat(cfg.clip_near ?? 0.05);
    const far = toFloat(cfg.clip_far ?? 4000);
    const size = this.renderer.getSize(new THREE.Vector2());
    const aspect = size.x / Math.max(size.y, 1);
    if (ortho) {
      // Godot's ortho size is the full view height (keep height).
      const h = Math.max(0.01, toFloat(cfg.ortho_size ?? 16)) / 2;
      Object.assign(this.ortho, { left: -h * aspect, right: h * aspect, top: h, bottom: -h, near, far });
      this.ortho.updateProjectionMatrix();
      this.active = this.ortho;
    } else {
      const focal = toFloat(cfg.focal_length_mm ?? 0);
      const fov = focal > 0 ? (2 * Math.atan(36 / (2 * focal)) * 180) / Math.PI : toFloat(cfg.fov ?? 75);
      Object.assign(this.camera, { fov: Math.min(Math.max(fov, 1), 179), aspect, near, far });
      this.camera.updateProjectionMatrix();
      this.active = this.camera;
    }
  }

  /** CameraDirector._drain_mouse_facing: captured mouse motion turns the actor (facing, pitch). */
  private drainMouse(actor: Entity): void {
    if (!this.mouseCaptured || this.mouseDelta.lengthSq() === 0) {
      this.mouseDelta.set(0, 0);
      return;
    }
    const sens = toFloat(this.cam.mouse_sensitivity ?? 0.003);
    actor.setState("facing", toFloat(actor.getState("facing", 0)) - this.mouseDelta.x * sens);
    if (this.cam.use_pitch !== false) {
      const lim = Math.PI / 2 - 0.05;
      const pitch = toFloat(actor.getState("pitch", 0)) - this.mouseDelta.y * sens;
      actor.setState("pitch", Math.min(Math.max(pitch, -lim), lim));
    }
    this.mouseDelta.set(0, 0);
  }

  /** CameraDirector._resolve_follow_entity: the first entity with follow_tag, else the entity with that id. */
  private followEntity(world: World): Entity | null {
    const tag = String(this.cam.follow_tag ?? "");
    if (tag === "") return null;
    for (const e of world.env.entities.values()) if (e.hasTag(tag)) return e;
    return world.env.entities.get(tag) ?? null;
  }

  /** The reference shakes only its 2D camera (CameraDirector.apply_shake moves Camera2D.offset). */
  shake(_intensity: number, _frames: number): void {}

  render(): void {
    const size = this.renderer.getSize(new THREE.Vector2());
    if (this.active === this.camera) {
      this.camera.aspect = size.x / Math.max(size.y, 1);
      this.camera.updateProjectionMatrix();
    }
    this.renderWaterInputs();
    if (this.usesPost()) {
      this.renderPost(size);
      return;
    }
    this.renderer.render(this.scene, this.active);
  }

  private water: THREE.Mesh | null = null;
  private waterTarget: THREE.WebGLRenderTarget | null = null;

  /** hint_screen_texture and hint_depth_texture: the opaque scene with the water hidden, for the water shader. */
  private renderWaterInputs(): void {
    if (!this.water) return;
    const size = this.renderer.getDrawingBufferSize(new THREE.Vector2());
    if (!this.waterTarget || this.waterTarget.width !== size.x || this.waterTarget.height !== size.y) {
      this.waterTarget?.dispose();
      this.waterTarget = new THREE.WebGLRenderTarget(size.x, size.y, { type: THREE.HalfFloatType, depthTexture: new THREE.DepthTexture(size.x, size.y) });
    }
    this.water.visible = false;
    this.renderer.setRenderTarget(this.waterTarget);
    this.renderer.render(this.scene, this.active);
    this.renderer.setRenderTarget(null);
    this.water.visible = true;
    const u = (this.water.material as THREE.Material).userData.uniforms as Record<string, THREE.IUniform>;
    const cam = this.active as THREE.PerspectiveCamera | THREE.OrthographicCamera;
    u.screen_tex.value = this.waterTarget.texture;
    u.depth_tex.value = this.waterTarget.depthTexture;
    u.screenSize.value.copy(size);
    u.camNear.value = cam.near;
    u.camFar.value = cam.far;
    u.camOrtho.value = cam instanceof THREE.OrthographicCamera;
    u.TIME.value = performance.now() / 1000;
  }

  private composer: EffectComposer | null = null;
  private renderPass: RenderPass | null = null;
  private aoPass: GTAOPass | null = null;
  private bloomPass: UnrealBloomPass | null = null;
  private bcsPass: ShaderPass | null = null;

  private enabledBlock(name: string): Dict | null {
    const b = this.lighting[name];
    return isDict(b) && b.enabled !== false ? b : null;
  }

  private usesPost(): boolean {
    return ["adjustments", "glow"].some((n) => this.enabledBlock(n) !== null);
  }

  /**
   * The post chain of Godot's Environment, in its order: SSAO and glow on
   * the HDR frame, the tonemap and the sRGB step (OutputPass), then the
   * adjustments.
   *   ssao         GTAO. Godot darkens only the ambient light
   *                (ssao_light_affect 0), and GTAO darkens the whole frame.
   *                So its blend is intensity × AO_AMBIENT_SHARE, at most 1.
   *   glow         UnrealBloomPass: strength intensity × strength,
   *                threshold hdr_threshold.
   *   adjustments  apply_bcs on the sRGB values. A pixel check against the
   *                lanterns Godot capture chose this order: in linear space
   *                the colors crushed.
   */
  private renderPost(size: THREE.Vector2): void {
    // The reference runs Godot's gl_compatibility renderer (project.godot), which
    // does not draw SSAO. So this host does not draw it either. GTAO stays wired
    // for a reference on Forward+, and AO_AMBIENT_SHARE stays its blend.
    const ssao = REFERENCE_DRAWS_SSAO ? this.enabledBlock("ssao") : null;
    const glow = this.enabledBlock("glow");
    const adj = this.enabledBlock("adjustments");
    if (!this.composer) {
      this.composer = new EffectComposer(this.renderer);
      this.renderPass = new RenderPass(this.scene, this.active);
      this.composer.addPass(this.renderPass);
      if (ssao) {
        this.aoPass = new GTAOPass(this.scene, this.active, size.x, size.y);
        this.aoPass.updateGtaoMaterial({ radius: toFloat(ssao.radius ?? 1) });
        this.aoPass.blendIntensity = Math.min(toFloat(ssao.intensity ?? 2) * AO_AMBIENT_SHARE, 1);
        this.composer.addPass(this.aoPass);
      }
      if (glow) {
        this.bloomPass = new UnrealBloomPass(size, toFloat(glow.intensity ?? 0.8) * toFloat(glow.strength ?? 1), 0.4, toFloat(glow.hdr_threshold ?? 1));
        this.composer.addPass(this.bloomPass);
      }
      this.composer.addPass(new OutputPass());
      if (adj) {
        this.bcsPass = new ShaderPass({
          uniforms: { tDiffuse: { value: null }, bcs: { value: new THREE.Vector3(1, 1, 1) } },
          vertexShader: `varying vec2 vUv;
void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
          fragmentShader: `uniform sampler2D tDiffuse; uniform vec3 bcs;
varying vec2 vUv;
vec3 applyBcs(vec3 color) {
  color = mix(vec3(0.0), color, bcs.x);
  color = mix(vec3(0.5), color, bcs.y);
  color = mix(vec3(dot(vec3(1.0), color) * 0.33333), color, bcs.z);
  return color;
}
void main() {
  vec4 c = texture2D(tDiffuse, vUv);
  gl_FragColor = vec4(clamp(applyBcs(c.rgb), 0.0, 1.0), c.a);
}`,
        });
        this.composer.addPass(this.bcsPass);
      }
    }
    this.renderPass!.camera = this.active;
    if (this.aoPass) this.aoPass.camera = this.active;
    this.composer.setSize(size.x, size.y);
    if (this.bcsPass && adj) this.bcsPass.uniforms.bcs.value.set(toFloat(adj.brightness ?? 1), toFloat(adj.contrast ?? 1), toFloat(adj.saturation ?? 1));
    this.composer.render();
  }
}

/**
 * EntityMesh3D._shape_mesh: a mesh that matches a link collision shape, or
 * null for a link with no shape. A URDF root link often has no shape, and a
 * default box would hide the robot.
 */
function linkShapeMesh(shape: Dict, color: unknown): THREE.Mesh | null {
  if (!("type" in shape)) return null;
  let geo: THREE.BufferGeometry;
  switch (String(shape.type)) {
    case "box": {
      const sz = Array.isArray(shape.size) ? shape.size.map(toFloat) : [1, 1, 1];
      geo = new THREE.BoxGeometry(sz[0], sz[1], sz[2]);
      break;
    }
    case "sphere":
      geo = new THREE.SphereGeometry(toFloat(shape.radius ?? 0.5), 32, 16);
      break;
    case "cylinder": {
      const r = toFloat(shape.radius ?? 0.4);
      geo = new THREE.CylinderGeometry(r, r, toFloat(shape.height ?? 1.0), 32);
      break;
    }
    case "capsule": {
      // Godot's capsule height includes both caps.
      const r = toFloat(shape.radius ?? 0.4);
      geo = new THREE.CapsuleGeometry(r, Math.max(toFloat(shape.height ?? 1.0) - 2 * r, 0), 8, 24);
      break;
    }
    default:
      return null;
  }
  const mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: colorOf(color) }));
  const t = shapeTransform(shape);
  mesh.position.set(...t.p);
  mesh.quaternion.set(...t.q);
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  return mesh;
}

/** CameraDirector.heading_of (ADR 0094): `facing` or `yaw`. */
function heading(actor: Entity, cfg: Dict): number {
  const src = String(cfg.heading ?? "facing");
  return toFloat(actor.getState(src === "yaw" ? "yaw" : "facing", 0));
}

/** EntityMesh3D._read_y_scale. */
function yScale(e: Entity): number {
  const s = e.getState("scale", 1);
  if (typeof s === "number") return s;
  if (s instanceof Vec3) return s.y;
  if (Array.isArray(s)) return toFloat(s.length === 3 ? s[1] : s[0]);
  return 1;
}

/** LightingDirector.day_factor: 0 at midnight, 1 at noon. */
export function dayFactor(t: number): number {
  return (1 - Math.cos((mod(t, HOURS_PER_DAY) / HOURS_PER_DAY) * Math.PI * 2)) / 2;
}

/** LightingDirector.sun_direction_at: straight down at noon, along +x at 6:00. */
export function sunDirectionAt(t: number): THREE.Vector3 {
  const angle = (mod(t, HOURS_PER_DAY) / 12) * Math.PI - Math.PI / 2;
  return new THREE.Vector3(Math.cos(angle), -Math.sin(angle), 0).normalize();
}

function mod(a: number, n: number): number {
  return ((a % n) + n) % n;
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

/** LightingDirector.SKY_DAY_NIGHT: [day field, night field, day default, night default]. */
const SKY_DAY_NIGHT: Record<string, [string, string, string, string]> = {
  sky_top_color: ["sky_top_color_day", "sky_top_color_night", "#5890d8", "#0a1530"],
  sky_horizon_color: ["horizon_day", "horizon_night", "#80a0e0", "#101020"],
  cloud_color: ["cloud_color_day", "cloud_color_night", "#f0eee8", "#383848"],
  cloud_shadow_color: ["cloud_shadow_color_day", "cloud_shadow_color_night", "#888888", "#1a1a25"],
};

/** LightingDirector.sky_color_at. */
function skyColorAt(sky: Dict, uniform: string, f: number): THREE.Color {
  const [dayField, nightField, dayDefault, nightDefault] = SKY_DAY_NIGHT[uniform];
  const params = isDict(sky.shader_params) ? sky.shader_params : {};
  const dayV = uniform in params ? params[uniform] : dayDefault;
  return colorOf(sky[nightField] ?? nightDefault).lerp(colorOf(sky[dayField] ?? dayV), f);
}

/** An sRGB color from Godot's float components, as a linear three.js color. */
function linear(r: number, g: number, b: number): THREE.Color {
  return new THREE.Color().setRGB(r, g, b, THREE.SRGBColorSpace);
}

/**
 * Adds the sky fog of Godot 4 (sky.glsl fog_process) to a sky material. The
 * fog color is fog_light_color × energy mixed toward the sky color by
 * fog_aerial_perspective, plus light × pow(max(dot(view, to_sun), 0), 8) ×
 * fog_sun_scatter. The fog amount is 1 - exp(-1e8 × density), which is 1 for
 * any fog, and fog_sky_affect is Godot's default of 1. skyFogOn stays 0 until
 * the scene has fog.
 */
export function withSkyFog(mat: THREE.ShaderMaterial): THREE.ShaderMaterial {
  Object.assign(mat.uniforms, {
    skyFogOn: { value: 0 },
    skyFogColor: { value: new THREE.Color() },
    skyFogAerial: { value: 0 },
    skyFogScatter: { value: 0 },
    skySunDir: { value: new THREE.Vector3(0, 1, 0) },
    skySunColor: { value: new THREE.Color() },
  });
  const re = /gl_FragColor = vec4\((\w+), 1\.0\);/;
  if (!re.test(mat.fragmentShader)) throw new Error("withSkyFog: the sky shader has no gl_FragColor = vec4(<color>, 1.0)");
  mat.fragmentShader = mat.fragmentShader
    .replace("varying vec3 vDir;", "varying vec3 vDir;\nuniform float skyFogOn; uniform vec3 skyFogColor; uniform float skyFogAerial; uniform float skyFogScatter; uniform vec3 skySunDir; uniform vec3 skySunColor;")
    .replace(
      re,
      `if (skyFogOn > 0.5) {
    vec3 fogC = mix(skyFogColor, $1, skyFogAerial);
    fogC += skySunColor * pow(max(dot(normalize(vDir), skySunDir), 0.0), 8.0) * skyFogScatter;
    $1 = fogC;
  }
  gl_FragColor = vec4($1, 1.0);`,
    );
  return mat;
}

/** Godot's ProceduralSkyMaterial: sky_curve 0.15 above the horizon, ground_curve 0.02 below it. */
function skyMaterial(): THREE.ShaderMaterial {
  return new THREE.ShaderMaterial({
    side: THREE.BackSide,
    depthWrite: false,
    fog: false,
    uniforms: {
      top: { value: new THREE.Color() },
      horizon: { value: new THREE.Color() },
      groundHorizon: { value: new THREE.Color() },
      groundBottom: { value: new THREE.Color() },
    },
    vertexShader: `varying vec3 vDir;
void main() {
  vDir = normalize(position);
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}`,
    fragmentShader: `uniform vec3 top; uniform vec3 horizon; uniform vec3 groundHorizon; uniform vec3 groundBottom;
varying vec3 vDir;
const float PI = 3.14159265;
void main() {
  float v = acos(clamp(normalize(vDir).y, -1.0, 1.0));
  vec3 c;
  if (v < PI * 0.5) {
    float k = 1.0 - v / (PI * 0.5);
    c = mix(horizon, top, clamp(1.0 - pow(1.0 - k, 1.0 / 0.15), 0.0, 1.0));
  } else {
    float k = (v - PI * 0.5) / (PI * 0.5);
    c = mix(groundHorizon, groundBottom, clamp(1.0 - pow(1.0 - k, 1.0 / 0.02), 0.0, 1.0));
  }
  gl_FragColor = vec4(c, 1.0);
  #include <colorspace_fragment>
}`,
  });
}
