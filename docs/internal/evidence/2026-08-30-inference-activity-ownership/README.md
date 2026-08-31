# Exact inference ownership and cancellation

Status: **PASS — source, focused tests, Release build, UI stop, and client-disconnect A/B pass.**

## User-visible defect

An external client could disconnect while local generation continued, and the
operator had no request-level view explaining whether the engine was loading,
queued, processing a prompt, generating, saving cache, or unloading. The old
HTTP disconnect hooks also called `cancelGeneration(name:)`, so one client
could cancel unrelated concurrent work using the same resident model.

## Causal source trace

- `HTTPHandler.runRequestTask` already owns an exact task per connection and
  cancels that task from `channelInactive`, input-close, idle-close, and
  `closeFuture`.
- Several streaming disconnect hooks bypassed that identity and additionally
  cancelled by model name.
- `ModelRuntime` already has one tracked producer wrapper per generation, but
  its identity, phase, producer source, and cancellation closure were not
  exposed to the UI.

## Fix contract

- One UUID per local model step.
- Exact producer attribution: Chat UI, HTTP API, Agent, Channel, Schedule,
  Watcher, Self-scheduled, Plugin, or P2P.
- Live phases: queued, loading, prompt processing, generation, cache save, and
  model unload.
- The Live Activity settings card lists active work and cancels only the
  selected request. Empty state is explicit.
- `/admin/cache-stats` exposes the same request IDs, sources, phases, start
  times, and cancellation state for CLI diagnostics.
- Agent display attribution is separate from residency ownership: delegated
  helpers remain chat-owned for handoff/reload correctness.
- HTTP disconnect relies on its exact route task and stream termination; no
  disconnect hook cancels by model name.

## Current automated evidence

- `InferenceActivityRegistryTests`: 3/3 pass.
- `RuntimePolicySourceTests`: 110/110 pass on the post-MTP-merge head.
- `RuntimePolicySourceTests.httpChannelCloseCancelsPerRequestStreamingTasks`:
  pass and pins the absence of model-name cancellation in `HTTPHandler`.
- Localization catalog/key/literal lint: pass.

## Release-app live gate

- Integrated code head: `a2e9454bb` (the evidence-only commit follows this
  code head).
- Release binary SHA-256:
  `d201c7af470902e42731750253d0b79e12b22d4630dc20d9bb0ae64020f4395a`.
- Isolated app PID: `18364`; server PID was the same process; model:
  `lfm2.5-2.6b-jang_6m`.
- Release build: `xcodebuild` completed with `** BUILD SUCCEEDED **`.
- Final-head focused tests: 3/3 registry and 110/110 runtime source-policy
  tests pass.

### Exact UI stop

Two simultaneous HTTP streams appeared as distinct owned activities:

- `c6ad3ed2-4260-47c8-be3a-29990d4a9733`: Generating, Stop enabled.
- `ee646704-6b7a-4137-aa36-041a5c50229b`: Processing prompt, Stop disabled
  until cancellable.

The Live Activity Stop button cancelled only `c6ad3ed2`. Its sibling remained
active and emitted a coherent consecutive sequence through `1552` before the
configured length stop. The registry then returned `inference_activity: []`,
BatchEngine returned active `0` / queued `0`, and the UI returned to explicit
`Idle — no active or queued inference`.

### Real client disconnect

`run_disconnect_ab.py` opens two same-model HTTP streams, closes only A after
250 SSE data records, preserves both raw streams, and polls the exact activity
registry until drain. The recorded result in `disconnect-ab-summary.json` is:

- A: HTTP 200, TTFT `0.1097 s`, deliberate client disconnect after `1.5243 s`,
  and no terminal model finish.
- B: HTTP 200, coherent consecutive output, normal `length` finish, `1200`
  completion tokens at `165.2428 tok/s`, TTFT `1.4199 s`. Its visible output
  is the strict sequence `1...332` without a gap or repetition.
- Registry: two unique HTTP API activity UUIDs before disconnect, only the
  survivor UUID afterward, then active count `0` and an empty registry.

After the post-merge rows, cache telemetry was active `0`, queued `0`, disk L2
hits/misses/stores `4/4/4`, and SSM companion hits/misses `4/0`. Measured idle
`phys_footprint` was `1346 MB`; process peak was `1526 MB`. UI Quit ended the
exact app with `last-exit.json` reason `quit-complete`; no crash occurred.

Screenshots:

- `live-two-owned-requests.jpeg`: distinct model/source/phase/request IDs and
  request-scoped Stop controls.
- `live-idle-after-disconnect.jpeg`: active `0`, queued `0`, and explicit Idle.

Raw evidence:

- `disconnect_a.sse`
- `survivor_b.sse`
- `disconnect-ab-summary.json`
