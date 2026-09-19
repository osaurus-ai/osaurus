# CUA S1 Forms: experimental native form filling

Status: **experimental / partial; leave PR #2823 open for team review**.
The user explicitly prohibited merging and auto-merge on 18 September.
This is a
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

## Manual preview and explicit agent integration

Computer Use → Forms (Experimental): off by default. Users create named local
profiles of label/value fields, optionally import a document and review the
extracted candidates, select a converted scorer folder, then choose one app
and exact window. A dry-run preview shows every prediction and value. Only
explicitly selected, reviewed fills/checks can execute. Buttons, submission,
password fields, and coordinate/keyboard fallbacks are not executable here.
The first draft was manual-only. The agent integration adds an explicit
per-agent profile grant; saving a profile alone never grants agent access.
The selected profile in the manual preview is independent of those grants.

Profiles are stored locally in a private directory/file and not sent to
telemetry. They are **not encrypted**; say so in the UI. Document source files
remain unchanged. Saving is explicit, errors visible, and runs use an immutable
profile snapshot. Disabling, editing, changing target/profile/model, navigating
away, or cancelling invalidates the preview and/or cancels the run.

An agent grant explicitly permits that agent to use the profile in browser
and desktop form tasks. Filled values can enter websites, chat history and
local/cloud models involved in delegation; Settings explains this before
granting. No full profile is injected into the planner prompt. A spawned local
agent resolves its own grant from its actual chat-session agent identity,
never its parent's or sibling's profile. Remote agents do not receive local
profile files. Mid-run revocation, disabling, edits or scorer-path changes stop
further fills instead of silently switching profiles.

The general LLM still plans the browser/desktop task. With a grant, the browser
child exposes `browser_fill_form`; the desktop `agent_action` schema exposes
`fill_form`. These call the real native CPU scorer over current DOM/AX fields,
not an LLM approximation. Each text edit is separately gated, revalidated
after approval and read back. They do not submit, select checkboxes, fill
passwords or dropdowns. The existing independently gated browser/desktop
actions remain responsible for any subsequent user-authorized action.

The run feed names `CUA S1 Forms · local CPU` only after actual scoring. Results
include a separate `form_scorer` receipt with scored/applied counts and scoring
seconds, while `model` remains the true LLM planner. Enabling the feature alone
must not claim S1 was used. This is not a claim that the entire browsing agent
uses only the scorer's small memory footprint.

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
- [x] Draft PR #2823 opened with explicit experimental/unsupported boundaries.
- [ ] Native scorer integration through real direct and delegated agent runs,
      saved grant parity, revocation, stop and follow-up proof.

## Separate queued work

Bonsai fused RHT / Hadamard prefill and decode investigation is running as a
separate source/evidence audit. Preserve existing load/prefill/FP16-KV fixes;
do not bundle it in this form feature. The requested `.64` target refers to the
Python/Electron release lane, not Osaurus's `0.25.x` version. No release action
is authorized by this planning note.

## Evidence

Agent integration checkpoint: local `tests-forms-agent-integration-3.log` and
`Tests-forms-agent-integration-3.xcresult` under the private campaign evidence
directory: 72 XCTest + 129 Swift Testing cases, zero failures, exit 0.
Includes five real native-S1/WebKit scenarios (apply, revoke, interrupt,
decline, revoke after first field) and six real-S1/AX-driver scenarios (apply,
revoke, interrupt, unverified value, read-only, agent permission revoked).
Native AX scenarios use a mocked driver, not actual macOS permission proof.
The existing pinned probability-parity rows ran without skips. First attempts
failed on a missing diagnostics switch case and missing inner `try` in new
test macros; both failure logs are retained. Fresh integrated-app UI,
delegation, actual footprint and full AgentLoop/Frontier evidence remain open.

### Nested live checkpoint (source `d1ec09c1`)

**Still experimental; keep this PR open/draft.** Exact optimized isolated app
binary SHA256
`2a6d34f46905cac3f7b6d7ba6dd640ceeba416dfcbc772b178741fdffefd16e6`, engine
`6026359408f02c5867643d84300b0ca2225a2e88`. Local focused run
`Tests-nested-s1-queued.xcresult`: **72 XCTest + 238 Swift Testing = 310**
cases, zero failures. The build also completed successfully. These are not
the full evaluation or mixed-model handoff matrix.

Source trace: `SubagentAdmissionLease.swift`, `SubagentSession.runPrepared`,
and `DelegationResidencyContext.capture/run` preserve actual parent admission
ownership across a delegated chat, its nested local tools, and queued starts.
Only the parent's own shared slots are released before exclusive upgrade;
normal child authority, RAM and residency checks still run. Children drain
before restoration and owner release. Stop during an upgrade may wait for
already-admitted peers to drain; those peers are not killed or bypassed.

Real app UI, same Gemma snapshot/defaults as the prior checkpoint below:

- Orchestrator → Helper → Browser completed at engine capacity **one**, with
  active high-water one, without the former parent-slot self-wait. Parent and
  child histories and actual website visits are retained.
- Continued same Helper session: real CPU S1 receipt
  `B1C4307A-C798-44A0-BB48-AF9BE1327BED`, **2 fields scored / 2 applied**,
  one batch in **3.900667 ms**, separately approved and independently observed
  in the website's input/change events; no submission. Browser planner
  last-step **84.7248 tok/s**, 233 completion tokens, 5 steps. Child L2
  hits/misses/stores **21/323/55**, prefix **0/0**. Parent resumed with the
  correct two-item / $24 cart answer: 53 tokens, **83.7 tok/s**, .4954s TTFT,
  normal stop. S1 is the scorer; Gemma remains the actual planner.
- Actual main-chat Stop while nested Browser Use awaited approval removed
  the modal and cancelled both histories. A subsequent delegated browser
  read completed normally; health had active/pending/chat_active all zero,
  capacity/available one. Existing generic cancellation UI says Failed and
  tool envelopes say `execution_error`, despite terminal reason `cancelled`.
- **Accuracy failures retained:** first run selected the wrong first public
  book and omitted a duplicated cart line; first form follow-up incorrectly
  opened a sign-in window and then claimed scorer execution without a scorer
  receipt; post-Stop follow-up again miscounted cart units. Explicit normal
  navigation clarification was needed for the successful S1 follow-up.
  This is not evidence of reliable autonomous browsing or a general task
  success rate. Exact causal attribution of count errors remains open because
  the raw inner reader result is not persisted in these chat receipts.
- Two 300-sample windows peaked at **2.84 / 2.81 GiB app phys_footprint**;
  WebKit subprocesses and whole-system memory are excluded. No near-zero-RAM
  claim, no memory-safety bypass, no second planner model loaded.
- The initial isolated app stalled in external-volume model discovery;
  sampling traced main-thread Foundation `getxattr` through external-model
  size enumeration. Only this test profile was narrowed to the unchanged
  existing Gemma snapshot. General model discovery is excluded, not fixed.
- Final app Settings reports **Accessibility: Not Granted**. Native desktop
  S1 effects remain blocked on the user's grant; a real delegated
  `computer_use` call returned `unavailable` / Required: Accessibility
  (receipt `D1EACAFE-A976-4A3C-94BD-BF457951E5BD`) and the independent fixture
  stayed empty, submit count zero. Mock AX tests do not close this gap.

Private receipts under `vmlx-private-evidence/cua-s1-forms-2026-09-18`:
`LIVE-NESTED-d1.md`, `app-identity.json`, `s1-d1-nested-receipt.sqlite`,
`browser-demo-events.jsonl`, `memory-nested-d1{,-followup}.jsonl`,
`live-d1-s1-retry-complete.png`, `live-d1-stopped.png`,
`live-d1-post-stop-followup.png`, and `sample-d1-settings.txt`.
No screenshots or private profile values are committed.

### Earlier live browser checkpoint (source `8cbc5ba9`)

Exact optimized isolated app binary SHA256:
`38ae6d8ae4903fe8828c6b976e6915293b0c320940147d013c8b03e6803ceefc`.
Engine pin: `6026359408f02c5867643d84300b0ca2225a2e88`.
The planner was local Gemma 4 E2B it 8bit, HF snapshot
`433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, bundle defaults temperature 1,
top-p 0.95, top-k 64, EOS `[1,106,50]`; no sampler or prompt masking.

- Real browser follow-up reached the public book detail page and returned
  **A Light in the Attic / £51.77**, then read **two** local cart entries at
  $12 each and the $24 total. Browser receipt
  `E21C08E9-996B-4986-B5C7-9CB66D794618`: 6 steps, 295 completion tokens,
  last-step 83.7329 tok/s. Main answer: 113 tokens, 85.8 tok/s,
  0.3136 s TTFT, normal stop. L2 hits/misses/stores 13/129/29, prefix 0/0.
- A subsequent real S1 call filled the two reviewed fictional contact fields;
  independent website events record both edits, no new submission. Receipt
  `4306981D-51BB-4ABF-9959-00F13B8A173E`: 2 scored / 2 applied, one CPU
  batch in 0.002448625 s. Planner last-step 85.4723 tok/s; main answer
  140 tokens at 85.5 tok/s, normal stop. L2 18/177/41, prefix 0/0.
- The first reader replay is retained as a **failure**: it miscounted
  duplicated cart articles and guessed a public URL which returned 404.
  The later successful follow-up does not erase that row or establish a
  general browser task success rate.
- 300 process-memory samples peaked at 3,093,318,584 bytes (~2.88 GiB)
  app `phys_footprint`. This excludes WebKit child processes and is not a
  whole-system or near-zero-RAM claim.
- Orchestrator → Helper → Browser remains **unproved** at this head:
  an earlier real run self-waited on its parent's local admission slot.
  The owned nested-admission correction is undergoing separate regression
  tests; it is not in this app binary.
- Actual Settings → Computer Use → Refresh permission status reports
  **Accessibility: Not Granted** for this isolated app. Native desktop
  execution remains blocked on a grant to the final rebuilt artifact;
  mocked AX tests are not permission or native execution proof.

Private receipts: `LIVE-BROWSER-8cbc.md`,
`s1-8cbc-browser-receipt.sqlite`, `memory-reader-s1-replay.jsonl`, and
`desktop-permission-refresh-8cbc.png` under the campaign evidence directory.
No screenshots are committed. Current focused proof is not the full
AgentLoop/Frontier or broad handoff matrix; no production-readiness claim.

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

## Live UI finding and expanded context request (18 September)

CI at `adf3a545` caught four Forms catalog destinations with an unhandled
Computer Use sub-tab. The view already consumed `computerUseSubTabRequest`, but
Management search did not set it. The search dispatcher now forwards that
request, and the destination-enum regression covers Computer Use plus a Forms
profile-search case. Live search-to-Forms navigation remains to be checked in
the rebuilt app; a catalog match alone is not proof of navigation.

At `adf3a545`, the optimized isolated app imported the synthetic contact PDF,
displayed the extracted candidates, let the user remove the document heading
candidate, and saved the three reviewed fields in its isolated profile. The
original UI driver crashes while traversing the Forms tab; an explicitly
authorized AppleScript/Accessibility fallback exposed a separate app issue:
the scorer-folder button did not open a picker, while the document button did.
Both `fileImporter` modifiers were attached to the same view. They now share
one presenter with an explicit import kind. Rebuild/retest both buttons; this
source change alone is not live verification. Actual native preview, confirmed
fill, no-submit and relaunch remain pending.

The user has expanded the prototype's desired scope to reusable Computer Use
context and parity across spawn/delegation. **The current implementation is
manual-only and does not yet satisfy that expansion.** Keep #2823 a draft.

### Context users should be able to provide

| Use case | Explicit candidate values | Scope / review needed |
| --- | --- | --- |
| Personal/contact forms | Name, preferred name, email, phone, separate shipping/billing address | Selected person/profile; do not mix household members |
| Company/vendor onboarding | Legal company name, department, role, public business contact, reference IDs | Selected organization; distinguish personal vs company data |
| Job/event applications | Employment/education fields, experience dates, registration details | Reviewed facts from CV/application notes; no invented qualifications |
| Travel/expense workflows | Trip dates, destination, cost center, receipt amounts/currency, expense category | Per-task data overrides only with explicit conflict review; no payments/bookings implied |
| Support/service requests | Product/version, customer reference, issue title, explicit description | Separate reusable facts from the current request |

Current label/value profiles can represent short explicit values; they do not
provide general prose reasoning or OCR. Arbitrary notes, long answers, PDFs,
images, dropdown categories and free-form instructions are different inputs:

- Keep document candidates with visible provenance and review status; reject
  conflicting duplicate labels rather than silently selecting a source.
- Let users distinguish reusable profile data from task-only values and select
  a single person/organization/context for the run. A later task must not
  inherit stale trip/expense details automatically.
- Preserve aliases and date/currency units explicitly. Any typed-field
  conversion or dropdown classification needs separate evaluated behavior;
  do not claim those are covered by the current field-value scorer.
- Keep scorer feature/context construction faithful to its 224/96-byte
  contract. Long notes cannot simply be appended and advertised as understood.
- Do not treat document text, agreement text or the scorer's training TASK
  string as authorization to submit, consent, purchase or disclose secrets.

### Required integration / parity before broader agent claims

- [ ] Trace the selected profile and explicit sharing grant from Computer Use
      settings into `ComputerUseTool` → `ComputerUseKind` → `ComputerUseLoop`.
- [ ] Use a run-owned, bounded snapshot/reference, not global mutable selection
      read anew in every child. Do not inject all saved values into every LLM
      prompt. Remote-model exposure must be explicit in the user-facing scope.
- [ ] Trace `SubagentSession`, spawned text-agent tool dispatch, delegated
      agent identity, batch siblings, background/watcher paths and model
      residency handoff. Recipient authority must not increase on inheritance.
- [ ] Test same-profile inheritance, unauthorized child denial, distinct
      sibling profiles, selection edits during a run, cancellation, persistence,
      and disabling/revoking before an action. No cross-run/context leakage.
- [ ] Reuse Computer Use's action confirmation, target/window validation,
      policy/allowlist and post-action effect checks; scorer output must not
      become a second bypass around those controls.
- [ ] Prove an actual direct run and a delegated/spawned run in the isolated
      app, with source/artifact identity and observed target changes. Scripted
      dependency-injection tests are useful but not native runtime proof.
