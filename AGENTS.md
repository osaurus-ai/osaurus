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
