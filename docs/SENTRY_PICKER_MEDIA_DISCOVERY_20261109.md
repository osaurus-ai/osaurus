# Text picker readiness and optional media discovery

Status: scoped picker liveness observed; model-family qualification remains
PARTIAL. No specific Sentry issue is attributed to this wait.

An actual native Chat window reported that an AI was needed after local model
discovery had already finished with one usable Gemma bundle. A process sample
showed `ModelPickerItemCache.computeItems` awaiting
`ImageGenerationService.availableModels` in `imageModelsRoot`, blocked in a
directory listing. The main thread was idle. The documented
`OSAURUS_IMAGE_MODELS_DIR` override, pointed at an empty private directory,
allowed the same app/model/profile to open ordinary Chat. No onboarding,
generation configuration or sampler change was used. This isolation comparison
is a reproduction of the dependency, not a production fix for disk I/O.

The existing `prewarm` contract describes a fast first paint with foundation,
local and cached remote chat models. `ChatSession` subscribes to `$items` for
later catalog changes, and image/settings views do the same. Optional local
image/video discovery must not prevent those usable chat models from being
published. A sampled Sentry frame alone would not establish this cause.

The candidate separates completed chat/cloud and local media snapshots. Chat
rebuilds retain their existing coalescing; local media gets one independent
in-flight task with a coalesced follow-up. Media publishes through the existing
items stream after its actual scan. The old ready-bundle/video eligibility,
remote reasoning-catalog update, and foundation/local/media/remote order remain.
Completed snapshots remain visible during refresh. Explicit image download and
delete paths still await the media refresh they requested. No timeout, fake
availability, abandoned scan per caller, new model allowlist, generation default,
prompt, memory limit or permission change is introduced.

The affected fixture matrix covers blocked media versus chat/current-items
liveness, late media readiness and removal, retained snapshots and ordering,
coalesced refresh bursts, latest chat state, and invalidation during a stale
media scan. Fixtures instantiate a separate cache with injected catalog loaders;
they do not replace the singleton or claim actual filesystem/AppKit/model proof.
Existing picker/capability/tool-resolution/source-policy suites are also selected.

The complete focused rerun passed **267/267** unique tests in nine suites with
no skips, including restored-window selection when the media entry arrives late.
The first run is retained: **251/252** passed, with 32 assertions in one existing
concurrency test. Its supposedly stable catalog omitted Foundation initially,
then included it for every concurrent caller as the asynchronous Apple
Intelligence availability probe completed. The orchestration fixtures now use
fixed injected catalogs; the real notification observer and 32-caller equality
checks remain, with a new maximum simultaneous loader assertion of one. The
production availability probe is unchanged. Real bundle-classification coverage
is retained. The four new blocked-media tests passed in both runs.

A fresh isolated Release app exposes Gemma and opens its actual picker while a
simultaneous five-second sample still shows 4,354 samples in optional media
discovery's `imageModelsRoot` directory `open`. The main thread is idle. The
verified process has **no image-root override**. Actual General > Local Models >
General > Local Models navigation remains usable, with one installed Gemma.
Two immediate automation snapshots returned transient AX errors; the next
observations recovered in about 0.1 seconds. Those attempts are retained and
are not presented as crashes or main-thread hangs.

Three connected native user turns completed, including one real clock call with
`timezone: Asia/Seoul`, a successful native result and a settled tool card.
Stop disappeared and input unlocked each time. **Answer quality is only 1/3**:
the arithmetic answer was 31 instead of 29; the clock answer correctly included
UTC+9 but also invented an inconsistent 1,176-second offset. The follow-up
correctly recalled Asia/Seoul. Those failures are retained with their causes
unassigned. No prompt, output rewrite or sampler adjustment replaces them.
The four native model passes reported 107.17, 103.06, 102.23 and 100.55 tok/s.
Automatic Foundation title/follow-up generations have separate activity rates.
Defaults remain bundle-owned: temperature 1, top-p 0.95, top-k 64,
do_sample=true, think_in_template=false, no repetition penalty or native output
cap override. The verified public bundle revision is
`da2cd74442e6f4f1a8d720a592b21c53c013093f`.

Physical footprint reached **5,313,827,568 bytes** against 4,002,479,278 weight
bytes, failing the family low-RAM gate. No RAM improvement or complete model
readiness is claimed. This change repairs the observed readiness dependency;
it does not repair the filesystem's blocked open, the answer-quality failures,
or establish incident-specific Sentry prevention. Actual image/video generation
and all-AX responsiveness remain outside the demonstrated scope.

Source base: `a4b7e5ee69f7bf8824ee5e6c72aa3d474bb07b69`. The runtime remains
`1bcd74ad182103a3b83941f61e57ee0bac23b330` and Aptabase remains the audited
upstream `a55267506ca9e9413e242cff00309f91bda16679`; this is not the draft
rotating-cache consumer pin. The original native trace, failed attempts,
subsequent builds/tests, source hashes and actual proof receipts live privately
under `/Users/eric/vmlx-private-evidence/sentry-inference-20261108/`.
`cache-api-proof/chat-route-discovery.sample.txt` is the original wait trace;
`picker-media-discovery/` contains this candidate's iteration evidence.
`NATIVE-QUALIFICATION.json`, `focused-tests-attempt2-summary.json` and
`CANDIDATE1-ARTIFACT.json` give the exact scores, source/build identities and
limitations. The app SHA-256 is
`fdc67721981c44d56339f8053494bf97a1e91f63272a6332aa933f52269d2ad6`.
Its Release production source is byte-identical outside DEBUG to the final
candidate; only the test factory's DEBUG observer parameter changed afterward,
as recorded in `RELEASE-SOURCE-EQUIVALENCE-after-test-fixture.json`.
