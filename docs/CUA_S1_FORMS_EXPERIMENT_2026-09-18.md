# CUA S1 Forms: experimental native form filling

Status: implementation in progress; not qualified for production. This is a
separate draft feature branch based on Osaurus main `56b3eb5024747fe791955c7085217c7a6e89c738`.
Do not merge or release this experiment without a separate adoption decision.
Reasoning PR #2822 is already merged and is not part of this feature.

## Contract and scope

- [Model](https://huggingface.co/cua-ai/cua-s1-forms/tree/4171435d90e7fd78d6d3f0e78b1c4e4cca896706):
  706,048-parameter byte-level **option scorer**, not a chat/VL model. No text
  generation, tokenizer template, KV cache, reasoning parser, or speculative decode.
- [Reference implementation](https://github.com/trycua/cua/tree/83f142c4290a0f7d9ed545ae8532858c6e4f8145/libs/cua-s1):
  context encoder has two pre-norm Transformer layers; option encoder has one;
  width/rank 128, four heads, ReLU feed-forward, FP32 inference. Inputs truncate
  at 224 context / 96 option UTF-8 bytes, byte + 1 with zero padding. Preserve
  the separate padding masks and upstream attention-head math.
- It selects among explicit `fill Label: value` entities and `check/click/skip`.
  Document extraction is separate, conservative label/value extraction, not OCR
  or general document understanding. Imported candidates require human review.
- HF ships a pickle `.pt`; current upstream requires signed-content safetensors
  plus JSON. The app must never load pickle or execute checkpoint code. A
  developer-only, `weights_only=True` conversion must reproduce every tensor.
- Reuse `DocumentTextExtractionCache`, `NativeMacDriver`, `ComputerUseGate`,
  existing accessibility permission, paths, and Settings search. Do not create
  a second chat model loader, bypass autonomy policies, or auto-share profiles.

## Bounded first prototype

Computer Use → Forms (Experimental): off by default. Users create named local
profiles of label/value fields, optionally import a document and review the
extracted candidates, select a converted scorer folder, then choose one app
and exact window. A dry-run preview shows every prediction and value. Only
explicitly selected, reviewed fills/checks can execute. Buttons, submission,
password fields, and coordinate/keyboard fallbacks are not executable here.
This first draft is a direct user-operated form helper, not a new autonomous
agent tool or a hidden global source of personal data.

Profiles are stored locally in a private directory/file, not sent to chat or
telemetry. They are **not encrypted**; say so in the UI. Document source files
remain unchanged. Saving is explicit, errors visible, and runs use an immutable
profile snapshot. Disabling, editing, changing target/profile/model, navigating
away, or cancelling invalidates the preview and/or cancels the run.

The native scorer uses a scoped MLX CPU stream to avoid changing or unloading
the chat model. Batch options may be encoded once because all element rows use
the same entity list; parity tests must demonstrate this mathematical reuse.
Validate bounded config, exact keys/shapes/dtypes, safetensors payload bounds,
metadata and the upstream content signature before execution.

Apply rechecks permission and current policy, exact app identity and window,
then re-observes before **each** mutation. Match a unique stable element identity,
require its pre-apply value to match the reviewed value, perform one AX action,
and re-observe its actual effect. Stop on ambiguity, stale target, unsupported
field, partial tree, rejected action, changed value, cancellation, or unverified
effect. Report completed count when a later action fails; no blanket success.

## Acceptance / remaining work

- [x] Check local checkpoint against original `.pt` using safe weights-only read;
      retain SHA256, config, tensor count, exact parity and upstream provenance.
- [x] Native scorer, strict loading and FP32 probability parity with pinned
      PyTorch reference, including empty/padded/Unicode/truncated inputs.
- [ ] Context CRUD, PDF/text extraction review, duplicate/conflicting and
      over-budget input handling; save/relaunch; no PII logs or implicit sharing.
- [x] Settings tab, search/anchor/self-find tests and guide/localization entries
      implemented; actual app controls are a separate unchecked row below.
- [x] Planner/executor tests: preview only, no submit, exact window, allowlist,
      read-only policy, stale/ambiguous targets, permission, cancellation,
      re-observation, confirmed effects and partial-failure reporting.
- [ ] Fresh isolated dev app: real controls, PDF import, save/relaunch, actual
      synthetic local form preview/fill, follow-up no-op, no submission.
- [ ] Record scorer latency and decisions/second (tokens/second is inapplicable),
      app SHA/engine pin/bundle hash, test denominators and all failed rows.
- [ ] Open draft PR with proof and explicit experimental/unsupported boundaries.

## Separate queued work

Bonsai fused RHT / Hadamard prefill and decode investigation is running as a
separate source/evidence audit. Preserve existing load/prefill/FP16-KV fixes;
do not bundle it in this form feature. The requested `.64` target refers to the
Python/Electron release lane, not Osaurus's `0.25.x` version. No release action
is authorized by this planning note.

## Evidence

Local artifact discovered (no download): `~/models/cua-ai/cua-s1-forms`.
Original `.pt` SHA256:
`f5077f0c9baf6b5fc10f21512e1aa15207a395598416a6ffdd95f0d3dd5ab8df`.
Existing safetensors SHA256:
`53b6e6c296302db0624cc0180bae7a3ade9ecb6cd6ba1e30d4e3c782617349f9`.
The developer converter reproduced all 45 tensors / 706,048 FP32 parameters
bit-identically. Run the opt-in native parity tests by setting both
`CUA_FORMS_REFERENCE_DIR` and `TEST_RUNNER_CUA_FORMS_REFERENCE_DIR` to the
converter output; without the artifacts these two tests explicitly skip.

Initial focused build failed because the new mock `CUSnapshot` omitted
`image: nil`; no tests ran. After correcting the fixture, the second run
passed **31 Swift Testing cases in 5 suites plus 8 XCTest effect-classification
cases**, with zero skipped native parity rows. The real CPU scorer matched
**58/58 argmax decisions, 599 probabilities, 45 schema strings** against pinned
PyTorch reference; maximum absolute probability difference **1.1920929e-6**
(required <=1e-4). The three batches took 2.746722 s / 52 decisions,
0.059599 s / 3, and 0.092865 s / 3 under the debug test host. These are scorer
latencies, not chat token/s or an optimized app performance claim.

Private evidence: `vmlx-private-evidence/cua-s1-forms-2026-09-18/`
contains `reference/goldens.json`, `source-second.patch`, `tests-second.log`,
and `Tests-second.xcresult`. The initial generic filters for two existing
policy/driver test files did not name their actual XCTest classes, so those
classes did **not** run in the 39-case result; a corrected-filter rerun is next.
Native dev-app import, persistence and actual form mutation remain unproven.

Follow-up `Tests-third.xcresult` on implementation commit `e1caaf584` passed
**31 Swift Testing + 29 XCTest = 60 cases**, including the corrected
`ComputerUseGateTests`, `AutonomyPolicyTests` and four driver-contract classes.
Native parity remained 58/58 with max error 1.1920929e-6. Draft PR #2823 is open.
Its first CI run stopped at localization lint, before compilation, on one
unwrapped `Current:` label. That label is now localized; no gate was weakened.
The first optimized build was explicitly interrupted to bind the following
build and live proof to this correction rather than the stale UI source.
