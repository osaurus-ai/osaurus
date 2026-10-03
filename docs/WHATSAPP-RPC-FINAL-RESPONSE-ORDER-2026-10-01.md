# WhatsApp RPC final-response ordering

Status: source and regression preparation only. Native tests, app proof and the
required CI checks remain pending.

The independent transport candidate is based on public app main
`a64231c3e` with unchanged dependency manifests and lockfiles.

## Retained failing evidence

Osaurus PR2962, test-core job110404051127 failed
`WhatsAppRPCClientProcessTests.helperExitEmitsTerminationNotification()` after
0.050 seconds with `Caught error: .notRunning`. Neighbor tests
`timeoutKillsWedgedHelperSoNextCallGetsFreshProcess()` and
`shutdownTerminatesTheChildProcess()` passed in the same suite.

The retained CI failure remains a failed exact-head receipt until the changed source
passes fresh validation; neither focused proof nor source inspection makes app CI
8/8 or makes the cache-pin PR merge-ready.

## Concrete source cause

The scripted helper writes its valid quit response and exits immediately.
Previously stdout readability and Process termination each queued independent
actor Tasks. The termination Task could clear `readBuffer`, close stdin and fail
the pending quit request with `.notRunning` before the response Task executed.
The source order in the child does not order these independent actor hops.

The same unscoped callbacks could also clear a newly launched helper or prepend
old partial output to its frame buffer. The lifecycle was unchanged since
WhatsApp PR2290 (`e118cea31`, 2026-08-04); PR2854 (`ffbd07bf6`) only changed JSON
fragment encoding. Neighbor iMessage PR2674 (`92fb38a15`) already added process
generation guards, which this fix follows without modifying iMessage.

## Prepared change

A per-process output reader serializes nonblocking pipe reads and event publication
under one lock. Its AsyncStream yields already-read and termination-drained bytes
before the termination event; one actor consumer ingests them in order. This
resolves final responses before retiring the helper and failing remaining calls.
An open writer inherited by a descendant cannot hold the final drain waiting for
EOF. Each drain has 64 attempts; a final drain exceeding that bound reports an
explicit read error. POSIX read errors cause typed failure and scoped shutdown.
Cancellation closes the reader, finishes its stream, and makes queued callbacks
inert before touching a closed descriptor. Retirement drops the consumer task
handle without canceling the task: the finished finite stream drains naturally,
and its generation guard rejects remaining events. In particular a read-error
consumer can await helper shutdown without canceling its own exit wait.

Every reader, exit, timeout and buffer-overflow action carries the helper's UUID.
Old events cannot retire or contaminate a replacement. A request that observes a
dead child waits for that generation's ordered consumer before spawning again,
and rechecks generation after the actor suspension so another request's replacement
is preserved. Explicit shutdown retires ownership before awaiting child exit and
emits one termination notification, matching the neighboring iMessage lifecycle.

## Prepared regressions and remaining proof

- [ ] Run deterministic output-reader tests: termination before any
  readability callback; queued prefix plus termination-drained suffix; and
  cancellation followed by stale callbacks. Tests intentionally keep the write
  end open and use event order rather than sleeps as synchronization.
- [ ] Run process tests, including the original quit/notification failure,
  ten consecutive final-response/exit cycles, stale old termination after a real
  replacement answers, and stale partial output after replacement. Notifications
  use an AsyncStream barrier. The test harness now shuts down on thrown errors.
- [ ] Run the relevant full native core lane and retain exact source/pin
  and raw output, then establishes all8/8 required app CI checks on the delivered
  source before cache-pin merge.
- [ ] Run the existing receive/restart service tests with the in-memory fake
  transport. Keep fresh app integration smoke separate from a real linked-account
  claim; this regression gate does not require WhatsApp credentials.

No test skips, timeout increases for the RPC request, helper response delays,
Actions edits or retry-only workaround are introduced. The test trait bounds
event waits; it does not hide an RPC failure.

## Reproducing the scoped native gate

Use a Debug test build: the six scripted-process methods are guarded by
`#if os(macOS) && DEBUG`, and the executable override is also Debug-only.
The three output-reader methods use only local pipes. The process methods
install a temporary Bash fake helper while holding the shared configuration
test lock and restore the previous executable override afterward; no linked
WhatsApp account, real helper or network connection is
needed. Keep the model directory empty and use a fresh test root:

```sh
task_root="$(mktemp -d "${TMPDIR:-/tmp}/osaurus-wa-tests.XXXXXX")"
mkdir -p "$task_root/models"
env OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
  OSAURUS_TEST_ROOT="$task_root/profile" OSU_MODELS_DIR="$task_root/models" \
  swift test --package-path Packages/OsaurusCore \
  --filter 'WhatsAppRPC(ClientProcess|ProcessOutputReader)Tests'
```

Expect all nine methods: `delayedOldTerminationCannotRetireReplacement`,
`delayedOldOutputCannotContaminateReplacement`,
`timeoutKillsWedgedHelperSoNextCallGetsFreshProcess`,
`shutdownTerminatesTheChildProcess`, `helperExitEmitsTerminationNotification`,
`consecutiveFinalResponsesSurviveImmediateHelperExit`,
`terminationDrainsBufferedResponseBeforeExitWithoutWaitingForEOF`,
`queuedPartialFramePrecedesTerminationDrainedSuffix`, and
`cancellationFinishesAndIgnoresQueuedOldCallbacks`.

For Xcode, build Debug `OsaurusCoreTests` from the changed source, then select
the two suites with `-only-testing:OsaurusCoreTests/WhatsAppRPCClientProcessTests`
and `-only-testing:OsaurusCoreTests/WhatsAppRPCProcessOutputReaderTests`. Use the
one-worker and timeout policy in `make ci-test` for the full core gate. An old
test product does not prove the changed source; retain the exact source revision,
engine pin, method inventory and raw results for each gate.
