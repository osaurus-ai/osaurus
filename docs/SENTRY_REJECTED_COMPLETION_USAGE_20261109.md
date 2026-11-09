# Preserve measured usage on rejected completions

Status: partial candidate. Focused regression proof passes; fresh native Release,
app interaction, applicable evals and full CI remain required. No model-family,
RAM, quality or incident-prevention claim.

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
remain intact. The completion latch records the physical terminal already
observed upstream; an earlier consumer cancellation still wins.

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
candidate currently has focused runtime-component proof only. Fresh native app
and eval proof remain pending. Prior documented overwritten sidecar and sampler
gaps from other lanes remain declared; no cleanup performed.
