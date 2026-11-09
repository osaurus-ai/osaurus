# Retained Activity tab persistence wait investigation

Status: CANDIDATE / PARTIAL. No PR or merge-readiness claim yet.
Base source `a4b7e5ee69f7bf8824ee5e6c72aa3d474bb07b69`; runtime remains
`1bcd74ad182103a3b83941f61e57ee0bac23b330`, Aptabase remains
`a55267506ca9e9413e242cff00309f91bda16679`. No generation configuration,
model load, sampler, watchdog policy or permission change.

The actual APPLE-MACOS-3QK event samples main in streaming completion through
`BackgroundTaskManager.markCompleted` / `persistRetainedTabs`, then
`UserDefaults.set` waiting for cfprefsd IPC. APPLE-MACOS-3QJ independently samples
`TelemetryService.consent` / `UserDefaults.object(forKey:)` during run dispatch.
A sampled stack does not establish why the daemon was slow or prove prevention.

The unchanged production-class fixture injects a single bounded 1.25-second
store delay into separate isolated defaults suites. No system daemon is stalled,
restarted or killed. Telemetry track blocked the main actor for 1.357 seconds,
and actual streaming-end publication through Combine and the manager blocked
for 1.374 seconds; their main-queue pulses were delayed 1.358 and 1.376 seconds.
Both tests failed both liveness assertions (0/2, four issues). Actual caller
stacks, baseline sources, executable, log and xcresult are retained privately.

The candidate snapshots the existing filtered/sorted records on MainActor and
queues immutable encoded Data (or a clear) to one serial writer. The key, JSON
schema, terminal/showToast/nonmirror filter, order, transcript ownership and
restore behavior are unchanged. An older write must not land after a later
rename or clear. The existing quit fan-out drains this writer within its
existing 2.8-second group deadline; no synchronize() call or new timeout policy
is introduced. A drain timeout is logged and is not a persistence success.
Apple documents concurrent [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults) use and asynchronous disk persistence. It explicitly advises against [synchronize()](https://developer.apple.com/documentation/foundation/userdefaults/synchronize()).
Existing ConfigDiskWriter and Keychain use ordered workers plus bounded quit
drains. Queue drain proves submitted calls returned, not a forced cfprefsd disk
fsync or survival after forced termination.

Candidate1 moved the same delayed write off main: actual streaming completion
returned in 0.000123 seconds and the main pulse ran in 0.000213 seconds while
the worker still waited. Its first combined matrix was **24/28** in six suites,
with four failed cases/five issues. Telemetry intentionally remained unchanged
and failed two assertions. Two existing quick-reply cases timed out waiting for
a follow-up; the new ordering fixture counted four override callbacks instead
of its assumed three. All failures, source and the exact binary remain.

A native Foundation-only probe established that removeObject forwards to the
overridden set(nil). The corrected fixture counts Data writes and the explicit
remove, preserving the same three-logical-mutation, Original/Renamed order,
final-clear and relaunch assertions. Production writer behavior is unchanged.
One bounded paired run of the archived baseline and candidate binaries passed
all eight quick-reply tests independently (8/8 each). This does not explain the
earlier combined-matrix timeouts; that gap remains open pending the full matrix.
Candidate2 removes unrelated formatter-only changes and selects the actual nine
suite names, correcting the nonexistent AgentRequestLifecycleTests selector.
The full candidate2 run initially passed 43/45 in nine suites, with the same two quick-reply timeouts. All new writer/order/clear/drain cases passed. No skip or retry-until-green policy.

Cross-function review found the explicit defaults change observer in
ContentBlock.ActivityRollupSetting uses a lock-protected memo invalidation
callback with no MainActor/AppKit access. Real Settings/Chat interaction remains
required to qualify the actual UI, including worker notifications. No naive
telemetry consent cache is included: current-process notification alone cannot
preserve outside-process opt-out behavior, and immediate consent, ordering,
pre-decision buffer64, keyless behavior and returning-session state must be
proved before changing that separate service.

SOURCE EVIDENCE: BackgroundTaskManager snapshot/filter/write boundary and
AppDelegate existing quit fan-out; original methods and exact hashes in private
`preferences-waits/BASELINE1-REVIEW.json`, candidate runner receipts and sources.

LIVE EVIDENCE: private `preferences-waits/BASELINE1-REVIEW.json`, baseline and
candidate1 delayed-store/main-pulse JSON, exact caller stacks, both binaries,
xcresults/logs, native Foundation forwarding probe, and paired archived-binary
quick-reply receipts. Native Release persistence/clear/relaunch proof is still
missing. No model-family or incident-specific prevention claim.


## Test-launcher isolation correction

An actual negative-control test PID inspection found none of the four parent
private-root/Keychain variables reached xctest. Parent environment receipts alone
were insufficient. The named injected UserDefaults suites and explicit
ChatHistoryTestStorage fixtures still provide their own scoped isolation; a
whole-process private-root claim for those earlier runs is withdrawn. Actual
native-app LaunchServices environment/root proof is independent and unaffected.
Apple documents the TEST_RUNNER_ prefix in its
[environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference).

The same frozen candidate2 binary, same 45 tests/nine suites and unchanged
assertions/timeouts passed **45/45** in 0.704 seconds with explicit xctestrun
variables. Actual PID48899 contained all four expected private flags. This is a
controlled launch-configuration comparison, not a claim that one specific flag
or preflight stage caused the earlier timeouts; four flags changed together.
See ENVIRONMENT-A-RESULT.json, ENVIRONMENT-B-RESULT.json and
CANDIDATE2-ENVIRONMENT-REVIEW.json. Earlier failures remain retained.

One private diagnostic reused a hardcoded sidecar filename during the environment
negative control. The original candidate1 telemetry sidecar was overwritten.
Its exact failed log, xcresult, binary and numerical assertions remain intact;
the lost full sidecar is explicitly recorded in
EVIDENCE-SIDECAR-OVERWRITE-20261109.json. The replacement is identified separately;
it does not replace the original failed case or improve its score.

The next integration projection will include the separately-qualified picker
change and repeat the affected matrix with actual test-process verification.
Fresh isolated Release completion, retained-tab restore/clear/relaunch and quit
proof remains required. No preference PR, release or merge-readiness claim yet.
