# Cron date calculation across a repeated hour

Status: reproduced in the unchanged current-main app; correction awaiting full
component/build/native qualification and normal CI. No release action.

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

## Remaining acceptance

- Run full affected cron/schedule/consumer suites, including repeated-hour,
  half-hour and midnight rollbacks, spring gaps, UTC/non-DST controls, repeated
  matching slots, DOM/DOW OR, month boundaries, leap day and impossible dates.
- Build a fresh isolated Release and use the exact retained native fixture.
  Inspect the real Chat/Settings/Schedules controls, normal quit/relaunch,
  schedule preview and a subsequent ordinary multi-turn/tool conversation.
- Record current pinned vMLX long-prefill progress, rates, cache/resource and
  output evidence separately; no pin update or M1 performance claim is implied
  by a Foundation calendar correction.
- Retain failures and compare actual tested/final/CI/merged source trees before
  a normal merge. No release/tag/publish, original-profile deletion or OS grant.

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
