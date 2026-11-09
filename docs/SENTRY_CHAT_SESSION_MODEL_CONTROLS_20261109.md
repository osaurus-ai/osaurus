# Conversation-owned reasoning and speculative decoding

Status: draft; native ownership checks, the full model matrix and CI are pending.

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
- The unchanged119-case AgentLoop+Frontier inventory is running. No current
  matrix score, native On/Off isolation, relaunch, queue, media or M2/M3
  qualification is claimed yet. No release, normal-profile install, model
  download, OS grant, sampler default or prompt/template change.

SOURCE EVIDENCE: ChatModelControls.swift, ChatSessionData.swift,
ChatHistoryDatabase.swift, ChatView.swift and FloatingInputCard.swift; guides
and ChatModelControlsTests.swift record the ownership and regression contract.

LIVE EVIDENCE: private sentry-inference-20261108/chat-session-controls/:
COMPONENT-QUALIFICATION1.json, CANDIDATE2-FAILURE-CAUSE-REVIEW1.json,
CANDIDATE1-APP-ARTIFACT.json, native-candidate1/GEMMA-QAT-TOOL-GATE1.json,
actual Activity payloads, UI captures, PID-matched logs and resource samples.
These qualify only the named completed rows. Remaining native/model/CI gates
must be recorded before merge.
