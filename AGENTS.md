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
make test
```

In that mode, Keychain wrappers should return nil / no-op on reads, writes,
and deletes rather than calling `SecItemCopyMatching` / `SecItemAdd` /
`SecItemUpdate` / `SecItemDelete` against the login Keychain.

## Model Runtime Non-Negotiables

- Never add forced thinking tags, parser repair, hidden sampler defaults,
  repetition-penalty rescues, close-token bias, or prompt/template coercion to
  make a model appear coherent.
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
- Do not spawn recursive local "agent" workers, Python subagents, or delegated
  helper agents for Gemma/Osaurus release work unless the user explicitly asks.
  Do not use Python or shell wrappers as an orchestration layer to farm work out
  to Codex, Claude, local LLMs, or other helper agents. Work directly in the
  current session, keep status artifacts current, and use normal shell, test,
  build, and proof commands for evidence. Python is allowed for deterministic
  parsing or proof harnesses, but never to recursively run another agent.
