# Preserve measured usage on rejected completions

Status: draft pending final-head CI. Controlled native and component proof
qualifies the isolated accounting behavior below. Both full model runs remain
red; this patch does not qualify their model quality, RAM or incident prevention.
Production implementation is frozen at2733ec02543d136296f7b67be45e5e0db33adb82;
subsequent commits change only tests and qualification documentation.

## Cause and existing behavior contract

A real Gemma E2B QAT MXFP4 clock request completed without its required call.
The existing validator correctly rejected it, but Activity retained input4146
and an error while losing measured output. A retained runtime window later
correlated17generated tokens and rounded engine104.3tok/s; derived decode
175.3tok/s is a different interval. That shared log has no explicit PID/request-ID
join, and full-precision original rate was not recovered. The original failed
row and quality1/4/RAMFAIL remain unchanged.

ResponsesToolChoiceContract withheld responseCompleted on validation failure
and attached only response_id to NSError422. ChatEngine installs its logger
after validation, so corrected terminal input/output counts never reached it.
The correction attaches only optional measured counts under a private typed
key and applies the logger's existing monotonic budget rule. Reported zero
remains zero; unavailable remains unknown. Streamed budget estimates are never
refunded, and a larger terminal count charges only the additional work.

Domain/code/message/response_id, error outcome, withheld success and no-dispatch
policy remain intact. The completion latch observes terminal metadata, while
physical producer/cache cleanup can still be pending; earlier consumer
cancellation remains authoritative. No prompt, sampler, parser, cache policy,
generation default or provider-wire event changes. Activity keeps its existing
full-request rate calculation. HTTP/history error-usage consumers beyond this
logger are not claimed fixed.

## Deterministic component and native proof

- Original old-production regression:59tests/8suites,9issues in the3argument
  cases of the new rejected-completion test; the other7suites passed. Earlier
  candidate72tests/9suites passed. Both original binaries/logs/xcresults and
  corrected earlier count wording remain retained.
- Expanded corrected-production gate:309tests/18suites,0issues,4.231s.
  Canonical agent/tool-loop budgets, delegated accounting, frozen controls,
  system prompts, cancellation and controlled Metal errors pass. The native
  stream adapter's pending drain completes without cancellation after the
  required-call rejection; original422/no-success/no-call/error status and
 73reported input/17reported output remain. Identical new fixtures on old
  e96production run21tests/2suites and report25issues:9lost-count,14budget and
  2drain-row accounting assertions. Physical drain ownership passes on both
  sides; no new drain defect is claimed.
- An initial1token fixture equalled its1token estimate, so it did not prove
  no-refund. Its source/results remain retained. The revised fixture asserts
  an estimate between1and17and observes9. Reported0/1/17each run with/without
  a budget ceiling. The affected12tests/1suite pass in3.347s, with6argument
  rows:0/1retain9charged output tokens,17charges17once, Activity persists the
  reported0/1/17, input corrects to277and lower ceilings cancel. Unlimited
  controls stay running. The exact revised fixture on old e96runs12tests/1suite
  with29issues, retaining257input/nil logged output and failing exhaustion.
  The309and12framework totals overlap; do not sum them. All actual test PIDs
  have5private process flags verified.
- Fresh isolated Release from2733: executable SHA256
  c640178443ed9cf1de960da88843fff31b1714ae2366a2504aca95e55d5b4ac1.
  Development version1.0, vMLX1bcd74ad182103a3b83941f61e57ee0bac23b330,
  Aptabasea55267506ca9e9413e242cff00309f91bda16679. Quant revision
  da2cd74442e6f4f1a8d720a592b21c53c013093f, bundle temperature1/top_p0.95/
  top_k64/do_sample=true/EOS[1,106,50], no explicit cap/repetition penalty/
  reasoning override; installed template selects Thinking off.
- Two verified private launches exercise8/8ordinary answers,6/6actual tools,
  Chat/Settings, normal quit/relaunch/history and post-error recovery. A
  predeclared conflicting user input intentionally elicits text without the
  required call. Actual required/generation{} request verified; UI preserves
  text plus original error and dispatches no tool. Activity seq77retains
  4294reported input/1reported output, status500/error and3.788208request tok/s.
  Rounded engine102.1and derived decode83.3tok/s are distinct. Actual Insights
  and app-exported JSONL preserve counts/error/hash; app manifest reports
  chainIntact=true/0problems, not an independent hash reimplementation. This
  is controlled negative accounting proof, not a spontaneous recurrence or a
  production prompt change. Native15Gemma generations emit engine rates;
  17Foundation housekeeping requests have separate request rates.

## Full agent-loop comparison and limits

Both sides ran the same119logical fixtures: candidate65raw passes/50failures/
4skips; old e96baseline54/61/4. There are10candidate-only raw failures and21
flips in the other direction. Unseeded outcomes do not establish improvement
or regression-free quality. The same4skips are sandbox setup and3missing
AppleScript-model cases; no OS grant, sandbox setup or download forced them.

Actual recorded candidate inference requests are437auto+10omitted, all447
status200. Baseline has470auto+9omitted, all479status200. AgentLoopEvaluator
setsauto/nil; the contract returns the upstream stream unchanged for those
values. These records bypass the changed rejected-error branch, exercised by
the controlled negative tests instead. Task/file/tool/rubric failures remain
red and are not attributed to an unexecuted branch.

Each run attempts115unique fixtures with119trial transcripts because two
fixtures use3trials. Same-model rubric grades are non-independent. All17
candidate rubric rows were manually reviewed;3contain incorrect positive
automated verdicts, with originals retained. Suite metadata marks self-judge;
individual selfJudge=false for an explicit identical judge is incorrect and
is not used as independent proof.

All437candidate/470baseline transcript steps have numeric emitted rates,
including12/19zero-token, zero-rate empty completions. They are not positive
throughput or quality passes. Fresh PID-matched DEBUG logs retain465/497
engine stats and one auxiliary length-stop each, not joined to parent step
identity. Neither parent transcript contains a length-stop step. SwiftPM and
native Xcode retain7other committed dependency differences; same vMLX/Aptabase
pins do not imply all-binary parity. Evals use the canonical0.25.31host version;
the native development app reports1.0.

RAMFAIL remains: native sampled peaks5,255,222,168and5,322,511,040bytes;
full candidate7,326,584,864and baseline6,424,399,832bytes, all above
4,002,479,278quant weight bytes. No low-RAM, family, M2/M3physical-hardware,
SSD-optimization or Sentry-incident-prevention claim.

## Retention and current evidence

Private root: /Users/eric/vmlx-private-evidence/sentry-inference-20261108/.
Raw Sentry events, images, model payloads and private app state are not uploaded.
Each model run retains116exact workspace paths plus its PID-owned runtime
root as APFS clones with file hashes; original paths remain. Successful and
failed transcripts, generated files, DB/WAL state, rates/resources, binaries,
commands and every earlier test iteration remain retained. A snapshot preflight
rejected interleaved stdout before copying; a review-generator ID mismatch
also failed before writing results. Both failures are retained.

The wrapper initially copied an older Release/tmp log. DEBUG writes under the
source checkout's tmp; correct PID13018/41946logs were recovered and hashed,
while stale copies remain labeled context only. No rerun was needed. Prior
unrelated overwritten-sidecar and sampler gaps remain explicitly declared.
The separate tokenizer/memory diagnostics are retained without attributing
model quality to them; no memory or tokenizer patch is included here.

SOURCE EVIDENCE: Services/Inference/ResponsesToolChoiceContract.swift,
Services/Chat/ChatEngine.swift, ActivityTokenProvenanceTests.swift and
ResponsesCancellationInsightsTests.swift. All other prompt/runtime/cache/
default/lock source contracts are unchanged from the named baseline.

LIVE EVIDENCE: rejected-completion-usage/{EXPANDED-COMPONENT-QUALIFICATION1,
BUDGET-BASELINE-CONTROLS-REVIEW1,FULL-MATRIX-COMPARISON1,
ZERO-AND-LENGTH-RATE-BOUNDARY1,NATIVE-CANDIDATE1-QUALIFICATION-v2,
NATIVE2-APP-EXPORT-REVIEW}.json; original/new logs, xcresults, binary bundles,
actual DEBUG log identities, normal-quit DB snapshots and both retained runtime
manifests. Final-head normal CI remains required before merge.
