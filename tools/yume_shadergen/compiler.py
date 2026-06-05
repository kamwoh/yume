"""
ADR 0058 Phase B: shader DAG compiler.

Walks a JSON DAG declared in scene.json under
`ground.mesh.shader_dag`, validates types, and emits a concrete
`.gdshader`. Each DAG node references a primitive from
`data/lib/shaders/primitives/<id>.json`; primitives carry hand-tuned
GLSL Jinja2 fragments that the compiler stitches together in order.

Per docs/guideline/00_what_yume_is.md, the shader system is projection-
configuration = content = JSON-driven. Phase A used a monolithic
Jinja template; Phase B's primitives are reusable across shader
domains (ground, water, sky, ...).

DAG format (scene.json under ground.mesh):

    "shader_dag": {
      "stages": {
        "vertex":   [<op>, <op>, ...],
        "fragment": [<op>, <op>, ...]
      }
    }

Each <op>:

    {"op": "primitive_id",
     "in": {"input_name": "$spec_param" | "@local_var" | <literal>, ...},
     "out": "local_var_name"  OR  {"output_a": "var_a", ...}}

Spec params resolve from `ground.mesh` (anywhere except `shader_dag`).
Common ones: biomes (list<biome>), heightmap (string path), height_scale
(float), uv_tile (float), etc.

Builtins recognized as `out` targets: NORMAL, ALBEDO, ROUGHNESS,
METALLIC, VERTEX. The compiler routes those to direct assignments
in the emitted GLSL.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import jinja2
except ImportError:
    raise ImportError("compiler requires jinja2; pip install jinja2")


BUILTINS = {"NORMAL", "ALBEDO", "ROUGHNESS", "METALLIC", "VERTEX",
            "ALPHA", "EMISSION"}

# Known Godot spatial-shader builtins + Yume conventional varyings.
# Used by the type checker to validate string references that aren't
# $spec or @local. New varyings declared by primitives should be
# added here OR carried through the primitives' `varyings` lists.
WELL_KNOWN_TYPES: dict[str, str] = {
    "NORMAL": "vec3",
    "ALBEDO": "vec3",
    "VERTEX": "vec3",
    "ROUGHNESS": "float",
    "METALLIC": "float",
    "ALPHA": "float",
    "EMISSION": "vec3",
    "UV": "vec2",
    "TIME": "float",
    "MODEL_MATRIX": "mat4",
    # Yume varyings (per data/lib/shaders/primitives/world_pos_from_model.json)
    "v_world_pos": "vec3",
}


@dataclass
class Primitive:
    """A loaded primitive definition."""
    id: str
    description: str
    stage: str  # "vertex" | "fragment" | "both"
    inputs: dict[str, dict[str, Any]]
    outputs: dict[str, dict[str, Any]]
    uniforms: list[dict[str, Any]]
    varyings: list[str]
    glsl_vertex: str = ""
    glsl_fragment: str = ""


@dataclass
class CompiledStage:
    """Per-stage compiled output."""
    glsl: str = ""
    declared_uniforms: dict[str, dict[str, Any]] = field(default_factory=dict)
    declared_varyings: set[str] = field(default_factory=set)
    local_types: dict[str, str] = field(default_factory=dict)  # var name → type


import re

# Lines like `vec3 NORMAL = ...` need to become `NORMAL = ...` —
# builtins are pre-declared by Godot. Same for ALBEDO / ROUGHNESS / METALLIC / VERTEX.
_BUILTIN_DECL_RE = re.compile(
    r"^(\s*)(?:vec[234]|float|int|bool)\s+(NORMAL|ALBEDO|ROUGHNESS|METALLIC|VERTEX|ALPHA|EMISSION)(\s*=)",
    re.MULTILINE,
)


def strip_builtin_type_prefix(glsl: str) -> str:
    """Replace `vec3 NORMAL = ...` with `NORMAL = ...` so Godot accepts it."""
    return _BUILTIN_DECL_RE.sub(r"\1\2\3", glsl)


@dataclass
class CompiledShader:
    """Full compiled shader."""
    uniforms_block: str
    varyings_block: str
    vertex_glsl: str
    fragment_glsl: str

    def full_source(self) -> str:
        parts = [
            "shader_type spatial;",
            "render_mode blend_mix, cull_back, depth_draw_opaque;",
            "",
            self.uniforms_block.strip(),
            "",
            self.varyings_block.strip() if self.varyings_block else "",
            "",
            "void vertex() {",
            self._indent(self.vertex_glsl),
            "}",
            "",
            "void fragment() {",
            self._indent(self.fragment_glsl),
            "}",
            "",
        ]
        return "\n".join(p for p in parts if p is not None) + "\n"

    @staticmethod
    def _indent(body: str) -> str:
        return "\n".join("    " + line if line.strip() else line
                         for line in body.splitlines())


class CompilerError(Exception):
    """Raised when DAG validation fails."""


def load_primitives(primitives_dir: Path) -> dict[str, Primitive]:
    """Walk the primitives directory, load each JSON file."""
    out: dict[str, Primitive] = {}
    for fp in sorted(primitives_dir.glob("*.json")):
        if fp.name.startswith("_"):
            continue
        d = json.loads(fp.read_text())
        out[d["id"]] = Primitive(
            id=d["id"],
            description=d.get("description", ""),
            stage=d.get("stage", "fragment"),
            inputs=d.get("inputs", {}),
            outputs=d.get("outputs", {}),
            uniforms=d.get("uniforms", []),
            varyings=d.get("varyings", []),
            glsl_vertex=d.get("glsl_vertex", ""),
            glsl_fragment=d.get("glsl_fragment", ""),
        )
    return out


def resolve_in(value: Any, spec_params: dict[str, Any],
               locals_: dict[str, str], stage: str) -> tuple[Any, str | None]:
    """Resolve a DAG `in` value. Returns (resolved_value, source_kind).

    - `$key` → look up in spec_params (returns the value as-is)
    - `@var` → look up in locals (returns the var name string)
    - literal → returns as-is
    """
    if isinstance(value, str):
        if value.startswith("$"):
            key = value[1:]
            if key not in spec_params:
                raise CompilerError(
                    f"[{stage}] $key '{key}' not in spec — available: "
                    f"{sorted(spec_params.keys())}"
                )
            return spec_params[key], "spec"
        if value.startswith("@"):
            key = value[1:]
            if key not in locals_:
                raise CompilerError(
                    f"[{stage}] @var '{key}' not declared by a prior op — "
                    f"locals so far: {sorted(locals_.keys())}"
                )
            return key, "local"
    return value, "literal"


def emit_op_glsl(prim: Primitive, op: dict[str, Any],
                 spec_params: dict[str, Any], stage_state: CompiledStage,
                 stage: str) -> str:
    """Render the primitive's GLSL fragment for this op invocation."""
    in_block = op.get("in", {})
    out_block = op.get("out", "")

    # Resolve inputs
    resolved_inputs: dict[str, Any] = {}
    for in_name, in_def in prim.inputs.items():
        if in_name in in_block:
            value, kind = resolve_in(in_block[in_name], spec_params,
                                     stage_state.local_types, stage)
        elif "default" in in_def:
            value, kind = in_def["default"], "literal"
        else:
            raise CompilerError(
                f"[{stage}] {prim.id}: missing required input '{in_name}'"
            )
        # For list<biome>, expose both the rendered string AND the raw list
        # so templates can `{% for b in inputs.X_list %}`.
        if in_def.get("type", "").startswith("list<") and isinstance(value, list):
            resolved_inputs[in_name] = value  # use list directly
            resolved_inputs[f"{in_name}_list"] = value
        elif isinstance(value, float):
            # Format floats with enough precision but no trailing junk
            resolved_inputs[in_name] = f"{value:.6f}".rstrip("0").rstrip(".") or "0.0"
            if "." not in resolved_inputs[in_name]:
                resolved_inputs[in_name] += ".0"
        else:
            resolved_inputs[in_name] = value

    # Resolve outputs
    resolved_outputs: dict[str, str] = {}
    if isinstance(out_block, str):
        # Single output → map to the (first) declared output name
        if len(prim.outputs) == 1:
            out_name = next(iter(prim.outputs))
            resolved_outputs[out_name] = out_block
        elif len(prim.outputs) == 0:
            pass  # void primitive
        else:
            raise CompilerError(
                f"[{stage}] {prim.id}: primitive has {len(prim.outputs)} "
                f"outputs but 'out' is a single string — provide a dict"
            )
    elif isinstance(out_block, dict):
        for out_name in prim.outputs:
            if out_name in out_block:
                resolved_outputs[out_name] = out_block[out_name]

    # Track new locals (skipping builtins)
    for out_name, var_name in resolved_outputs.items():
        if var_name in BUILTINS:
            continue
        out_type = prim.outputs[out_name].get("type", "float")
        stage_state.local_types[var_name] = out_type

    # Track declared uniforms (dedupe by name)
    for u in prim.uniforms:
        if u["name"] not in stage_state.declared_uniforms:
            stage_state.declared_uniforms[u["name"]] = u
    # Auto-declare sampler2D inputs as uniforms — the input VALUE
    # (a string from $spec or @local or literal) is the uniform name.
    # E.g., DAG passes "map": "$heightmap" → spec_params.heightmap is
    # the path; the input value is "heightmap" (a uniform reference)
    # because spec_params just contains the bare path string. But for
    # sampler2D uniforms we want the uniform name itself, which the
    # spec_params stores under the same key — so we use the key, not
    # the value. The DAG should reference uniforms by name via $key
    # where the spec_params holds the path. Convention: the spec key
    # name IS the uniform name.
    for in_name, in_def in prim.inputs.items():
        if in_def.get("type") != "sampler2D":
            continue
        # Look up what the DAG passed for this input
        raw = in_block.get(in_name)
        if isinstance(raw, str) and raw.startswith("$"):
            uniform_name = raw[1:]  # spec key = uniform name
        elif isinstance(raw, str) and not raw.startswith("@"):
            uniform_name = raw  # literal name
        else:
            continue  # @local or non-string — not a uniform
        if uniform_name not in stage_state.declared_uniforms:
            # Pick reasonable defaults based on what the input doc suggests
            hint = "source_color, filter_linear, repeat_disable"
            if "albedo" in uniform_name or "color" in uniform_name:
                hint = "source_color, filter_linear_mipmap, repeat_enable"
            stage_state.declared_uniforms[uniform_name] = {
                "name": uniform_name,
                "type": "sampler2D",
                "hint": hint,
            }
        # The rendered inputs.<in_name> now needs to be the uniform name
        resolved_inputs[in_name] = uniform_name
    # Plus biome-derived uniforms (handled separately below)

    # Track declared varyings
    for v in prim.varyings:
        stage_state.declared_varyings.add(v)

    # Render GLSL
    template_str = prim.glsl_vertex if stage == "vertex" else prim.glsl_fragment
    if not template_str:
        return ""
    env = jinja2.Environment()
    template = env.from_string(template_str)
    return template.render(
        inputs=resolved_inputs,
        outputs=resolved_outputs,
    )


def collect_biome_albedo_uniforms(dag: dict[str, Any],
                                  spec_params: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """If the DAG references the biomes list, emit one albedo_<name>
    sampler2D uniform per biome (since primitives can't emit
    parameterized-count uniforms via their static `uniforms` list)."""
    biomes = spec_params.get("biomes", [])
    out: dict[str, dict[str, Any]] = {}
    if isinstance(biomes, list):
        for b in biomes:
            if not isinstance(b, dict) or "name" not in b:
                continue
            name = f"albedo_{b['name']}"
            out[name] = {
                "name": name,
                "type": "sampler2D",
                "hint": "source_color, filter_linear_mipmap, repeat_enable",
            }
    return out


def _spec_type(value: Any) -> str:
    """Infer a type tag from a spec_params value."""
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, list):
        # vec2/3/4 if numeric components; list<biome> if dicts with biome shape
        if value and all(isinstance(e, dict) for e in value):
            if all("name" in e and "color" in e for e in value):
                return "list<biome>"
            return "list<dict>"
        if value and all(isinstance(e, (int, float)) for e in value):
            return f"vec{len(value)}" if 2 <= len(value) <= 4 else "list<float>"
        return "list<unknown>"
    if isinstance(value, str):
        # Heuristic: looks-like-texture-path → sampler2D
        if value.endswith((".png", ".jpg", ".jpeg", ".gltf", ".glb")) or value.startswith("res://"):
            return "sampler2D"
        return "string"
    return "unknown"


# Compatible-with rules. Loose where the GLSL allows implicit promotion
# (int → float), strict otherwise.
_TYPE_COMPATIBLE: dict[str, set[str]] = {
    "float": {"float", "int"},
    "int": {"int"},
    "bool": {"bool"},
    "vec2": {"vec2"},
    "vec3": {"vec3"},
    "vec4": {"vec4"},
    "sampler2D": {"sampler2D"},
    "list<float>": {"list<float>"},
    "list<biome>": {"list<biome>"},
    "list<dict>": {"list<biome>", "list<dict>"},
    "string": {"string", "sampler2D"},  # paths come through as strings
}


def types_compatible(expected: str, actual: str) -> bool:
    """Return True if a value of type `actual` can satisfy an input
    declared `expected`. Used by the DAG type-checker to catch
    mismatches at plan time (not at GLSL compile time)."""
    if expected == actual:
        return True
    return actual in _TYPE_COMPATIBLE.get(expected, set())


def type_check_dag(dag: dict[str, Any], spec_params: dict[str, Any],
                   primitives: dict[str, Primitive]) -> list[str]:
    """Walk the DAG, tracking each local's type. Return a list of
    error strings (empty = clean). The compiler MUST call this
    before GLSL emission so type drift surfaces as a clean Python
    error rather than a cryptic GLSL crash at sync time."""
    errors: list[str] = []
    stages_block = dag.get("stages", {})

    for stage_name in ("vertex", "fragment"):
        ops = stages_block.get(stage_name, [])
        local_types: dict[str, str] = {}

        for idx, op in enumerate(ops):
            prim_id = op.get("op", "")
            if prim_id not in primitives:
                errors.append(f"[{stage_name}#{idx}] unknown primitive '{prim_id}'")
                continue
            prim = primitives[prim_id]

            # Validate stage compatibility
            if prim.stage != "both" and prim.stage != stage_name:
                errors.append(
                    f"[{stage_name}#{idx} {prim_id}] stage='{prim.stage}', "
                    f"cannot run in '{stage_name}'"
                )

            in_block = op.get("in", {})

            # Validate each declared input
            for in_name, in_def in prim.inputs.items():
                expected_type = in_def.get("type", "unknown")
                if in_name not in in_block:
                    if "default" not in in_def:
                        errors.append(
                            f"[{stage_name}#{idx} {prim_id}] missing required "
                            f"input '{in_name}' (type {expected_type})"
                        )
                    continue
                raw = in_block[in_name]
                actual_type: str
                if isinstance(raw, str) and raw.startswith("$"):
                    key = raw[1:]
                    if key not in spec_params:
                        errors.append(
                            f"[{stage_name}#{idx} {prim_id}] input '{in_name}': "
                            f"$key '{key}' not in spec"
                        )
                        continue
                    actual_type = _spec_type(spec_params[key])
                elif isinstance(raw, str) and raw.startswith("@"):
                    key = raw[1:]
                    if key not in local_types:
                        errors.append(
                            f"[{stage_name}#{idx} {prim_id}] input '{in_name}': "
                            f"@var '{key}' not declared by a prior op in '{stage_name}'"
                        )
                        continue
                    actual_type = local_types[key]
                elif isinstance(raw, str) and raw in WELL_KNOWN_TYPES:
                    # Engine builtin or Yume conventional varying
                    actual_type = WELL_KNOWN_TYPES[raw]
                else:
                    actual_type = _spec_type(raw)

                if not types_compatible(expected_type, actual_type):
                    errors.append(
                        f"[{stage_name}#{idx} {prim_id}] input '{in_name}': "
                        f"expected {expected_type}, got {actual_type} (from {raw!r})"
                    )

            # Register outputs in local_types
            out_block = op.get("out", "")
            if isinstance(out_block, str) and len(prim.outputs) == 1:
                out_name = next(iter(prim.outputs))
                out_type = prim.outputs[out_name].get("type", "unknown")
                if out_block not in BUILTINS:
                    local_types[out_block] = out_type
            elif isinstance(out_block, dict):
                for out_name, var_name in out_block.items():
                    if out_name not in prim.outputs:
                        errors.append(
                            f"[{stage_name}#{idx} {prim_id}] unknown output "
                            f"'{out_name}' in 'out' (declared: {sorted(prim.outputs)})"
                        )
                        continue
                    if var_name not in BUILTINS:
                        local_types[var_name] = prim.outputs[out_name].get("type", "unknown")

    return errors


def compile_dag(dag: dict[str, Any], spec_params: dict[str, Any],
                primitives: dict[str, Primitive]) -> CompiledShader:
    """Compile the DAG into a CompiledShader."""
    # Phase 0: type-check the DAG before emitting any GLSL.
    type_errors = type_check_dag(dag, spec_params, primitives)
    if type_errors:
        msg = "DAG type check failed (" + str(len(type_errors)) + " error(s)):\n  - " + "\n  - ".join(type_errors)
        raise CompilerError(msg)

    stages_block = dag.get("stages", {})

    vertex_state = CompiledStage()
    fragment_state = CompiledStage()

    # Walk each stage in declared order
    for stage_name, state in (("vertex", vertex_state),
                              ("fragment", fragment_state)):
        ops = stages_block.get(stage_name, [])
        body_lines: list[str] = []
        for op in ops:
            prim_id = op.get("op", "")
            if prim_id not in primitives:
                raise CompilerError(
                    f"[{stage_name}] unknown primitive: '{prim_id}'"
                )
            prim = primitives[prim_id]
            if prim.stage != "both" and prim.stage != stage_name:
                raise CompilerError(
                    f"[{stage_name}] primitive '{prim_id}' has stage "
                    f"'{prim.stage}', cannot run in '{stage_name}'"
                )
            glsl = emit_op_glsl(prim, op, spec_params, state, stage_name)
            if glsl.strip():
                body_lines.append(glsl)
        state.glsl = "\n".join(body_lines)

    # Merge uniforms across stages (fragment can also see vertex's varyings)
    all_uniforms = dict(vertex_state.declared_uniforms)
    all_uniforms.update(fragment_state.declared_uniforms)
    # Plus biome-derived uniforms (one albedo_<name> per biome)
    all_uniforms.update(collect_biome_albedo_uniforms(dag, spec_params))

    # Emit uniforms block
    uniform_lines: list[str] = []
    for name, u in sorted(all_uniforms.items()):
        utype = u.get("type", "float")
        hint = u.get("hint", "")
        default = u.get("default", None)
        line = f"uniform {utype} {name}"
        if hint:
            line += f" : {hint}"
        if default is not None:
            if isinstance(default, (int, float)):
                line += f" = {default}"
        line += ";"
        uniform_lines.append(line)
    uniforms_block = "\n".join(uniform_lines)

    # Plus per-biome material constants if biomes is in spec
    biomes = spec_params.get("biomes", [])
    if isinstance(biomes, list) and biomes:
        const_lines = ["", "// Per-biome reference colors (from spec)"]
        for b in biomes:
            if isinstance(b, dict) and "name" in b and "color" in b:
                c = b["color"]
                const_lines.append(
                    f"const vec3 BIOME_COLOR_{b['name'].upper()} = "
                    f"vec3({c[0]}, {c[1]}, {c[2]});"
                )
        uniforms_block += "\n" + "\n".join(const_lines)

    # Emit varyings block
    varyings_set = vertex_state.declared_varyings | fragment_state.declared_varyings
    varying_lines: list[str] = []
    for v in sorted(varyings_set):
        # Default type for known varyings
        vtype = "vec3" if v.startswith("v_world") else "vec3"
        varying_lines.append(f"varying {vtype} {v};")
    varyings_block = "\n".join(varying_lines)

    return CompiledShader(
        uniforms_block=uniforms_block,
        varyings_block=varyings_block,
        vertex_glsl=strip_builtin_type_prefix(vertex_state.glsl),
        fragment_glsl=strip_builtin_type_prefix(fragment_state.glsl),
    )
