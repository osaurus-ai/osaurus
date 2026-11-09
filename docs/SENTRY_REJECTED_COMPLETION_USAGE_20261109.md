# Preserve measured usage on rejected completions

Status: draft pending final-head CI. The isolated accounting correction has
controlled native and component proof below. Both full model runs remain red:
candidate65passed/50failed/4skipped, baseline54passed/61failed/4skipped.
Those model rows are not qualified by this fix. No model-family, low-RAM, broad
quality or incident-prevention claim.

A real Gemma E2B QAT MXFP4 clock request completed without its required call.
The existing tool-choice validator correctly rejected it. Activity retained
input4146 and an error, but lost the measured output. Later correlation with a
retained runtime window recovered17 generated tokens and engine104.3tok/s
(rounded). The separately derived first-output decode metric was175.3tok/s.
The shared log has no explicit request-ID/PID join; full-precision engine rate
and the original Activity/history terminal usage remain unavailable. The
original failed qualification is preserved.

The cause of the accounting loss is narrower than the cause of the missing
tool call: ResponsesToolChoiceContract withheld responseCompleted on validation
failure and attached only response_id to NSError422. ChatEngine's logger runs
after validation, so it never received that completion's corrected input and
measured output counts.

The candidate attaches only those optional measured counts to the same error
under a private typed key. The logger persists them and charges only newly
known work under its existing monotonic budget rule. Real zero remains zero;
unavailable remains unknown. The original domain/code/message/response_id,
error outcome, tool policy, withheld success terminal and no-dispatch behavior
remain intact. The completion latch records measured terminal metadata already observed
upstream; producer/cache cleanup can still be pending. An earlier consumer
cancellation still wins, and pending runtime drain must retain its ownership.

Activity continues to calculate request rate as output tokens divided by full
request duration. It does not substitute engine/decode rate. No model request,
prompt, sampler, reasoning, parser, cache, generation-default or provider-wire
event was added. This candidate targets Activity and background-budget counts;
it does not claim to repair error-message history stats or every HTTP usage
consumer.

## Evidence

Private root: /Users/eric/vmlx-private-evidence/sentry-inference-20261108/.
No raw Sentry events, images, model payloads or private app state are uploaded.

- Original native candidate SHA256
  7766946871a434e2e895e1a858ecda2936c9837d57832f57702507d371a6c516,
  vMLX1bcd74ad182103a3b83941f61e57ee0bac23b330, Aptabasea55267506ca9e9413e242cff00309f91bda16679.
  Model revision da2cd74442e6f4f1a8d720a592b21c53c013093f, temperature1,
  top_p0.95, top_k64, do_sample=true, EOS[1,106,50]; no explicit repetition
  penalty/output cap/reasoning override. Installed template selected Thinking
  off. Original quality1/4 and RAM failure remain.
- Baseline production32f1dfd245640a93383660f3d09441f4d29a3fd0, with the new
  regression only: raw SwiftTesting aggregate59tests/8suites,9issues. All9
  assertions belong to the required-call regression's3 argument cases
  (unavailable/zero/17 output); the other7suites passed. ActualPID26082 had all5
  private environment values independently verified. Full log, xcresult,
  source snapshots and original binary retained. See
  rejected-completion-usage/BASELINE1-REVIEW-v2.json. Earlier review's
  subtractive58-test wording was corrected without deleting it.
- Candidate on merged-maine96dc64595d8ea2e9578d6bd822f6a58d4debba7:
  **72tests/9suites, zero issues,3.739s**, actualPID32355 with all5 private
  values verified. Source hashes unchanged during execution. Includes actual
  ChatEngine→validator→logger→Activity storage, reported zero/unavailable,
  corrected input257→277, unchanged422/identity/no successful terminal, and
  actual BackgroundTaskManager receiving277input/17output once after streamed
  estimates. Existing HTTP tool-choice, input accounting, native stream/result,
  mapping and consent suites passed. No model inference occurred in these
  fixtures; fixture rates are not runtime throughput proof.
- Separate offline full-history diagnostic preserved the real London tool
  result and conflicting stale Los Angeles identity memory through the actual
  converter/processor. Counts4621 direct versus4622 converted differ where
  string arguments become the structured tool-call dictionary expected by the
  bundle template. No token/logits parity or model-output cause is claimed.
  Private diagnostic source was archived outside automatic discovery before
  candidate replay so its hardcoded output receipts were not overwritten.

Run logs/plans/results and private fixtures are under
rejected-completion-usage/. Later native/CI receipts must add exact source and
app identity, complete scores including failed rows, measured rate/resource
boundaries, and retained artifacts before this PR is described as qualified.

SOURCE EVIDENCE: ResponsesToolChoiceContract.swift, ChatEngine.swift,
ActivityTokenProvenanceTests.swift, existing ResponsesToolChoiceContractTests,
HTTPToolChoiceContractTests and LocalInputTokenUsageTests.

LIVE EVIDENCE: the original failed native request/recovery is in
telemetry-consent-hot-read/FAILED-CLOCK-RUNTIME-METRICS-RECOVERY.json. The new
candidate also has the named native accounting/UI proof and a complete red
model matrix described below. Baseline comparison and expanded test proof
remain pending. Prior documented overwritten sidecar and sampler
gaps from other lanes remain declared; no cleanup performed.


## Later frozen-product qualification

Fresh isolated Release from2733 has executable SHA256
c640178443ed9cf1de960da88843fff31b1714ae2366a2504aca95e55d5b4ac1;
vMLX/Aptabase pins and quant bundle defaults are unchanged. Two actual private
launches exercise Chat/Settings,8/8ordinary answers,6/6actual tools, normal
quit/relaunch/history and post-error recovery. A controlled user-input conflict
elicited a missing required call without changing the production prompt or
sampler. Actual request required/generation{} verified; Activity seq77retains
4294reported input/1reported output, original error/no tool and3.788208request
tok/s. Insights UI and app-exported JSONL preserve the row and its hash. Engine
102.1rounded and derived decode83.3tok/s measure different intervals. This is
controlled accounting proof, not a spontaneous incident recurrence.

Native15Gemma generations emit engine rates;17Foundation housekeeping
requests have separate request rates. Sampled footprint peaks5,255,222,168and
5,322,511,040bytes exceed4,002,479,278weight bytes: RAMFAIL. Original poorer
quality rows remain failed; no causal quality diagnosis or retrospective pass.
Full artifacts: NATIVE-CANDIDATE1-QUALIFICATION-v2.json,
NATIVE2-APP-EXPORT-REVIEW.json, native2-activity-export1.jsonl and retained
screenshots/AX/resources/normal-quit database snapshots.

The candidate full AgentLoop+Frontier run finished119logical fixtures:
65raw passed,50failed,4skipped, exit1. The115attempted unique fixtures produce
119trial transcripts because two fixtures each use3trials.437model steps all
emit decode rates;3,146physical samples peak7,326,584,864bytes, also RAMFAIL.
All17same-model rubric rows were manually reviewed;3rows contain incorrect
positive automated verdicts. Raw reports remain unchanged. The suite marks
self-judge, while row-level selfJudge=false for an explicit identical judge is
incorrect metadata. No such grade is treated as independent evidence.

The exact116workspace paths from transcript system prompts and the PID-owned
runtime root are APFS-cloned and hashed; original paths remain. A first copy
preflight rejected interleaved stdout before copying anything; its failure is
retained. See agent-matrix-candidate1/{RESULT,PRELIMINARY-REVIEW1,
MANUAL-RUBRIC-REVIEW1}.json and retained-runtime-files2/MANIFEST.json.
The unchanged e96baseline is running the same119fixtures. Added local test-only
cases cover conservative1/17token budget charging/ceilings and a real native
stream adapter's pending drain after tool-choice rejection. Those tests have
not run yet; they are not passing evidence. Product source remains frozen2733.

SOURCE EVIDENCE: the two production files remain byte-identical to2733;
current additional edits are tests and this qualification document only.

LIVE EVIDENCE: the named native rows and full candidate matrix above are
retained. Model-family/low-RAM/readiness gates remain red; baseline comparison,
expanded component qualification and final-head normal CI remain pending.


## Expanded controls and completed baseline comparison

The expanded current-production gate passes309tests in18suites,0issues,
4.231s, including canonical agent/tool-loop budgets, delegated accounting,
frozen turn controls, system-prompt resolution, cancellation and controlled
Metal errors. A pending native stream drain survives the rejected terminal;
original422and error status remain, no successful terminal/call is emitted,
and the logger retains73reported input/17reported output. Old e96production
with identical new fixtures fails21tests/2suites with25issues:9lost-count,
14budget and2drain-row accounting assertions. Physical drain ownership itself
passes on both sides; no new drain defect is claimed.

A receipt exposed that the initial1token case equalled its1token stream
estimate. It did not test no-refund. The corrected fixture explicitly verifies
its estimate is9and uses0/1/17reported outputs, each with/without a budget
ceiling. The affected suite passes12tests/1suite,3.347s; its6budget argument
rows preserve9charged tokens for reported0/1and charge17once for reported17.
Activity retains the actual reported0/1/17counts. Corrected277input and total
work trigger the configured lower ceilings; unlimited controls stay running.
The same updated fixture on old e96fails12tests/1suite with29issues, retaining
257input/nil logged output and failing exhaustion. These framework totals
overlap; do not add309and12as distinct tests. All actual test PIDs have5private
environment flags verified; original/revised fixtures, logs, xcresults and
binary bundles remain retained. Product source is unchanged from2733.

The completed baseline full model matrix has54raw passes/61failures/4skips,
versus65/50/4candidate. There are10candidate-only raw failures and21flips in
the other direction. This unseeded comparison is not quality-improvement or
regression-free proof. Every recorded candidate inference request is auto
(437) or omitted(10), all447status200. Baseline likewise has470auto/9omitted,
all479status200. AgentLoopEvaluator usesauto/nil, for which the tool-choice
contract returns the upstream stream unchanged. These actual records do not
enter the changed rejected-error branch; controlled negative rows do. Task,
file, tool and rubric failures remain red and are not attributed to this
unexecuted branch.

All437candidate/470baseline transcript steps emit numeric rates, including
12/19zero-token, zero-rate empty completions. Those are not positive-throughput
or quality passes. Actual fresh DEBUG logs have465/497engine stats, including
one auxiliary length-stop each, not joined to parent step identity. No parent
transcript has a length-stop step. Baseline sampled footprint peaks
6,424,399,832bytes, also RAMFAIL. Source/fixture/default/pin/environment
identities are retained; no sampling intervention or rerun-for-green.

The initial eval wrapper also copied an older Release/tmp log. DEBUG writes
under each source checkout's tmp; the correct logs were recovered with actual
PID13018/41946and hashed, while stale copies remain labeled as context only.
No lost evidence or rerun was needed for that correction.

SOURCE EVIDENCE: the two production files remain exactly2733; only test and
qualification documentation changes follow that frozen implementation.

LIVE EVIDENCE: EXPANDED-COMPONENT-QUALIFICATION1.json,
BUDGET-BASELINE-CONTROLS-REVIEW1.json, FULL-MATRIX-COMPARISON1.json,
ZERO-AND-LENGTH-RATE-BOUNDARY1.json, both actual DEBUG log identities and
retained-runtime-files manifests. Final-head CI is required before merge.
