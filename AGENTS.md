# Codex Configuration - osaurus-staging

See `~/AGENTS.md` for the global Codex environment, wiki protocol, hard rules,
machine context, and useful commands.

## Keychain-Free Validation Gate

For Osaurus validation tied to vMLX, model runtime, parser/template, cache,
reasoning/tool, cancellation, or server-panel work:

- Do not run validation, build, signing, notarization, certificate, or
  `security` paths that trigger macOS Keychain or
  "wants to use your confidential information" prompts.
- Do not use app-launch or proof commands that can read the user's login
  Keychain unless Eric explicitly asks for that exact lane.
- Live app probes must use the keychain-disabled test mode:
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` and an isolated
  `OSAURUS_TEST_ROOT=/tmp/...` path.
- In keychain-disabled test mode, Osaurus Keychain wrappers must not perform
  `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, or `SecItemDelete`.
  Reads must return nil or an in-memory test key, writes must fail/no-op, and
  deletes must no-op without touching the login Keychain.
- Prefer source-only tests/audits and runtime probes that do not require
  signing or user authentication. If a prompt appears, stop the lane, document
  the artifact as blocked, and switch to a keychain-free proof path.
- Do not treat an unsigned Xcode build flag as sufficient proof of
  keychain-safety. If Xcode, codesign, CodeSigningHelper, or Keychain UI
  appears in the lane, stop.
- Do not run Osaurus SwiftPM/Xcode validation lanes (`swift test`,
  `swift build`, `xcrun swift`, `xcodebuild`, `swift-driver`,
  `swift-frontend`, package plugin builds, or Cmlx compile jobs) unless Eric
  explicitly approves that exact lane. These paths can still invoke Apple
  signing, package, or keychain-adjacent services even when the test itself
  looks source-only.
- Shell-only guards, `rg` audits, direct script checks, and direct execution of
  an already-built app through `scripts/live-proof/launch-keychain-free-osaurus.sh`
  are the default validation routes while this gate is active.

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
