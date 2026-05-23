# Shader primitive schema (ADR 0058 Phase B)

Each primitive lives in `data/lib/shaders/primitives/<id>.json` and
declares one composable shader operation. The DAG compiler in
`tools/yume_shadergen/compiler.py` walks a JSON DAG of primitives,
validates types, and emits a concrete `.gdshader` per game.

## Fields

```jsonc
{
  "id": "primitive_id_kebab_case",
  "description": "one-line explanation of what this op does",
  "stage": "vertex | fragment | both",

  "inputs": {
    "param_name": {"type": "float | vec2 | vec3 | vec4 | sampler2D | int | bool | list<biome>",
                   "doc": "what the input is for",
                   "default": <optional default if absent in DAG>}
  },
  "outputs": {
    "output_name": {"type": "float | vec3 | ...",
                    "doc": "what this output represents"}
  },

  "uniforms": [
    {"name": "uniform_id", "type": "sampler2D | float | ...",
     "hint": "optional hint_range etc.", "default": <optional>}
  ],
  "varyings": ["v_world_pos"],
  "constants": [],

  "glsl_vertex": "...optional GLSL fragment to emit in vertex() ...",
  "glsl_fragment": "...optional GLSL fragment to emit in fragment() ..."
}
```

## DAG (in scene.json under `ground.mesh.shader_dag`)

```jsonc
{
  "stages": {
    "vertex":   [<op>, <op>, ...],
    "fragment": [<op>, <op>, ...]
  }
}
```

Each `<op>` node:

```jsonc
{
  "op": "primitive_id",
  "in": {
    "input_name": "$spec_value"      // dereferences scene.json.ground.mesh.<spec_value>
                | "@local_var_name"  // a prior op's output in the same stage
                | <literal>          // plain string/number/list/bool/dict
  },
  "out": "local_var_name"            // or builtin like NORMAL, ALBEDO, VERTEX, ROUGHNESS, METALLIC
                | {"output_a": "var_a", "output_b": "var_b"}  // multi-output
}
```

## Type system

Types are strings checked at compile time:
- `float`, `int`, `bool` — scalars
- `vec2`, `vec3`, `vec4` — vectors (RGB / world position / UV)
- `sampler2D` — texture
- `list<T>` — array of T (`list<float>`, `list<biome>`)
- `biome` — a structured record `{name: string, color: vec3,
  roughness: float, metallic: float, albedo: sampler2D, animate?: bool}`

The compiler validates that each `@local_var_name` reference matches
its source's declared output type, and each `$spec_value` matches
the input's declared type.

## Templating

Primitive GLSL fragments are Jinja2 templates. Available variables:
- `inputs.<name>` — the resolved input value (uniform name, local var,
  or literal). For list inputs, also `inputs.<name>_list` (the raw list).
- `outputs.<name>` — the output's local var name (or builtin)
- `uniforms.<name>` — uniforms declared by this primitive
- Convenience loops: `{% for b in inputs.biomes %}...{% endfor %}`

## What primitives DON'T do

- They don't synthesize GLSL from algebraic specs. Each primitive's
  GLSL is hand-tuned for performance.
- They don't auto-vectorize or auto-optimize. Composition only.
- They don't manage uniform binding at runtime — `tools/yume_shadergen`
  emits matching `shader_params` writes alongside the .gdshader so the
  engine sets them.

## Composition rules

- One stage at a time. The `vertex` ops can't reference `fragment`
  outputs (except via varyings declared by a primitive).
- `@local_var_name` references must point to a prior op IN THE SAME
  STAGE.
- Varyings declared by a vertex op are available to fragment ops.
- Builtin outputs (NORMAL, ALBEDO, VERTEX, ROUGHNESS, METALLIC) can
  only be written once per stage. The last write wins; the compiler
  warns on multiple writes.
