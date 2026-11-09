# Conversation-owned reasoning and speculative decoding

Status: draft. Native ownership checks are recorded below. The full model
matrix is red, a Gemma Thinking-On protocol failure remains under investigation,
and final-head CI is required before merge.

The requested contract is that a saved agent can keep MTP Off while a user
requests adaptive decoding in one chat. Changing that chat must not edit the
agent, the shared Server preference or another conversation. Reasoning choices
have the same ownership. This changes the persistence intentionally introduced
by PR3247; it is not a claim that its original intent was accidental.

## Reproduced behavior

The unchanged Release baseline, product2733ec02543d136296f7b67be45e5e0db33adb82,
created an agent with Light reasoning and MTP Off. The actual chat picker
changed saved speculative_decoding from false to true and reasoning_effort
from low to none. A second chat and the agent editor showed the changed defaults.
Before/after agent JSON, UI captures and the running app identity are retained
under the private cache-settings-contract-audit-20261109/native-baseline2-internal/
evidence lane. The editor's explicit Save works and remains the route for
changing saved generation defaults.

## Implementation

ChatModelControls stores explicit reasoning/speculation choices per full model
ID in the owning ChatSession. A nullable session column, added by the existing
idempotent migration ladder, preserves them when reopening that conversation.
Missing legacy values inherit defaults. Empty chats remain unsaved until their
first turn. Reset removes a conversation override and reveals current saved
defaults; new/reset chats begin without overrides.

Capture composes a copy of the saved agent settings with these choices before
the existing frozen-turn pipeline. Per-submission overrides retain their higher
precedence. Queued sends, reconstructed tool requests and regeneration retain
their original captured controls. The existing runtime resolves the host-only
speculation preference and prepares the graph through its normal admission
path. Reasoning kind changes clear the same aliases as the existing saved-agent
setter while retaining unrelated template and generation fields.

The main chat card is the only production FloatingInputCard constructor. Its
binding writes the owning session. The other constructor is a preview. The
separate Claude Code harness picker path is unchanged. No control labels or
catalog destinations were added or renamed; the guides describe the new scope.

## Evidence and limits

Tested implementation:2ea466408bd67f467577ee5abd4a88f6cf654af0. Later commits
11fa987e and318be9a7 change test observation/setup only; product bytes match.
The later b886feed semantic source-policy correction is also test-only.
The fresh Release and SwiftPM runner were built at
318be9a7f63af2a04f40db73777b0071813e5a69. Both consume vMLX
1bcd74ad182103a3b83941f61e57ee0bac23b330 and Aptabase
a55267506ca9e9413e242cff00309f91bda16679. SwiftPM and Xcode's seven existing
dependency differences remain disclosed in the evidence.

- Initial focused run:598tests/50suites, one issue. The new isolation test
  took its baseline before selecting a model, which legitimately saved the
  agent's preferred model and timestamp. All other49suites and the other six
  new cases passed. A diagnostic replay retained the original assertion and
  added a raw-file assertion; both failed for that same setup mutation.
- Captured before/after data proves only defaultModel and updatedAt changed;
  generation settings stayed equal. The corrected fixture takes its baseline
  after model selection, retains both byte assertions and adds a baseline
  generation-settings assertion. The affected seven cases pass in0.666s.
  Production code is unchanged. Counts overlap and are not added together.
  All three logs, xcresults, test binaries, patches and process flags remain.
- The affected tests exercise actual ChatSession capture/send/queue/reset/load,
  saved-store isolation, per-model scope, alias composition, per-submission
  precedence and JSON/SQLite reopen. Existing reasoning, editor, MTP,
  migration, cancellation, tool-loop, budget and prompt suites were included.
- Fresh private Release SHA256
  8ea2c63f7c700df6eeff9a2b16534156f903b4267a3db66a7632fb18688a9d53,
  UUID028CCFF5-89AD-380F-A946-8D3148E221AF: three planned Gemma QAT answers
  correct, two real clock calls and a history-dependent follow-up. Actual
  requests have generation{}, preserving bundle defaults. Five parent steps
  emit100.2–104.4engine tok/s, distinct from request rates. Native cache counters
  reach three disk/L2 hits. Peak physical footprint5,320,610,376bytes exceeds
  4,002,479,278weight bytes: RAMFAIL, not a model-family qualification.
- The unchanged119-case AgentLoop+Frontier inventory completed:45 passed,
  70 failed and4 skipped. Compared with the earlier usage candidate,27 prior
  passes fail and7 failures pass. All479 inference terminals are200;473 use
  auto tool choice and6 omit it. The direct AgentLoopEvaluator does not
  construct ChatSession or capture these controls. This red, unseeded,
  same-model-judged run does not establish regression safety. All116 actual
  workspaces and its PID-owned runtime root are retained and hashed, with
  originals preserved. Peak footprint6,645,616,720bytes fails the same RAM gate.
- Native Qwen/DFlash2: create-agent Light/Off, chat None/On, second-chat
  Light/Off, return to the original chat, normal relaunch and independent
  resets are observed. Agent/server bytes and model-option preferences stay
  unchanged around chat-only actions. Actual requests, UI, history SQLite and
  PID-matched logs are retained. A genuinely queued turn and its regeneration
  retain Light while the picker shows None; the next fresh submission uses
  None. Host-only speculation is checked through component request-context
  assertions and actual runtime routes, rather than inferred from an HTTP
  field that does not serialize that context.
- Native explicit editor Save remains functional: an unsaved temperature
  draft disappears without modifying saved bytes. Saving temperature0.6,
  top-p0.9 and max output1024 survives relaunch and produces those exact
  request values, with an ordinary stop. These are explicit test choices,
  not changed defaults. The existing shared Server/Spawn fan-out mirror
  normalizes to its already authoritative value1; the relevant source is
  unchanged. This is not evidence of an independent budget being lost.
- A real red/blue image is attached through the native file picker and
  answered correctly, followed by a real London clock call and correct
  image-history grounding. Runtime logs show the DFlash2 path and disk-backed
  restore. This does not qualify every native head, direct DSpark bundle,
  media format, cache-pressure condition or hardware family. Candidate native
  phase peaks32.610/33.111/28.895GB exceed target weights22.679GB; RAMFAIL.
  An auxiliary DFlash2 diagnostic emits a256-token length stop and60.5tok/s;
  it is not an ordinary-answer pass. Other unmeasured warmups remain gaps.
- Native Gemma boolean Thinking choices leave default-agent/server/model
  stores unchanged. A fresh chat inherits Off, the original retains On, and
  switching to Qwen exposes its distinct effort tiers before switching back
  restores Gemma On. Actual On/Off requests contain true/false; the fresh
  inherited request omits the value. Stop cancels a real generation and a
  new chat completes afterward. However, the first On answer leaks reasoning
  and a literal `<channel|>` into visible content. That row is a format
  failure, not a quality pass. A later On row has a separate reasoning section.
  Frozen pre-fix native On requests and an exact captured-input API replay
  are being compared; no parser cause or correction is claimed. No forced
  opener, output stripping, sampler change or prompt coercion is justified.
- Initial final-head CI passed nine checks and failed an old source-policy
  assertion requiring the global Thinking option store. The test-only
  correction instead requires semantic conversation storage, a selected-model
  guard and no agent/model/Server writes, retaining inversion/effective-state
  checks. Fresh local RuntimePolicySourceTests plus ChatModelControlsTests
  pass120 tests in2 suites,5.507s. Counts overlap prior component runs.
  The original CI log and every failed analysis/test iteration remain.

No release, normal-profile install, model download, OS grant, sampler default,
prompt/template change or physical M2/M3 qualification is claimed.

SOURCE EVIDENCE: ChatModelControls.swift, ChatSessionData.swift,
ChatHistoryDatabase.swift, ChatView.swift and FloatingInputCard.swift; guides
and ChatModelControlsTests.swift record the ownership and regression contract.

LIVE EVIDENCE: private sentry-inference-20261108/chat-session-controls/:
COMPONENT-QUALIFICATION1.json, CANDIDATE2-FAILURE-CAUSE-REVIEW1.json,
CANDIDATE1-APP-ARTIFACT.json, native-candidate1/GEMMA-QAT-TOOL-GATE1.json,
actual Activity payloads, UI captures, PID-matched logs and resource samples.
Additional receipts: native-ownership-candidate1/ captures00–48 and store
snapshots; SAVED-GENERATION-REQUEST-AFTER-RELAUNCH1.json;
GEMMA-THINKING-ON-PROTOCOL-FAILURE1.json; agent-matrix-candidate1/
MATRIX-REVIEW2.json and retained-runtime1/MANIFEST.json;
SEMANTIC-POLICY-COMPONENT-QUALIFICATION1.json; ci-watch1/
actual-test-core-job.log. These qualify only the named completed rows.
Remaining model/CI gates must be recorded before merge.
