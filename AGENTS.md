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
- Chat/API defaults must come from the model bundle/generation config unless a
  user explicitly overrides them.
- Runtime proof must separate proven, partial, failed, and unproven rows.
- RAM, token/s, visible coherency, reasoning/tool behavior, and cache topology
  evidence are required before promotion.
