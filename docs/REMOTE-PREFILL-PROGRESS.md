# Remote prefill progress transport

Osaurus emits prefill telemetry as an SSE extension with empty `choices`.
The compatible parser previously decoded the extension but consulted only
usage and the first choice, so it never delivered progress to the native chat.

The candidate recognizes this extension only for the explicitly configured
Osaurus remote-provider type. A per-stream filter validates counts, binds one
remote ownership identity, rejects stale/duplicate sequences and switched
owners, and closes on completion or the first actual output. Foreign handles
are removed at this remote transport boundary; the native receiver creates a
fresh handle for its own chat session. The trusted local mapper/native-hint
path retains its original owner and sequence unchanged. Ordinary remote
provider parsing and visible content remain unchanged.

Five prepared tests (nine parameterized rows) exercise the actual remote event
parser and the native receiver, including a foreign handle matching an
unrelated local entry, duplicate/stale/switched identities, tool-only and
reasoning boundaries, malformed/suppressed progress, terminal frames and
ordinary-provider controls. Independent source review found no remaining
ownership blocker. Against the unchanged compiled app core at
`1416f458ab3991f972e2bc91258a77e25395e346`, four methods failed and the ordinary
provider control passed (eight failed rows, one passed, zero skipped),
reproducing the missing progress delivery.

The candidate passed all five methods and nine rows in a bounded harness using
its complete parser source, exact extracted new state/options, and the real
compiled core's chunk/progress/store/receiver types. The harness redirects type
references to the extracted state owner and substitutes a narrow dispatcher;
it does not compile the complete candidate provider service. No tolerances or
assertions were relaxed. Full-module provider selection, live remote-server,
GUI and network cancellation remain separate proof gates.
