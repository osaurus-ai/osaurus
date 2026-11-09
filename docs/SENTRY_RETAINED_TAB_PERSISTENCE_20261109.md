# Retained Activity tab persistence wait investigation

Status: Candidate. Narrow retained-tab lifecycle matrix complete; CI pending.
Model quality/RAM qualification remains PARTIAL/FAIL as detailed below.
Entries below retain the chronological failures and superseded pending states.
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


## Native integration1 and the retained-title correction

Projection `57799c4ea37d9f4d90b0a54121e216fde3b1c331` passed **312/312**
unique tests in 18 suites (7.422 seconds), with all four private flags verified
in actual PID63900. Its fresh Release binary SHA-256 was
`86d8230c360e56a8bd6145da47c0714dbe1b1bb8200166d64ae8fe201b854002`.
No image-root override, telemetry key or Sentry DSN was used.

Closing the active Chat tab while Stop was visible detached a real run; it
continued with the agent showing Working and produced a completed retained tab.
This shortcut left a blank Chat window, so it is not claimed as closing the
whole window mid-run. Closing that blank window and reopening restored the
complete answer. Actual clock/tool continuation and a further timezone follow-up
settled, then normal quit/relaunch preserved their full history. Explicit Close
Tab with another blank tab remaining removed the retained key; it stayed absent
through another normal quit/relaunch, and the tab did not reappear. General >
Local Models > General remained usable. One immediate AX snapshot error
recovered on the next observation in 0.113 seconds; no app-crash claim.

Strict answer quality was **2/3**: the rainbow explanation and timezone recall
passed; the clock supplied the requested UTC+9 correctly but invented Sunday
while the actual native result said Monday. This is a grounding failure, not a
passing row merely because the requested offset was correct. Four model passes
reported engine decode 104.3/102.2/100.7/99.1 tok/s, separately from Activity
end-to-end 31.82/39.06/25.66/74.84 tok/s. Seven automatic Foundation generations
are retained separately. Peak sampled phys_footprint was 5,317,841,360 bytes
against 4,002,479,278 weight bytes: **RAM FAIL**. No model-family readiness.
See NATIVE-INTEGRATION1-QUALIFICATION.json and raw activity/UI/resource artifacts.

The UI rename saved the canonical chat title and normal Chat relaunch showed
it correctly, but retained-task metadata still held the original title. The
terminal preview is the original completed-run snapshot; no continuous-preview
contract is invented and that field is unchanged. Source inspection found
canonical rename/renameQuietly did not synchronize BackgroundTaskState.taskTitle,
while headless hydrateRetainedTask treats the retained title as the latest
explicit rename and can write it back into the canonical store.

The same canonical rename implementation, with only an unused isolated-owner
test seam added, reproduced actual headless title loss in **0/3** cases, with
12 failed title assertions: manual rename, generated title, and an already-equal
canonical title. Canonical rename first succeeded, then actual headless reveal
reverted the DB title to the old retained title. Timestamp and transcript
assertions passed. Exact binary, log, xcresult and uniquely named raw before/
after receipts remain in retained-title-sync/BASELINE1-REVIEW.json.

The candidate synchronizes a known retained owner after canonical rename and
before the quiet-rename equality return. It does not call renameTask recursively,
rewrite previews/transcripts, or change manual/automatic timestamp policy. A
peek at the already-created shared registry avoids initializing it (and reading
defaults) merely to rename an ordinary chat. Isolated dependency overloads keep
tests off the shared registry; the existing two-argument UI API is preserved.
The four title/ordinary-chat tests and full affected matrix are pending, followed
by a fresh Release UI repeat. No preference PR or merge-readiness claim yet.


## Current candidate qualification

Frozen implementation `7ac0fef8b37147539145ebd273caa826d6ea40b5` passed
**316/316** unique tests in 19 suites, zero skips, 6.073 seconds. The actual
xctest PID40985 carried all four private flags plus the unique evidence root.
After merging current main, only the picker evidence document conflicted; its
exact current-main version was retained. All production/test/build-input hashes
match the frozen candidate. Projection `f15ac0966c90b558e48983140774bbf52e7921bd`
then passed the same **316/316**, zero skips, in 6.415 seconds with actual
PID69893 environment verification. A preceding preflight exited64 because it
reused the existing xcresult path; zero tests ran and the old result was not
overwritten. The corrected invocation used a fresh result/observation path.

The fresh private Release app binary SHA-256 is
`4bf964711fc77fab625aafd8136fc3f42f3982cb419430295825be7d14890dd3`, bundle
`com.dinoki.osaurus.sentrytitles20261109`; app/runtime pins remain those above.
Local Gemma MXFP4 revision `da2cd74442e6f4f1a8d720a592b21c53c013093f` used its
installed generation config: temperature1, top_p0.95, top_k64, do_sample=true,
EOS [1,106,50], no repetition penalty or explicit output cap. The app omitted
explicit reasoning options and the installed template selected Thinking off.
No prompt/sampler/template/output/permission changes were made for this fix.
The app has no analytics key or Sentry DSN. Actual process variables and 26
private/zero normal Osaurus app-data handles were checked on first launch;
this isolates named app roots, not every OS subsystem.

Two complete native workflows passed the narrow lifecycle matrix: normal
streaming tab close/adoption, terminal restore through a reopened window,
automatic title, manual Rename/Save, normal quit/relaunch, full history, a
second real clock call after restart, a further follow-up, and explicit Close
Tab with another blank tab present. Both final restart/quit checks kept the
retained key absent and did not resurrect the tab. Both canonical histories
remain saved. Manual titles were observed in both canonical UI and retained
metadata. General > Local Models > General was usable. The initial Local
Models AX error recovered on the next snapshot; no app crash is inferred.

Answer correctness remains **8/10 user turns**: both rainbow rows FAIL. The
first leaked literal `<channel|>` markers and reasoning into visible content,
called osaurus_help with invalid topic dispersion, and misstated entry and
reflection order. The bounded repeat had no marker leak, but contradicted
itself about red light bending least and being refracted most. Four real
clock calls had exact requested timezone arguments/results before and after
restart; all four clock answers and four timezone follow-ups passed. No
quality cause is assigned to this persistence change, and neither failed row
is replaced by the repeat. No forced closers, output stripping or prompt
coercion was introduced. The protocol leak is an open separate investigation.

The first workflow's eight content-bearing engine passes reported
104.41/102.18/101.90/99.47/99.19/99.26/98.22/97.66 tok/s. Two additional
intermediate passes emitted zero tokens with Activity rate0 and are failed
empty-generation rows, not successful answers. The repeat's seven engine
passes reported 103.99/100.63/99.33/100.17/98.73/97.51/96.19 tok/s. Activity
end-to-end metrics differ and all 17 Gemma plus 22 automatic Foundation
generation records are retained. Activity session_id is nil: grouping these
rows by workflow uses the verified launch4 timestamp, not an invented ID join.
The initial summarizer's zero-row join is retained and explicitly superseded
by NATIVE-CANDIDATE1-QUALIFICATION-v2.json.

Initial detached resource samplers each stopped after one startup sample,
with no captured error or terminal row: those generation peaks are
**UNMEASURED**, not a low-RAM pass. A bounded repeat used tracked sampler
sessions, verified multiple increasing samples before generation, and
recorded 237/121 samples over 118.92/60.46 seconds plus actual process-exit
rows. Peak phys_footprint was **5,287,121,336 / 5,293,281,984 bytes**, exceeding
4,002,479,278 weight bytes: **RAM FAIL**. The repeat does not retroactively
qualify the earlier missing traces. All attempts and gaps remain documented.

SOURCE EVIDENCE: BackgroundTaskManager ordered immutable snapshot writer,
canonical-title synchronization, ChatSessionsManager canonical rename methods,
and AppDelegate existing bounded quit fan-out. Tests cover actual delayed
UserDefaults completion/main liveness, bounded drain, ordered rename/clear,
restore, manual/quiet/equal-title headless reveal, timestamp/transcript
invariants and ordinary chats without a retained owner. Request execution,
tool dispatch, parser and generation logic are unchanged; AgentLoop evals are
not claimed for this storage/title-only change.

LIVE EVIDENCE: private preferences-waits/retained-title-sync/
CANDIDATE1-APP-ARTIFACT.json, candidate1-focused-RESULT.json,
projection3-focused-RESULT.json, NATIVE-CANDIDATE1-QUALIFICATION-v2.json,
raw native1..6 AX/screenshots/preferences/history/activity, resources-native4/5,
and baseline/candidate title and delayed-store receipts. These qualify the
narrow persistence/title/normal-quit behavior; they do not establish cfprefsd's
OS cause, forced-termination/fsync durability, telemetry hot-read prevention,
protocol correctness, model-family readiness or low RAM. CI is still pending.
