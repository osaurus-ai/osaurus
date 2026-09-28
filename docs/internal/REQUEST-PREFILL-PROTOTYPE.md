# Request-owned prefill progress

Current status: the request store and wiring patches match those in integration
`1416f458a`, whose rebuilt full core passed 249 selected test methods / 260
invocation rows (zero failures or skips). Ownership/wiring contributed 10 methods
/ 14 rows; adjacent coverage 190 / 194 and capabilities 49 / 52. This is selected
suite proof, not an entire-suite result. No model was loaded for these tests.

Twelve of fourteen changed Swift files are byte-identical to that integration;
ChatView and NativeMessageCellView also contain unrelated integration changes.
The narrow branch retains only the prefill changes and is stacked on #2923,
which depends on runtime pin #2917. Its own exact-head CI and fresh app GUI proof
remain open. Legacy remote consumer coverage is deterministic only, with no live
remote-server proof. The original manager baseline separately reproduced
cross-request clearing, overwriting and resurrection.

The adapter registers a fresh generation handle with the actual sessionId before
submission. PreparedStream carries it to the mapper. Mapper events assign one
sequence, update the owned store, and carry that same identity and sequence through
the native prefill hint. First output, completion, stream drain and cancellation
finish only that handle. Adapter gate-acquisition failure also finishes it.
Updates never register entries, so delayed hints cannot reopen completed work.

Native consumers deduplicate the direct/in-band path. Legacy remote progress is
bound once to its consuming stream and current chat; first tool name, envelope,
arguments, completion, reasoning, text or stream exit closes that scope. Invalid
legacy counts cannot create a queued entry. A newer same-session request can
remain active while an older request finishes or receives a delayed event.

The displayed session ID flows from ChatSession through IsolatedThreadView,
MessageThreadView, MessageTableRepresentable and CellRenderingContext into
NativeTypingIndicatorView. Changing sessions forces cell refresh even when block
IDs and theme are unchanged. The view observes the emitted entry dictionary and
selects only the exact session's newest active foreground request. Selection is
a read operation. Run-progress liveness uses the same session scope.

Existing coarse model-loading and warmup side-channel UI remain separate; this
change does not claim request isolation of those older status systems. Background
warmup suppression is preserved; unowned warmup token counts cannot supply a
chat badge or prefill liveness state. Coarse loading remains available. Media encoding still has no dedicated progress
stage, and complete still follows final GPU submission rather than a new GPU
completion fence. No timer generates model progress.

Prepared tests include explicit A/B completion/cancel/stale-update sequences,
same-request queued-total discovery, sequenced Codable duplication and invalid
frames; actual mapper text/reasoning/tool envelope/tool call first output;
consumer cancellation; actual native hint round-trip; legacy remote first-output
closure; and real NativeTypingIndicatorView same-theme session selection. Store,
mapper, receiver and native view tests use isolated progress state. These tests passed against the rebuilt integration core identified above. The two new suites contain ten
methods and fourteen parameter-expanded rows, including an unrelated suppressed
warmup while the native view selects a missing session.

Before merge: complete exact-branch CI and integration checks, then exercise two real chats with same-model batching, switch the
visible session, cancel one during prefill and verify the other counter/output
continues. Capture visible progress before first output, model/source identity,
cache telemetry, natural-stop multi-turn output and tokens/s. This is not a
Sentry crash fix or a cache/performance claim.
