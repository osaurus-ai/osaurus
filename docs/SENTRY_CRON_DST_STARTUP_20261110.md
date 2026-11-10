# Cron date calculation across a repeated hour

Status: reproduced in the unchanged current-main app; corrected components,
fresh Release and native startup/relaunch controls qualified. Normal full CI
and exact compiled/merged-tree verification remain required. No release action.

The new report describes an M1-family Mac with32GB on macOS27.0 hanging before
the interface appears. Its exact application version, report URL and process
sample have not been supplied. This document does not attribute that report to
a specific cause.

Two Sentry groups provide a closer lead than the older CoreML startup crash:
APPLE-MACOS-3GP and3MF have macOS27.0, MacBookPro18,1,32GB events about4.233s
and3.541s after process start on0.25.27. Both main-thread stacks run through
ScheduleManager.scheduleNextTimer, Schedule.consumedExecutionAnchor,
ScheduleFrequency.alignedAnchor/slotSnapIntervalSeconds and CronParser.nextDate.
CronParser.swift is byte-identical between the0.25.27 tag and current main
28f439b4527718a532d9cfc640deefc1fa6877e4. Matching hardware/OS and stack shape
does not identify the reporter or recover their saved expression/anchor.

## Confirmed cause and controls

The search advances an absolute Date, then reconstructs the start of its local
hour from year/month/day/hour components. During the second occurrence of a
repeated DST hour, that reconstruction selects the first occurrence. The loop
returns to the same instant indefinitely, so its existing five-year endpoint
does not bound execution. Initial minute truncation has the same identity loss
and can return a date before the reference.

Exact unchanged production-function subprocess probes retain six named rows:
UTC and an ordinary Los Angeles day return correct dates; the Los Angeles
repeated hour and an ordinary previous-day execution anchor time out; minute
truncation in the second repeated hour returns past times in Los Angeles and
half-hour-DST Lord Howe. Each timed-out child alone was terminated/reaped at
the declared three-second component boundary. No unrelated process was touched.

The isolated current-main Release app opens its fresh-profile Welcome window.
The same executable with one persisted cron schedule then freezes its main
thread at startup. Its actual native PID72523 has all six private flags, is
sampled at99.1%CPU, and its stack runs through ScheduleManager.scheduleNextTimer
into CronParser.nextDate. The actual CUA attempt to inspect that running app
times out after17.2994s. Its unresponsive main actor required SIGTERM of that
verified owned PID after capture; the resource sampler then exited normally.

The native fixture uses a future execution anchor immediately before the2027
rollback so no task is due or model work is dispatched when the correction is
tested. This is a valid persisted Date, not a changed clock or production
setting. The component baseline separately reproduces an ordinary past2026
execution anchor. The fixture and complete profiles remain retained.

## Narrow correction

Use Calendar's actual minute/hour intervals to retain the occurrence of the
supplied instant. Existing public nextDate(after:) still uses Calendar.current;
an internal calendar-taking overload allows deterministic tests without
mutating the process-wide timezone. Cron field grammar, day-of-month/day-of-week
OR logic, search horizon, calendar/day/month handling, scheduler execution,
agent settings, model/runtime/cache paths, dependency pins and release files
are unchanged. There is no worker-thread workaround or timeout hiding the loop.

The private two-truncation candidate returns the expected strictly-future
results for all six baseline rows. These are component observations, not yet
acceptance of the built app correction.

## Qualified correction and remaining CI gate

Tested source is d2d2b4aa5b35bcea91aa912875dbc084d052feee, based on main
28f439b4527718a532d9cfc640deefc1fa6877e4. The only product change is
CronParser.swift. No dependency, runtime, settings, harness or release change.
The Release and test builds resolved clean official vmlx-swift
1bcd74ad182103a3b83941f61e57ee0bac23b330 and Aptabase
a55267506ca9e9413e242cff00309f91bda16679.

The actual selected 59 suites reported 732 declarations: 728 passed, four
existing network opt-in skips, zero failures. The new parameterized calendar
test has 19 passing argument rows, plus two normal declarations. These cover
repeated hours, half-hour and midnight folds, spring gaps, non-DST controls,
the second matching slot, DOM/DOW OR, month boundaries, leap day and impossible
dates. Separately, an independent absolute-minute oracle agreed in 315/315
comparisons over ten timezones' 2026 transitions, five expressions and three
nonaligned reference offsets. All original failing baseline probes remain.

Three other Schedule-folder suites were not in the local selection:
NextRunSchedulerStorageReadyTests, ScheduleHistoryServiceTests and
ScheduleNextRunPreviewTests. Full normal core CI must cover them and the new
suite before merge; the local selection is not described as the full suite.

The fresh isolated Release uses exactly the retained failing fixture. Native
PID15683 now opened Chat and Settings/Schedules. Refresh, edit 09:00 to 10:00,
Save, restore 09:00, disable/Save and enable/Save all completed. The list showed
the correct next 09:00 occurrence across the fold. Normal quit and PID21030
relaunch retained the schedule and correct next date. Both samplers exited0.
No scheduled task was due or dispatched by the future-anchor fixture.

Through the actual model picker, OsaurusAI/gemma-4-E2B-it-qat-MXFP4 executed
get_current_time with exact UTC arguments, showed the tool result and a clean
visible continuation, then correctly recalled UTC in a follow-up. All three
model passes used empty generation overrides and bundle temperature1.0,
top-k64, top-p0.95, inherited Thinking Off. Decode rates were116.1,114.3 and
113.2tokens/s; restore/cache telemetry is retained. Physical footprint peaked
at5,288,367,240bytes versus4,002,479,278weight bytes: RAMFAIL, not model-family
or low-RAM readiness. No new AgentLoop/Frontier matrix was run for this isolated
calendar change; the preceding current-main119-case matrix remains56passed,
59failed,4skipped, with unassigned model/runtime/cache causes, not a green gate.

Only documentation follows the qualified source. Verify its non-document
projection, actual unfiltered CI test plan, compiled source/tree, terminal core
success and all normal checks before merging. No release/tag/publish,
original-profile deletion or OS grant.

## Separate bounded long-prefill observations

The same binary ran as PID32853 with a new private KV-cache namespace; the
complete original cache/profile stayed intact. OS/model/shader caches may be
warm, so this is not a cold-speed benchmark. Prefix and block-disk cache were
enabled, paged RAM KV disabled, memory policy safe_auto/slider2, and model
defaults unchanged. All seven actual Chat UI requests had empty generation
overrides. Twelve bundle files retained their identity/size/mtime and the
recorded config/template hashes after normal quit.

A39KB clipboard paste became the existing attached-document route. At21,852
tokens the model chose file_search without a working folder and did not answer.
That unsuccessful attempt and original blob remain retained. A separate direct
text-field route sent21,896tokens. Exact checks against both the source ledger
and untruncated request show only1/2 requested codes correct. Editing only the
question suffix returned0/2 correct. Both strict accuracy rows failed. An early
status update overstated their accuracy; the explicit correction and all raw
responses remain recorded. The subsequent growing turn correctly repeated its
previous answer, which still contained the wrong ledger value. No causal
cache/model/parser assignment or prompt/sampler workaround is justified.

The direct and edited requests restored1,797/21,896tokens despite their large
shared prefix. This does not prove long-prefix reuse. The growing follow-up
restored21,935/22,115tokens from disk. Actual decode rates across the six
completed passes were60.5,60.0,60.1,60.3,60.4 and112.0tokens/s; Activity's
end-to-end rates are kept separate. Rates are observations, not comparative
performance claims. Runtime stage events were observed; no intermediate
numeric UI prefill percentage was captured, so progress smoothness is unproven.

The larger46,899-token request was stopped while the trace still reported
prefill after a1,797-token restore, without decode-ready or a produced response.
Activity recorded499/cancelled; the lease drained, Stop disappeared, input
unlocked, and a fresh ordinary chat answered5+8 with13. There is no generation
rate for the cancelled no-output request. The recovery decoded at112.0tokens/s.
Normal quit and sampler exit0 completed. Peak physical footprint5,887,594,912
bytes fails the same RAM gate. These observations do not establish best speed,
long-context accuracy, all-family cache fidelity or physical M1/M2/M3 behavior.

PhysicalM1 proof and attribution to the new reporter remain unavailable.
Keychain-free native controls skip credential/network-plugin/sandbox startup;
they do not establish full production startup coverage or an Apple CoreML fix.
Related closed issue3076 and merged3078 address a different speech-load crash
loop and are not treated as this bug's cause or solution.

SOURCE EVIDENCE: CronParser.swift; Schedule.swift consumedExecutionAnchor and
slotSnapIntervalSeconds; ScheduleManager.swift scheduleNextTimer. Private
startup-m1-20261110/cron-component-baseline1/SOURCE-IDENTITY1.json;
os27-cohort-details1/REVIEW2.json; CRON-FIX-PLAN1.json.

LIVE EVIDENCE: same root/cron-component-baseline1/RESULTS1.json and
cron-component-candidate1/RESULTS1.json; native-controls1/APP-IDENTITY1/2.json,
LAUNCH1/2.json,00-empty-profile-welcome.ax.txt/.png,
cron-baseline-main-thread-sample1.txt,
CRON-BASELINE-UI-FAILURE-AND-OWNED-TERMINATION1.json and PROCESS-EXIT1/2.json.
All original compiled binaries, logs, profiles and samples are preserved.

SOURCE EVIDENCE: components1/QUALIFICATION2.json; native-build1/RESULT.json;
cron-calendar-oracle1/RECEIPT1.json; native-candidate1/APP-IDENTITY1.json.

LIVE EVIDENCE: native-candidate1/NATIVE-STARTUP-AND-QAT-QUALIFICATION1.json,
FIRST-LAUNCH-CONTROLS-QUALIFICATION1.json, both normal-exit receipts and
captures00-09; native-prefill-cold1/NATIVE-LONG-PREFILL-QUALIFICATION1.json,
all intermediate/closed SQLite/cache/profile snapshots, captures00-18,
QAT-BUNDLE-FILES-AFTER1.json and PROCESS-EXIT1.json. Screenshot path binding
records that the capture helper initially saved three new uniquely named
captures in native-candidate1; originals and unchanged copies are retained.


## Branch split during qualification

While the original PR3370 CI ran, teammate PR3366 changed main to Osaurus1.0
as15d4089fe83f52610e5414bea7388c87c4927da5. Its scheduling UI and managers
have changed substantially; the existing old-main native evidence cannot
qualify that different application. PR3370 is held draft rather than merged
using stale proof. All original source, CI, native and cache artifacts remain.

The reported0.25.x startup path is now maintained on classic. This clean
Classic candidate starts at0e7e4a0ccc237f40fdc3e06385a88055fbe979d0 and copies
only the two already-tested cron product/test files and this document. Its
CronParser, Schedule model/manager/views, Package.swift and package lock are
byte-identical to original28f439before this correction. No later D3/image
permission change, release script, workflow, appcast or pin is imported.
Fresh affected components, an isolated Release, the identical retained native
fixture and normal Classic PR/CI must qualify this integration before merge.
The original315oracle and exact parser regression evidence still apply to
unchanged file bytes; they are retained rather than rerun or discarded.

The new1.0 branch has the same original broken CronParser bytes, but its new
consumer paths require separate qualification. No1.0 readiness or live-user
upgrade/downgrade claim is made here; teammate release work stays untouched.
