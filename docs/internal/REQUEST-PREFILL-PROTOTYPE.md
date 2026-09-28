# Request-owned prefill progress prototype

Status: source/test preparation only; no production consumer uses this store yet.
No build, runtime, GUI, or model proof is claimed.

The store registers fresh per-generation identities, retains independent entries
for overlapping requests, ignores old/duplicate sequenced envelopes, and refuses
updates after finish. Completion or cancellation removes only its own entry.
Queued total discovery preserves that request's start time. Session projection
selects the newest active foreground request for the exact session, without
falling back to another chat, model, agent or unscoped request.

Tests adapt the observed baseline failure sequences to explicit ownership, check
serialized duplicate direct/native envelopes, stale completion and updates,
same-request total discovery, foreign identities, invalid counts, and independent
session selection. These tests are prepared but unexecuted.

Wiring still required: adapter ownership begin and error cleanup, mapper ownership
and sequence assignment, in-band hint identity, native consumer handling, and
actual typing-view session selection. GenerationParameters already contains a
sessionId string. The native table's CellRenderingContext currently does not;
the real chat session must flow from ChatView through MessageTableRepresentable,
cell context, and NativeTypingIndicatorView. Do not infer identity from active
agent or globally latest progress. This prototype is not a fix to the live HUD.
