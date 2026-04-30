export const entry14 = {
  id: "14",
  date: "2026-04-30",
  type: "decision",
  title: "Asset gen pipeline — concrete four-step flow + backend plugins",
  summary:
    "User pinned down the AI-gen path: <em>\"generate prompt → call xxx api → create the " +
    "2d/3d.\"</em> Designed the full offline pipeline: prompt builder → hash check → backend " +
    "dispatcher → file saver. All config-driven via <code>asset_gen.json</code>. Engine never " +
    "sees prompts — it reads file paths. Generation is offline tooling, not runtime.",
  highlights: [
    "<strong>Per-entity prompts:</strong> <code>entity.visual.sprite_2d_prompt</code>, <code>model_3d_prompt</code>, <code>audio.sfx_loop_prompt</code> — same shape across modalities",
    "<strong>Project style templates:</strong> <code>asset_gen.json</code> holds prefix/suffix/negative + per-modality settings. Final prompt = style + entity prompt",
    "<strong>Backend registry is JSON:</strong> each backend declares <code>type</code>, <code>endpoint</code>, <code>auth_env</code>, <code>params</code>, optional <code>polling: true</code>. FLUX, DALL-E, Meshy, ElevenLabs, etc. — all interchangeable",
    "<strong>Three adapter shapes</strong> cover most APIs: <code>SyncImageAdapter</code>, <code>AsyncJobAdapter</code>, <code>StreamingAudioAdapter</code>. ~50 LOC per shape; new backend usually = config entry only",
    "<strong>Idempotency via manifest:</strong> hash of (prompt, backend, params) → stable filename. Re-run is free if nothing changed. Manifest tracks cost, time, full prompt for audit",
    "<strong>CLI:</strong> <code>yume assets generate</code> / <code>cost</code> / <code>regen --style-changed</code> / <code>clean</code>",
    "<strong>Honest gaps:</strong> 3D post-processing (UV cleanup, LOD) deferred. Format conversion + image quantization in MVP via Pillow/trimesh. Cost guardrails (<code>max_cost_usd</code>) optional",
    "<strong>Engine ignorance preserved:</strong> Yume runtime sees file paths only. Prompts, backends, costs — all offline tooling. Honors invariant #8.",
  ],
  files: [
    "task_plan.md (2.5k expanded with k.1/k.2/k.3 subitems)",
    "docs/32_architecture_diagrams.md (asset gen flow diagram added)",
  ],
  followups: [
    "Pick first backend trio (likely FLUX + Meshy + ElevenLabs)",
    "Yume Python CLI scaffolding for the asset commands",
  ],
};
