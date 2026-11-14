# Telemetry consent hot-read wait

Status: candidate, not qualified or merge-ready. APPLE-MACOS-3QJ samples main
in run dispatch through FeatureTelemetry.agentRun > TelemetryService.track >
consent > UserDefaults.object > cfprefsd IPC. The sampled path does not explain
the OS daemon's latency. No system preference daemon is stopped or altered.

Old exact production service with injected isolated defaults passed10/11 tests
in two suites; the one liveness case failed four assertions. It performed four
more preference reads across event/consent/quit queries and blocked both call
and main pulse for1.2570/1.2572 seconds under a single1.25s emulated read.
The same binary replay reproduced1.2548/1.2549 seconds. Baseline3/4 process
flags were configured but their actual PID was not captured; named injected
defaults suites provide their own isolation. No whole-process isolation claim.
New sidecars explicitly record the real test PID and only five named nonsecret
variables for direct comparison. Earlier two compile failures and the minimal
Swift6 object-compilation capture reproduction are retained; zero tests ran
in those failed builds. Typecheck alone missed the sending-closure error.

Apple documents [individual-key KVO and thread-safe UserDefaults use](https://developer.apple.com/documentation/foundation/userdefaults).
A first payload-only KVO cache was rejected before product application: two
real concurrent Foundation writes can resume an older grant callback after a
later decline returned, leaving the cache true while the store is false.
The raw controlled schedule is retained. No consent or sampling policy was
changed to hide that failure.

The candidate subscribes lazily before the initial read. A separate recursive
refresh lock serializes the infrequent current-value reads/publications, so an
old callback rereads the actual store instead of publishing its stale payload.
The snapshot lock is never held over preferences I/O; event/consent queries
only copy Bool?. The exact revised helper passed11/11 Foundation probes,
including stale-grant replay and a snapshot query while a refresh read waits
1.25s. These helper probes are not the actual-service or native proof.

The keyless early returns must still perform no preference read. Existing
started gating, undecided/granted/declined semantics,64earliest FIFO buffer,
explicit local grant flush, local decline clearing, external-change gating
and returning decisions are unchanged. External grants do not invent a new
buffer flush. Initial queries and explicit preference changes still read or
write synchronously; this change targets steady-state event dispatch, not
all preferences IPC or startup liveness. Event emission/transport and
model/generation/parser configuration are unchanged.

SOURCE EVIDENCE: TelemetryService.swift preference observer/snapshot and
unchanged track/setEnabled policy; TelemetryConsentPreferenceTests and existing
TelemetryServiceConsentTests.

LIVE EVIDENCE: private telemetry-consent-hot-read/BASELINE3-REVIEW-v2.json,
baseline3/4 logs/xcresults/binary, telemetry-consent-kvo-probe3/4 and exact-helper
comparison artifacts. Actual candidate suites, full affected matrix, fresh
Release Privacy/Chat/navigation/restart and consent behavior remain pending.
No telemetry PR or incident-specific prevention claim yet.


## Candidate qualification and remaining runtime failures

Frozen implementation `9a9d931ad29324593beb98f2b5dcdd750941307a` passed
**322/322** unique tests in20suites, zero skips,6.259seconds. Actual PID26378
contained all four private flags plus the evidence root, independently matched
by the test's ProcessInfo sidecar. The slow-store arm was not reached: event/
consent/quit queries performed zero further store reads; call/main pulse were
0.000043/0.000100seconds. After integrating merged main, head
`2526929ab27a01af64da484345d486dd8090268a` had an identical full tree and
repeated **322/322**, zero skips,6.423seconds with the exact same test binary
and actual PID31181 flags/sidecar verification. No assertion or timeout change.
The revised exact helper also passed32/32 quiescent concurrency trials across
2,048 real Foundation writes.

The fresh private Release binary SHA256 is
`7766946871a434e2e895e1a858ecda2936c9837d57832f57702507d371a6c516`, bundle
`com.dinoki.osaurus.sentryconsent20261109`. Build inputs stayed unchanged.
Runtime remains `1bcd74ad182103a3b83941f61e57ee0bac23b330`; Aptabase remains
`a55267506ca9e9413e242cff00309f91bda16679`. The app has no analytics key or
Sentry DSN. Native proof covers the actual consent getter, control, external
change and persistence; it does not claim live external event delivery or
started-SDK native agent dispatch. The actual started-service event gate is
covered by the delayed-store/capture-sink runtime fixtures.

Actual Privacy initially showed usage Off, manual On survived General/back
navigation and normal quit/relaunch. With the app still running and its consent
cache initialized, an external defaults command changed only this private
bundle's key to false; Privacy showed Off on re-entry and the stored value
stayed false. Manual On then Off survived navigation, normal quit/relaunch,
actual Privacy Off and final quit. The setting autosaves through its existing
onChange handler; no Save button is invented. Terms were not accepted and
no OS grants were made. All three app PIDs and tracked samplers exited. First
launch had26 private app-data handles and zero normal Osaurus data handles.
These are named-root checks, not isolation of every OS/model-discovery path.
The default discovered-model count grew1to4; active chat remained Gemma.

The local Gemma MXFP4 bundle revision remains
`da2cd74442e6f4f1a8d720a592b21c53c013093f`. Its generation config supplies
temperature1,top_p0.95,top_k64,do_sample=true,EOS[1,106,50]. No repetition
penalty or explicit output cap was supplied. Captured generation{} omitted
reasoning overrides; the installed template selected Thinking off. No
prompt/sampler/parser or generation behavior changed in this PR.

Strict answer quality is **1/4**, requested clock execution **1/2** and
timezone follow-ups **0/2**. The first clock request failed the existing
required-tool contract, with get_current_time offered but no call executed.
Its follow-up invented an America/Los_Angeles result. After restart, the
Europe/London call executed with exact args and typed JSON,74ms, and the
answer gave the correct+0offset. The next follow-up nevertheless claimed
America/Los Angeles. Actual London tool-result content is present in the
app-captured follow-up request, together with existing LA user clock metadata;
raw prepared model IDs/logits were not captured, so the cause is unassigned.
The failed turns remain intact and are not replaced by the later call.

Five Gemma attempts were recorded. Four stats-bearing passes reported engine
103.54/103.42/101.88/101.76tok/s, separately from Activity end-to-end
26.25/39.46/44.99/80.16tok/s. The initial failed request omitted output tokens
and tok/s: that row is **BLOCKED for metrics**, not assigned zero or counted
as a successful generation. Seven automatic Foundation generations and71
embedding operations are retained separately. Embedding rows are not text
generations. Failed-completion usage preservation is a separate investigation;
no successful completion is fabricated to hide a tool-contract failure.

Tracked phys_footprint peaks were **4,993,307,712 / 5,345,530,152 bytes**
for the two generation processes versus4,002,479,278weight bytes: **RAM FAIL**.
Their1,337/873samples span673.26/439.42seconds with actual process-exit rows.
The final settings-only process had62samples and635,127,872bytes peak. No
model-family, cache-topology, long-prefill UI, low-RAM or release-readiness
claim follows from this consent change.

SOURCE EVIDENCE: TelemetryService.swift unchanged event/buffer/explicit-write
policy plus the lazy observed preference; TelemetryConsentPreferenceTests
and TelemetryServiceConsentTests. Initial-query and preference-change IPC
remain possible; this targets per-event consent reads on the dispatch path.

LIVE EVIDENCE: private telemetry-consent-hot-read/
CANDIDATE3-FOCUSED-QUALIFICATION.json, INTEGRATION4-FOCUSED-QUALIFICATION.json,
CANDIDATE3-APP-ARTIFACT.json, NATIVE-CANDIDATE3-QUALIFICATION.json, complete
activity/history/requests, native1..3 AX/screenshots/preferences/resource traces,
and rejected-design/failed-build/baseline receipts. Broader runtime qualification
remains PARTIAL/FAIL; scoped CI is still pending.
