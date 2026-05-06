# ADR 0020 — External agent IPC (LLM / RL / cross-process policies)

_Date: 2026-05-06_
_Status: **proposed (deferred — land when first dependent game queues)**_

## Context

ADR 0018 ships in-process actor policies (scripted JSON + GDScript
resource). External-process policies were originally part of 0018
but were SPLIT OUT per tech-director review because they introduce
a fundamentally different scope:

- **In-process** (0018): policy runs in the engine; no IPC; no
  external dependencies. Latency = nanoseconds.
- **External** (this ADR): policy runs in a SEPARATE process or via
  network; IPC overhead; new dependencies. Latency = 100ms-2s.

External policies are the foundation for:

- **LLM-driven NPCs** — Smallville / Generative Agents. Each NPC
  has a language-model brain making decisions every few seconds.
- **RL agents** — train an agent against a Yume sandbox. Agent's
  policy network runs in PyTorch; engine sends observations,
  receives actions.
- **Cross-process tooling** — visualization, replay analysis,
  external supervisors

These are powerful capabilities but require:
- Subprocess lifecycle management (start, error, kill, cleanup)
- Cross-platform support (Windows/Mac/Linux subprocess differs)
- Optional: ZMQ or similar IPC library
- Async tick handling (engine doesn't wait for slow policies)
- Security model (external policy is host-process trusted)

These are real engineering surfaces. The user community is divided
on which they need (hobbyists may want LLM; researchers may want RL).
Don't speculatively commit to all transports up front.

## Decision

Defer this ADR until the FIRST GAME requires external policies.
When that happens:

1. The game's GDD specifies what kind of external policy (LLM via
   subprocess? RL via ZMQ? both?)
2. We pick the MINIMAL transport that game needs
3. We implement only that transport in this ADR
4. Future ADRs extend with additional transports as needed

This avoids: subprocess + ZMQ + custom-protocol all at once. We
add capability as it's used.

### Anticipated transports (sketches only — not implemented)

When this ADR is activated, transport choice depends on use case:

**Stdio subprocess** — simplest; suitable for LLM agents
- Engine forks one process per actor (or pools them)
- JSON observation written to stdin; JSON action read from stdout
- Process lifecycle: start at world load; kill at world end
- Tick rate: low (every few seconds — LLM thinking is slow)
- Sample policy command: `python3 policies/llm_brain.py`

**ZMQ socket** — suitable for RL agents that need higher tick rate
- Engine acts as ZMQ client; agent process is server
- One actor's observations multiplexed over a single connection (REQ/REP)
- Better latency than stdio (~ms instead of tens of ms)
- New dependency: ZMQ Godot binding

**HTTP / WebSocket** — suitable for cloud-hosted policies
- Engine POSTs observation to URL; receives action JSON
- Adds network configuration surface
- Useful for "policy as a service" — external SaaS LLMs

**Unix domain socket** — alternative to TCP/ZMQ on Linux/Mac
- Lower overhead than TCP loopback
- Not portable to Windows without WSL

The Yume team will pick ONE of these when the first dependent game
queues. Others added incrementally.

### Yume's responsibility — explicit boundary

When this ADR is activated:

**Yume engine MUST**:
- Define the wire-format protocol (observation/action JSON shape)
- Manage subprocess lifecycle (start/error/kill) for the chosen
  transport
- Handle async return correctly (last-action fallback)
- Surface policy errors via Tier 2.6a structured-error system

**Yume engine SHOULD NOT**:
- Ship LLM clients (Anthropic SDK, OpenAI client, etc.)
- Ship RL environment wrappers (Gymnasium, etc.)
- Ship reference policies (only protocol + transport)
- Bundle Python interpreters or runtime environments
- Provide its own networking infrastructure beyond the chosen
  transport

Sample external-policy implementations live in the user's own
ecosystem (e.g., `examples/policies/llm_brain.py` showing a Claude
API client wrapping the protocol). Engine ships only the
transport.

## Backward compat

This ADR doesn't constrain anything until activated. ADR 0018's
in-process policies fully work without this ADR.

## Consequences (when activated)

**Enables:**
- LLM-driven NPCs (Smallville-style)
- RL training pipelines
- Cross-process tooling
- "Policy as service" cloud setups

**Constrains:**
- New external dependency surface (subprocess, ZMQ, etc.)
- Build complexity (multi-platform subprocess; optional native deps)
- Latency budgeting (engine must handle async)
- Security: external policies trusted at host-process level

## Alternatives considered

### A. Don't support external policies at all

Locks Yume out of LLM-agent + RL training use cases. These ARE
high-value capabilities. Rejecting outright sacrifices a lot.

### B. Bundle full external infrastructure (LLM clients, etc.)

Massive scope creep. Engine becomes opinionated about which AI
backends to support. Each new backend means more dep maintenance.
Reject.

### C. Ship all transports at once

The original 0018 draft. Over-commits to subprocess + ZMQ + protocol
without a real game driving the choices. Rejected per TD review;
this ADR is the result.

## When to activate this ADR

Activation criteria:

1. A new game's GDD specifies external policies as a requirement
2. Tech-director re-reviews this ADR with the game's specific transport
   need
3. Implementation is scoped to ONLY that transport
4. ADR 0018's in-process protocol is reused; only transport differs

Until activation: this ADR remains in proposed state. ADRs 0014-0017
+ 0019 + 0018 (in-process) can land independently.

## References

- ADR 0018 (in-process actor policies) — companion; observation/action
  protocol defined there is reused
- ADR 0016 (multi-actor framework) — prerequisite
- Tier 3 (Actors) roadmap — this ADR is the second half
- Smallville / Generative Agents paper — reference architecture

## Revisions per tech-director review

This ADR was created by SPLITTING the original 0018 draft. The TD
review verdict was: external IPC is a major dependency surface
deserving its own gate; defer until a real game needs it. This
ADR captures the design space without committing to implementation.

**Final verdict**: **deferred** until game-driven activation.

When activated, tech-director re-reviews with the specific transport
in mind. New conditions likely apply per transport (subprocess
lifecycle for stdio; dependency declaration for ZMQ; security
review for HTTP).
