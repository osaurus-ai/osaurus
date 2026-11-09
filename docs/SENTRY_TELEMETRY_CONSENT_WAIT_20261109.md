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
