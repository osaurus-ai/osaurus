# Rotating KV restore isolation consumer checkpoint

The runtime pin consumes vmlx-swift #752, merged as
`1a227377fcca0e94ea8b6304f7cd9dff68791130`. Restored rotating caches now receive
independent mutable MLXArray wrappers while retaining copy-on-write storage.
Previously, advancing one restored request changed retained arrays and another
request's arrays without changing that other request's metadata.

The previously consumed runtime reproduces the failure in all four standalone /
composite and keep=0/1 fixture rows through public restoreFromDiskArrays. Its
exact regression XCTest has 24 failed assertions. A complete MLXLMCommon rebuild
with the fix passes the four-row public restore matrix and four affected XCTest
cases, including three existing disk-persistence guards. The runtime merge tree
matches that tested projection exactly. These tests use real Cmlx/Metal arrays.

This consumer checkpoint remains PARTIAL. A fresh native Release app and CLI
build pass on combined projection `42a6c629c72eafbee8751af6d1fcf681dd22fc60`
(this pin plus the independently qualified analytics fix). The app binary SHA-256
is `918d97431d8527a8d48911f8d74cc30682be7f62f06f25f70824b4f565cf7041`.
No generation defaults or cache settings change in this pin update. The native
API rows below establish bounded cache behavior. Normal File > New Chat opens
the Chat surface without accepting the onboarding Terms/Privacy CTA or editing
onboarding state. The actual UI rows below supersede that earlier approval gap;
they retain a failed answer and do not qualify the model family.

## Native runtime evidence

An isolated profile and internal copy of the existing public
`OsaurusAI/gemma-4-E2B-it-qat-MXFP4` bundle were used. The original external model
is untouched. Actual process environment and open database paths were verified;
all test cache writes remained under the private profile. Earlier launches made
with the old transient-launchctl helper were invalidated and retained. Only
subsequent launches with explicit per-launch `open --env` count as evidence.

Generation defaults came from the bundle: temperature 1, top-p 0.95, top-k 64,
do_sample=true, no repetition penalty or forced thinking. The requests supplied
only an explicit diagnostic max_tokens 2048 and their tool-choice mode; no row
stopped at that cap. Rates below are emitted native tokens/s for short functional
probes, not a speed benchmark.

- Four connected text/tool turns completed through the native app's HTTP path.
  Both structured clock calls parsed and executed through the app's actual MCP
  registry. Only 1/2 calls supplied the requested timezone: the first omitted UTC
  and correctly received the native default America/Los_Angeles. Both visible
  follow-up answers were factual. This instruction failure remains retained and
  has no assigned parser or runtime cause. Rates 115.82–121.28 tok/s.
- After app quit/relaunch, three exact text requests each restored 2,462/2,465
  prompt tokens, with disk hits increasing 1/2/3 and correct visible natural-stop
  answers. Rates 119.96–120.20 tok/s.
- Real red/blue and red/green PNG payloads produced correct left/right colors
  in 4/4 cold/repeat rows. Changing the image missed the previous media prefix;
  repeating each image restored 2,109/2,112 tokens and increased disk hits.
- After another app quit/relaunch, both image requests restored 2,109/2,112 tokens.
  Their growing-history follow-ups restored 2,128/2,145 and 2,129/2,146 tokens and
  correctly identified the red side: 4/4 answers. All image rows, including one
  additional streaming probe, reported 120.67–122.15 tok/s. No observed marker
  leakage, looping, unclosed reasoning or length stops.
- The streaming probe emitted actual runtime stages: queued, prefill 0/2,118,
  then 512/1,024/1,536/2,048, complete 2,118/2,118 before decode. This verifies API
  progress telemetry; it does not establish visible Chat progress wiring.
- A separate native Settings control turned prefix reuse off, saved, navigated
  away/back and relaunched. Effective paged/disk reuse and their counters were
  off/zero; four connected clock/text turns plus a restart replay completed at
  113.68–119.90 tok/s. Physical footprint still reached 5,247,079,104 bytes.
  Persistent prefix reuse is therefore not necessary for that RAM failure.
  Per-request KV remains; `cache_enabled:true` alone is not a reuse claim.
- A real client disconnect at measured prefill 512/8,676 produced no decode
  rate: that cancelled diagnostic is BLOCKED for throughput and excluded from
  successful generation rows. Cleanup reached idle on the first subsequent
  poll. Recovery and repeat both answered 29 at 95.47/93.94 tok/s; repeat reused
  8,673/8,676 tokens. No partial checkpoint was stored before cancellation.

## Actual native Chat and restart

The same Release app completed four connected user turns (five model passes)
through actual Chat controls. The arithmetic answer was 29. The next turn
emitted `get_current_time` with `timezone: Asia/Seoul`; the native tool returned
success and the visible answer correctly said nine hours ahead of UTC. Its
tool card settled in 97 ms. The connected follow-up correctly converted that
to 540 minutes. After quit/relaunch, saved History restored the messages and
the settled tool card. A fourth turn restored 4,403/4,502 prompt tokens and
answered with the correct city and nine-hour offset, but omitted the requested
minutes unit. Requested-answer quality is **3/4**, not a full pass; the cause
of the omission is unassigned. No retry or rewritten output replaces that row.

All four turns stopped naturally, Stop disappeared and input unlocked. No
loop or raw protocol marker was observed. Native engine decode rates for the
five model passes were 105.87, 103.16, 101.39, 100.74 and 100.99 tok/s. Native
automatic Foundation title/follow-up generations have separate activity rates
in the retained receipt. Physical footprint reached 5,144,597,448 bytes before
restart and 4,842,164,496 after restart: both fail the model-size RAM gate.

Optional image-model discovery initially blocked picker readiness despite the
local text model scan having finished. A native process sample shows the picker
awaiting a directory listing in `ImageGenerationService.imageModelsRoot`; the
main thread was idle. The documented `OSAURUS_IMAGE_MODELS_DIR` override pointing
to an empty private directory allowed ordinary Chat to become ready. This is
diagnostic isolation, not a production wait fix or Sentry hang attribution. No
image-generation model, generation config, sampler or onboarding state changed.
Accidental window minimization and unsuccessful tab-selection attempts are
retained; the successful restart continuation used the actual History inspector.

Effective topology was fp16 KV, 12 rotating and 3 full KV layers, disk-backed
restore required, paged RAM disabled, and 0 TurboQuant KV layers. Prefix/paged
counters remained 0; the observed hits were disk L2. No SSM companion state was
required. No audio or video claim.

## Qualification failures and remaining proof

Physical footprint reached 5,030,597,432 bytes in the text candidate process,
above this bundle's 4,002,479,278 weight bytes. The old consumed runtime
`1bcd74ad182103a3b83941f61e57ee0bac23b330`, tested in app `0c53af186` with the same
request harness, also failed this gate at 5,274,226,984 bytes. Its four text/tool
turns completed with both requested zones. These are sampled outputs with no
fixed seed, not deterministic logits or a statistical regression bound. Neither
row qualifies the model family as low RAM or working. No allocator clamp or
sampler change was introduced to conceal the failure.

The serialized native conversations did not visibly reproduce the old wrapper
alias defect; the public restore matrix and exact XCTest do. No incident-specific
Sentry attribution, family readiness, speed improvement or release is claimed.
Real Chat controls and complete turn settlement were observed as described
above. Visible long-prefill Chat progress remains unproven. The separate
screen-context Accessibility permission request
also remains pending; it is unrelated to this runtime pin.

## Behavior contract audit

The restore contract requires independent request advancement with identical
restored tensor values, ring offsets and retained metadata. `MLXArray` is a
mutable reference wrapper; full-range indexing creates a new wrapper with
shared lazy backing storage. The fix changes only wrapper ownership at restore.
It leaves serialization, numerical contents, ring metadata, topology and model
generation behavior untouched. The old/new real Metal matrix tests those
observable contracts, including mutation of each restored request in turn.
This establishes the narrow restore defect independently of the unsuccessful
model-family qualification rows. This PR remains draft while those gaps are
investigated; no invented sampler, prompt or memory-limit workaround is applied.

Cumulative raw events, original failed runs, revised runs, compiler commands,
shader identity and retained disk fixtures are kept privately at
`/Users/eric/vmlx-private-evidence/sentry-inference-20261108/rotating-restore/`.
They must remain available through later iterations.

Native raw requests/responses, real tool results, cache snapshots, PNG payloads,
SSE timings, physical-footprint JSONL, source/app identities, baseline comparison
and corrected observation notes are retained in the adjacent `cache-api-proof/`
directory. The initial mistaken comparison of a cache panel with older API state
is retained and explicitly corrected: simultaneous API/UI state agreed that no
model was loaded. No UI cache-panel defect was established.

`NATIVE-CHAT-QUALIFICATION.json`, `PREFIX-REUSE-OFF-CONTROL.json` and
`prefill-cancel-run1/REVIEW-rate-clarification-v2.json` preserve the continued
UI, controls, restart, failure and cancellation evidence. The private
`behavior-contract-audit-20261109/AUDIT.json` records the source/caller/upstream
review for each proposed fix in this investigation.
