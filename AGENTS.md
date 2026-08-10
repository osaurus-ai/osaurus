# Codex Configuration - osaurus-staging

See `~/AGENTS.md` for the global Codex environment, wiki protocol, hard rules,
machine context, and useful commands.

## Build & Test

Running tests and builds is encouraged — they're how we keep quality high. The
canonical lanes live in `Makefile`:

- `make test` — `swift test --package-path Packages/OsaurusCore` (fast unit
  loop).
- `make ci-test` — mirrors the CI `test-core` xcodebuild job (`xcbeautify`
  output, xcresult bundle at `build/Tests.xcresult`).
- `make cli` / `make app` — build the CLI and the embedded app via
  `xcodebuild` against `osaurus.xcworkspace`.
- `make evals` / `make evals-all` — run OsaurusEvals suites under
  `Packages/OsaurusEvals/Suites/*`.
- Live-app smoke: `scripts/live-proof/launch-keychain-free-osaurus.sh`.

### Keychain tip (optional)

Some tests touch Osaurus Keychain wrappers. If a test doesn't need real
Keychain access, prefer running it in keychain-disabled mode to avoid
unrelated "wants to use your confidential information" prompts:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
OSU_MODELS_DIR=/tmp/osaurus-test-models \
make test
```

In that mode, Keychain wrappers should return nil / no-op on reads, writes,
and deletes rather than calling `SecItemCopyMatching` / `SecItemAdd` /
`SecItemUpdate` / `SecItemDelete` against the login Keychain.

`OSU_MODELS_DIR` (pointed at an empty dir) matters on machines with real
models in `~/MLXModels`: dispatch-style tests start real `ChatSession.send`
turns, and without the override they resolve the user's installed models and
try to load them inside the SwiftPM harness — which has no Metal kernels and
dies with `MLX/MLXArray.swift precondition failed`. With the override those
sends fail fast with `modelUnavailable`, matching CI behavior. Keychain-gated
suites (e.g. `PluginAgentScopingTests`) still fail by design under
`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`; run those without the flag when you
need real Keychain proof.

## Osaurus Release Proof and PR Reporting

For every change that can affect a runtime, parser, tool call, agent loop,
subagent/delegation path, cache, model setting, or user-facing execution
lifecycle, source inspection and focused unit tests are necessary but never
sufficient:

- Build a fresh isolated Release development app and exercise the real Chat and
  Settings UI. Click every control touched by the change, save it, navigate
  away and back, relaunch when persistence is part of the contract, and prove
  the effective request/runtime state changed. Inspect the complete turn until
  reasoning closes, every tool/subagent card settles, Stop disappears, input
  unlocks, and a follow-up turn completes.
- During a user-authorized live UI proof, when Osaurus shows its first-use
  permission popup for a newly exercised tool kind, choose **Always Allow**
  for that tool in the isolated test agent. Record the granted tool kind and
  verify the choice survives the intended follow-up/relaunch. This does not
  authorize unrelated macOS, browser, account, or external-service grants.
- For batching/delegation specifically, live-test the allowed agent/local/cloud
  target pool, add/remove/save/relaunch, target notes, permission modes, worker
  tools, child budgets, per-agent maximum fan-out, Server Continuous Batching,
  Concurrent Sessions, RAM-safety clamp/refusal, same-model batching,
  different-model handoff/restore, mixed local/remote fan-out, ordering,
  cancellation at each lifecycle phase, cache reuse, and parent continuation.
  A visible control or source-wired value is not proof that it is effective.
- Run the relevant focused regression suites and the applicable full
  OsaurusEvals lanes, including AgentLoop and AgentLoopFrontier when agent-loop
  behavior can change. Add efficient deterministic eval cases for new
  delegation, batching, parser, completion, cancellation, or cache contracts.
  If an external judge key is unavailable, preserve the raw artifacts and
  grade the named rows manually rather than silently omitting them.
- Every GitHub PR proof/status comment must include the exact tested source SHA,
  app/vMLX pin, model bundle and generation defaults, suite/eval names, raw
  scores and denominators, failed-case attribution, and paths or hashes for
  local evidence. Never post images to the repository. Never report only the
  favorable model rows or summarize a non-perfect score as passing.
- Re-run the affected full matrix after rebase, merge-conflict resolution, or
  any source/config change. If any required source trace, automated score, or
  live UI row is missing, report `PARTIAL` or `BLOCKED` and do not describe the
  PR as fixed, proven, release-ready, or regression-free.

## Model Runtime Non-Negotiables

- Never add forced thinking tags, parser repair, hidden sampler defaults,
  repetition-penalty rescues, close-token bias, or prompt/template coercion to
  make a model appear coherent.
- Never add fake guards, placeholder gates, hardcoded model allowlists,
  synthetic output filters, or "same behavior" enforcement to make a runtime
  row look safe. If JANG, JANGTQ, MXFP, VL/audio/video, hybrid cache, SWA,
  speed, coherency, leaking tool parser output, reasoning boundaries, or RAM
  policy is wrong, trace the root cause and fix the real function/path. If the
  root cause is not fixed yet, document the row as `PARTIAL` or `BLOCKED` with
  exact evidence instead of forcing behavior in prompts, parsers, samplers, or
  UI state.
- Chat/API defaults must come from the active model bundle's
  `generation_config.json` or equivalent runtime config unless a user
  explicitly overrides them. Native-trained defaults such as top-k matter for
  quality and speed; do not replace them with synthetic Osaurus defaults.
- Reasoning, tool, and chat-template behavior must be auto-detected from the
  bundle/tokenizer/template/runtime config. Do not fake thinking envelopes,
  strip visible output to hide parser bugs, or coerce one model family into
  another family's template.
- Runtime proof must separate proven, partial, failed, and unproven rows. A
  load-only result, single prompt, or source-only assertion is not enough to
  call a model family working.
- RAM proof means Activity Monitor physical footprint stays within the intended
  low-RAM gate. A row that reaches full model size in physical footprint is a
  failure even if generation is coherent.
- Every generation row must record token/s. Missing token/s is a blocked or
  failed row, not production proof.
- Multi-turn coherency is required: visible answer, reasoning channel behavior,
  no looping, no hidden reasoning-only output, no length-cap fake pass, and no
  raw parser marker leak.
- Reasoning fixes must preserve the model's real contract. Do not inject fake
  closers/openers, hide leaked reasoning markers by stripping visible text, or
  treat a parser cleanup as correctness unless the live output, structured
  reasoning field, and user-visible answer all prove the boundary is correct.
- Cache proof must match the model architecture:
  - Full-attention models need real KV, prefix/paged, L2 disk, and TurboQuant
    KV proof when enabled.
  - Qwen-style hybrid SSM needs KV plus SSM companion rederive/hit proof; a KV
    hit alone is not enough.
  - ZAYA/CCA and HY3-style models need companion cache and pooling proof.
  - DeepSeek-V4 CSA/HSA/SWA hybrid pool needs prefix/L2 plus pool restore/hit
    proof and must not use TurboQuant KV as a substitute.
- VL/video rows require real media payloads, media cache salts, and cache-hit
  validation; text-path evidence does not prove media-path correctness.
- Big-model load cancellation must be live-proven before promotion: if the user
  stops generation, closes chat, or exits during first load, startup must
  cancel and cleanup must prevent zombie loads and OOM growth.
- Qwen/JANG/JANGTQ RAM regressions require end-to-end Osaurus proof with
  physical footprint, stop status, cache telemetry, token/s, and visible
  multi-turn output before being called fixed.
- Memory limits must apply only through documented user/runtime settings and
  the resolved runtime plan. Do not add hidden RAM percentage blocks or fake
  load refusals. If a selected setting or true runtime limit prevents a load or
  context request, fail before unsafe MLX/Metal allocation with a clear typed
  API/app error that tells the user what setting or resource limit applied.
- Server settings are part of runtime proof, not a source-only contract. For
  every claimed model/runtime row, verify the relevant server setting wiring
  through live Osaurus panel/API state: generation defaults and overrides,
  reasoning mode, tool mode, memory enablement, prefix cache, paged KV, L2 disk
  cache, TurboQuant KV when applicable, media/cache settings, concurrency, and
  memory-safety settings. Toggle the setting, speak to the model, and confirm
  the runtime behavior, telemetry, and user-visible state changed as intended.
  If settings conflict or do not compose for a model family, question the
  compatibility contract, fix the real wiring, or document the row as
  `PARTIAL`/`BLOCKED` with the exact incompatible setting combination.
- Treat every implementation change as a cross-function and cross-settings
  compatibility change until proven otherwise. Trace every shared value from
  persisted global and per-agent configuration through UI editing, save and
  relaunch, request/schema composition, runtime admission, execution,
  telemetry, cancellation, and finalization. Test precedence and composition
  with adjacent controls (including model defaults, explicit request
  overrides, reasoning, tools, cache, batching, concurrency, and RAM safety)
  and remove duplicate, stale, or unwired consumers instead of adding a second
  source of truth. A direct unit test of the changed function is not sufficient
  when another consumer or setting can alter the effective behavior.
- For every touched or behaviorally related user setting, use the real built
  app to change or toggle it, save it, exercise the affected workflow, and
  visually inspect the complete result. Relaunch when persistence or
  next-load-only behavior is part of the contract. Reading a stored value,
  source default, or test fixture is never a substitute for this live proof.
- Tool, memory, and cache setting proof must exercise the live user flow after
  the setting changes. Required tool proof includes exact tool args, tool-result
  history grounding, a second tool call after history, and no parser/protocol
  leakage. Memory proof, when the shipped flow exposes memory context or memory
  toggles, must include multi-turn chat that depends on the memory state. Cache
  proof must include baseline, changed setting, reload when next-load-only,
  live chat, `/admin/cache-stats`, and typed incompatibility rather than silent
  ignore for unsupported combinations.
- For the active Gemma 4 QAT checkpoint, every OsaurusAI MXFP4 and JANG_4M
  bundle must prove real Osaurus tool use before harness or benchmark results
  are treated as meaningful. A row needs load, at least one executed tool with
  exact name and parseable JSON arguments, tool-result continuation, clean
  visible text, no protocol/reasoning/tool marker leakage, cache telemetry with
  paged KV off and disk/L2 behavior recorded, and a scored AgentLoop harness
  artifact with every failed case attributed. Decent non-perfect scores are
  acceptable for teammate testing only when the failures are documented; source
  or BF16 Gemma folders do not count for this QAT checkpoint.
- Do not spawn recursive local "agent" workers, Python subagents, or delegated
  helper agents for Gemma/Osaurus release work unless the user explicitly asks.
  Do not use Python or shell wrappers as an orchestration layer to farm work out
  to Codex, Claude, local LLMs, or other helper agents. Work directly in the
  current session, keep status artifacts current, and use normal shell, test,
  build, and proof commands for evidence. Python is allowed for deterministic
  parsing or proof harnesses, but never to recursively run another agent.
