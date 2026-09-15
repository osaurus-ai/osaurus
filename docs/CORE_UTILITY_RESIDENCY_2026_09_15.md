# Core utilities must preserve resident ownership

Status: regression reproduced; focused correction tests passed. Native source
ownership checks completed on a755, with a failed history continuation retained.
Combined RAM-branch verification and reporter-hardware confirmation remain pending.

## Failure mechanism

Automatic titles and follow-up suggestions call `CoreModelService.generate`
with background load intent. Its `GenerationParameters` previously inherited
`requestSource = .httpAPI` and `preserveExistingResidencyOwner = false`.
`MLXService` forwards those parameters to `ModelRuntime.generateEventStream`,
which assigns the resolved source to `lastUseSource`.

That changes a chat-owned resident to API-owned after an internal utility
request. Window-close acceleration skips non-chat owners.
`ChatResidencyHandoff.unload` also checks ownership before reclaiming a parent.
The reporter's title, suggestion, and Core Model settings are unknown; this
mechanism is not a confirmed explanation of their M4/16GB admission refusal.

History: #1901 added source-sensitive close cleanup; #1994 carried the default
HTTP source through core utilities; #2586 added auxiliary cache intent without
enabling source preservation. This interaction predates the current vision
processor changes.

The correction sets `preserveExistingResidencyOwner` for core utilities. A
subsequent genuine API request still claims API ownership. Background-load
refusal, leases, handoff ownership tokens, RAM admission, generation settings,
and SSD cache lifetime retain their existing contracts. In particular, source
preservation does not bypass the separate sharing check for child handoff tokens.

## Executed regression

Base app source: `e326a42086ebd3749bfa870ed9f2f540c044a8c7`.
Engine pin: `441d9a8e8df19f4c364b50903cbc62b4059639c9`.
The pre-fix patch adds an injectable local backend and exercises the actual
core router, then the runtime ownership resolver, for both background and
interactive requests and all ten request sources. This is deterministic
routing evidence, not a model inference test.

- Debug `CoreModelServiceFallbackTests` and `ResidencyIntentTests`: 23 tests,
  22 passed, one failed with 20 ownership assertions. The negative API control
  and existing residency suite did not fail.
- Raw log: `SWIFTTEST_UtilityResidency0915__050326.log`.
- Result: `utility-residency-red-debug.xcresult`.
- Source: `utility-residency-red.patch` and
  `utility-residency-red-source-hashes.json`.
- Two earlier Release attempts failed before executing assertions: missing
  testability, then DEBUG-only test hooks. Neither is behavioral red evidence.
- Evidence directory:
  `/Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14`.

The post-fix Debug run passed all 23 tests in both suites, exit 0:
`SWIFTTEST_UtilityResidency0915__051138.log` and
`utility-residency-green-debug.xcresult`. The exact patch is
`utility-residency-green.patch`. Peak tracked footprint was 8.56 GiB, swap
remained 7.00 GiB, and supervisor cleanup found zero remaining owned processes.
CoreData XPC warnings occurred in both red and green runs and are retained in
the logs; they did not prevent assertion execution.

A separate fresh Release app is required for native verification; Debug unit
results cannot substitute for it.

## Native comparison still required

Test both automatic titles/suggestions disabled and enabled with Core Model
set to “Use chat model.” Save via the actual controls, navigate back, and
verify persistence and effective requests. Add a dedicated Core Model control;
isolate title-only and suggestion-only if the enabled combination differs.

Use identical single-child, repeated fresh-chat, and sequential two-child
tasks with RAM safety on, handoff on, coexistence off, batch size one, and
same-model ceiling one. Record admission decisions, resident owners, lease
completion, footprint, pressure, swap deltas, cache state, and token/s. Check
idle expiry and window close without immediately reopening the app during
inspection; protect active and API-owned residents. Local 128GB results cannot
establish M4/16GB acceptance.

## Related live failures retained

The e326 Release baseline completed two isolated native UI runs. Idle expiry,
Keep Loaded changes, and accepted 30-layer disk restore were observed, but
window close did not shorten the sampled deadlines with utilities enabled.
The inspection mechanism could reopen the chat, so causal isolation is pending.

A later LFM image-history regeneration returned Red for the latest blue image.
Both saved image attachments decode to exactly the original fixture pixels;
`combined-ui-persisted-media-pixels.json` records that comparison. The wrong
reply remains a failed row pending matched cold versus restored requests.
Neither the ownership correction nor a successful disk restore proves media
history correctness.

## Corrected native ownership comparison

Release app `a755a8a1ca21f2d6a05ad7d4de8bf224f804675f`, engine441, binary
SHA-256 `5e61e8dbc35c4f93f9b1ef23b8b1cd9ecd04c1fa3196e5d93182a9e59d0ab06b`.
Exact cached Gemma4 E2B 8-bit snapshot433003a1e3fbfd10819ad15179d5e3c4d02d7ea7
on Apple M5 Max128GiB. Core Model displayed Use chat model. Both utility
toggles were changed in Settings, revisited, and visually captured.

- Utilities off: exact initial and follow-up replies; 97.4/94.0tok/s. A
  regeneration returned the same code at96.1tok/s. Close All at12:32:11Z
  unloaded the model before its12:32:18Z idle deadline.
- Utilities on: exact initial reply at88.3tok/s; actual title and suggestion
  requests completed and their results were visible. Close at12:34:10.632Z
  unloaded by12:34:11.006Z, before the12:34:21Z deadline.
- The enabled follow-up returned200 instead ofUTILITY-ON-OK at94.0tok/s.
  This is a failed history row. Initial status strings differed between the
  two configurations and no random seed was fixed, so it is not causal proof
  of utility-induced corruption. Preserve and investigate it.
- Genuine API request: API-OWNER-OK, stop,95.2744tok/s. Closing chat at
  12:36:34.113Z did not accelerate its12:36:43Z idle deadline; unloaded at
  12:36:43.718Z.
- The UI displayed Thinking Off throughout; do not describe this as an
  independently verified default-thinking contract. Sampling and utility
  generation parameters are retained in the runtime log.

Evidence: `utility-a755-native-comparison-progress.json`,
`combined-ui-run3-measurements.jsonl`, `combined-ui-run3.oslog`,
`utility-a755-{off,on}-settings*.png`, corresponding turn/follow-up captures,
and `utility-a755-api-owner-response.json`. No screenshot is committed.
The bounded process exited0; tracked footprint peaked2.29GiB and cleanup
found zero owned processes. These are small-turn rates, not benchmarks.

## Integration boundary

The a755 build did not contain PR#2752. Its source8229e5e05971bdb921f75860331a84dc835a17b7
adds fresh host sampling, capacity/budget/cancellation fixes and13 deterministic
RAM eval cases. It is now being integrated for combined qualification.
Neither a755's ownership results nor #2752's earlier standalone results replace
tests/evals/native delegation on that combined source. The reporter's measured
2,442,035,200bytes remain below the documented reserve-plus-child cutoff;
preserving source ownership alone does not change that arithmetic.

## Core Model restart regression found during combined proof

Combined source019294bfab48a74e1b885af7f20297aaa522c34c built as Release
(binary61fbd9ac5b3b05205a45b8405fbf15e668f3e2f181eda40b5ef26294d3eca866).
The actual General control was cleared to Use chat model, revisited, and then
Osaurus was quit and relaunched. It reverted to foundation (unavailable).
`core-fallback-explicit-before-restart.png` and
`core-fallback-after-restart-failure.png` capture the native failure. Saved JSON
omitted coreModelName, making the explicit choice indistinguishable from a
legacy file that still needed migration. Both utility toggles remained on.

The correction persists an explicit null for the chat-model fallback; missing
legacy keys still migrate. Other fields use the existing ChatConfiguration
encoder. The regression exercises actual save/reload twice for fallback,
local and remote Core Model choices, with conflicting legacy memory.json.

SOURCE EVIDENCE: AppConfiguration.PersistedChatConfiguration and
chatJsonNeedsLegacyMigration; AppConfigurationMigrationTests.savedCoreModelChoiceSurvivesReload.
LIVE EVIDENCE: SWIFTTEST_CoreFallback0915__055416.log and
core-fallback-green-debug.xcresult: 42/42 tests in AppConfigurationMigrationTests,
CoreModelServiceFallbackTests and ResidencyIntentTests; exit0,12.77GiB peak,
swap6.94 to6.93GiB and zero owned processes after cleanup. The tested patch is
core-fallback-green.patch, based on019294. CoreData XPC warnings were emitted;
the assertions executed and all three suites completed.

At this checkpoint, status was PARTIAL: the persistence correction still required a fresh
Release build and the same native clear/relaunch test. The reporter's utility
configuration is unknown; continue both off and on. Repeated and sequential
native delegation on the final combined source is still required. No M4/16GB
acceptance or blanket regression-free claim is made.

## Combined Release comparison on 473a

SOURCE EVIDENCE: `473a3d98ab65d6e2c090f541390b58fe88f9e82c`, engine
`441d9a8e8df19f4c364b50903cbc62b4059639c9`. Fresh Release binary SHA-256
`da98a06a0df4e9b7236c40b3bf2a0c077e3505489d6adb43c152065dc44e0d85`.
The source includes RAM8229, utility ownership preservation, explicit fallback
persistence and the vision/idle changes. The following observations supersede
the pending combined/persistence rows above, not the retained history failures.

LIVE EVIDENCE: `core-fallback-473a-release-receipt.json`,
`combined-ui-run7.oslog`, `combined-ui-run7-measurements.jsonl`, timing and
rendered-prompt directories, `utility-473a-delegation-matrix.json`, and native
`utility-473a-{off,on}-*.png`/AX captures in the private evidence directory.
This is the same M5 Max128GiB host and Gemma E2B snapshot described above.
Native controls set RAM safety/handoff on, coexistence off, concurrent sessions
and same-model ceiling one, and each child's budget to2048tokens/2turns/120s.
The UI displayed Thinking Off. Bundle sampling remained temperature1/topP0.95/
topK64; title/suggestion services retained their existing explicit overrides.

For each configuration, three fresh single-child chats were followed by a fresh
SysAdmin-to-Writer sequential chat, with no restart or manual cache clear:

| Automatic titles / suggestions | Actual children | Child token/s | Follow-up |
| --- | --- | --- | --- |
| Both off, Use chat model | 5/5 exact summaries, in order | 24.3,30.0,33.2,29.6,28.8 | Exact two summaries,84.6tok/s |
| Both on, Use chat model | 5/5 exact summaries, in order | 29.3,29.3,29.0,30.4,28.0 | Exact two summaries,82.9tok/s |

Both sequential parents copied verbose tool-result JSON into their first answer;
the follow-up returned only the two requested codes. The enabled row produced
actual titles and four suggestion buttons. All child cards settled, Stop
disappeared, and input unlocked. Ordinary30-second idle unloading remained
active between chats; these are not exclusively warm-resident trials.
Explicit Core Model selection then Clear survived navigation, quit/relaunch
and actual General inspection as Use chat model; the off toggles also persisted.
Both-on relaunch confirmation remains outstanding at this checkpoint.

Close All at13:36:58.717Z unloaded chat-owned Gemma by13:36:59.118Z, ahead of
its13:37:03Z deadline. Physical footprint fell from2,364,115,800 to1,229,294,232bytes.
The first close attempt was too close to idle expiry and remains inconclusive.
A genuine API control returned API-OWNER-OK at95.3047tok/s; chat close at
13:38:03.128Z retained its resident until the original13:38:10Z deadline
(first empty sample13:38:11.517Z). Receipts:
`utility-473a-early-close-receipt.json`, `utility-473a-api-close-receipt.json`.
Run7 exited0, tracked footprint peaked3.37GiB, swap fell6.92 to6.89GiB,
and supervisor cleanup found zero owned processes.

CI job104393398811 on473a ran358 harness tests in44suites. Deterministic suites
recorded131passed/15skipped/146total,0failed/0errored, including RAMAdmission13/13.
The15skips are live ComputerUseLoop rows, not inferred passes. Log:
`ci-473a-test-evals.log`. Other CI jobs were still running at this checkpoint.

## Native follow-up tool-choice regression

With both utilities on and dedicated Core Model Qwen3-0.6B-8bit, another actual
SysAdmin child returned RAM_FIRST_OK at28.8tok/s. Background Qwen load requests
were refused while they would evict active/resident Gemma; suggestions fell
back to Gemma. Qwen subsequently loaded after Gemma idled. This is not a claim
that all background requests were refused or that a second model corrupted KV.

The next native prompt, "Return only the summary from the child that just
completed. Do not delegate again.", returned literal
`complete(summary="SysAdmin agent returned RAM_FIRST_OK as requested.")`
at85.1tok/s. This is a FAIL, recorded in
`utility-473a-dedicated-core-followup.png` and its AX capture.

SOURCE EVIDENCE: `ChatView` calls `ChatToolChoicePolicy.resolve` before request
construction. `containsCallableName` used substring matching, so "completed"
matched registered tool `complete`, resolving `.required`. The runtime's
existing required-choice path then added a function-call directive.
LIVE EVIDENCE: run7 rendered prompt
`prompt-1789479665281-12665-BatchEngine.generate-snapshots_433003a1e3fbfd10819ad15179d5e3c4d02d7ea7.txt`
contains the actual ordinary follow-up and the injected MUST-function-call
instruction. The failure is therefore a native request-policy error; it does
not establish a Core Model or cache corruption cause.

The correction matches a complete callable identifier, preserving explicit
calls/backticked names and escaping regex syntax. It does not change explicit
API tool choice, sampler defaults, the tool execution gate or model output.
New direct regression tests retain the exact failed native sentence, adjacent
word/underscore/hyphen negatives and explicit invocation positive controls.
RED:43tests,2failed with5assertion failures;
`SWIFTTEST_ToolNameBoundary0915__064927.log`, `tool-name-boundary-red-debug.xcresult`.
GREEN:43/43 in3suites, exit0,8.55GiB peak, unchanged6.88GiB swap;
`SWIFTTEST_ToolNameBoundary0915__065516.log`, `tool-name-boundary-green-debug.xcresult`.
Both include CoreData XPC warnings; assertions actually executed. Patch receipts
are `tool-name-boundary-{red,green}.patch`, based on473a.

Coverage boundary: headless `AgentLoopEvaluator` supplies automatic tool choice
and does not exercise native Chat's inference policy. Existing RAM evals cover
admission and actual child ordering; they cannot substitute for this direct
policy regression and a fresh Release replay of the failed native prompt.
That replay and final-source qualification remain pending. Actual M4/16GiB
confirmation, retained earlier semantic/media-history failures and the wider
combined model matrix remain PARTIAL; no blanket regression-free claim is made.

## Current combined Release: d0d4, both utility configurations

SOURCE EVIDENCE: app d0d4b9aefa8d0ef85d6b7f9c832bc050ccdcb643,
engine 441d9a8e8df19f4c364b50903cbc62b4059639c9. The native Release SHA-256
is c8d334602e9f80ec04d6a6f0533f235a3d05c385fa22fbe80df3eedb2814da9c.
The exact callable-identifier boundary, utility ownership and explicit fallback
persistence changes were exercised together with RAM8229 and vision/idle changes.

LIVE EVIDENCE: tool-name-boundary-d0d4-release-receipt.json,
utility-d0d4-delegation-matrix.json, utility-d0d4-eight-parent-transcripts.json,
combined-ui-run8.oslog, combined-ui-run8-measurements.jsonl and the native
utility-d0d4-*.png/AX captures in the private evidence directory.

Both enabled and disabled configurations completed three fresh single-child
chats followed by a fresh sequential SysAdmin/Writer chat: ten actual children,
all exact expected digests in order. No restart or manual cache clear occurred;
the normal 30-second idle policy remained active. Core Model was Use chat model,
RAM safety/handoff on, coexistence off, batch/same-model ceiling one. The enabled
configuration and Core fallback survived a real restart. Child envelope rates
were 27.8–33.4 tok/s; these include child-run overhead and are not decode-only
benchmark rates. The host was M5 Max128GiB, not the reporter's M4/16GiB.

The previous literal complete(...) native failure was replayed with its saved
history and dedicated Qwen Core Model. It returned RAM_FIRST_OK at84.0tok/s;
the rendered prompt no longer forced a function call on the word “completed.”
Cancellation stopped a live turn (648 delivered tokens, task_cancelled), and its
follow-up returned CANCEL-RECOVERED at88.0tok/s with input unlocked.

With actual titles and suggestions generated, Close All at14:33:00.246Z
unloaded by14:33:01.171908Z, before the14:33:12Z idle deadline. A genuine API
request returned API-OWNER-OK at94.7657tok/s; closing chat retained that resident
until its original14:34:07Z deadline. This distinguishes utility preservation
from real API ownership. Disk-backed restoration accepted4691 tokens after
restart; the effective Gemma topology was3 KV plus12 rotating layers, paged off,
TurboQuant KV layers0. Run8 peak tracked footprint was3.09GiB; swap6.86GiB stayed
unchanged and supervisor cleanup found zero owned processes.

### Failed answer rows remain failures

The enabled pair's parent returned abbreviated result objects, then repeated
those objects on a strict codes-only follow-up (85.2tok/s). Both complete tool
results were in the rendered history. Retrieved Memory facts also contained
prior result objects. Disabling Memory and regenerating returned exact codes,
but the subsequent re-enabled regeneration had no Memory block, so it was not a
matched memory-content control. An explicit later recall request did retrieve
Memory and returned a literal osaurus_inspect expression without executing it.
Those failures do not establish an admission or cache-ownership mechanism.

The earlier wrong “200” answer reproduced with identical status-code history
under utilities ON, OFF after idle, and OFF while resident (94.8–95.3tok/s).
All three rendered235-token prompts contained the correct preceding answer.
Utilities are therefore not necessary for this failure. A direct first-answer
recall returned the original code; it does not replace the failed rows.
See utility-d0d4-matched-history-prompts.json and memory comparison receipts.

### Fresh harness and CI

The Xcode Release Evals binary SHA-256 is
 de02c4881a26e3d38bf303b97e5c8272594b60d435d497576a5d06b2241ca48a.
Receipt evals-d0d4-release-receipt.json names source, engine and MLX metallib.
The first launch failed before main because the Xcode CLI lacked Sparkle's
runtime search path; the isolated launch now points DYLD_FRAMEWORK_PATH to the
actual current build products. No app source or binary was changed to repair
the harness packaging environment; the failed launch log is retained.

RAMAdmission13/13, AgentLoopRAMAdmission3/3 (four single and four sequential
trials plus the three-fresh-chats sequence), RAMControls3/3 and both batching
suites1/1 each passed:21/21 cases. Actual child digests and zero post-chat
reservations were asserted. evals-d0d4-targeted-receipt.json and raw reports
retain every trial, throughput/cache telemetry, and unavailable early tool-step
throughput markers. The self-judge warning remains; deterministic RAM assertions
do not rely on an LLM judge. Peak sampled supervisor footprint1.75GiB,
swap6.83→6.81GiB, exit0 and zero owned processes. Per-case telemetry may observe
higher peaks between supervisor samples and is retained independently.

App CI34978506104 at exact d0d4 completed all seven jobs successfully.
Evals harness tests358/358; deterministic floor run131 passed/15 skipped/146
including RAM13/13. Skipped ComputerUseLoop cases are not passes.
The full live AgentLoop/Frontier and current vision matrix are tracked separately;
this checkpoint does not claim M4 acceptance, universal coherence or merge readiness.


### Full live scores and remaining coverage

The same d0d4 Release Evals binary completed AgentLoop with36 passed,7 failed,
4 skipped out of47, and AgentLoopFrontier with22 passed,17 failed out of39.
Combined:58 passed,24 failed,4 skipped out of86. The process exited1; this is
not a green full-matrix result. See evals-d0d4-agent-full-receipt.json,
evals-d0d4-agentloop-failures.json and evals-d0d4-frontier-failures.json.
The strict two-different-model batch failed because the generated job placed
`target_type` inside its payload; no child executed. Other failures include
file-edit formatting, task completion, clarification/tool selection, and
constraint retention. No matched baseline exists for every failed row, so
these are not all classified as pre-existing or unrelated to this PR.
The rejection-stops-run fixture still expects an immediate stop for not_found;
the inherited production path permits one typed path correction. Its original
failed result is retained without changing the assertion or score.

Canonical engine ProcessorTypeRegistryEvidenceTests from a393 were compiled
unchanged against current441 Release production objects. Both source revisions
have identical Libraries tree9ddbcd63b6dc6f54fb02b0f572fc5cb2a72b65a3.
Two test functions completed successfully: six parameterized selection rows and
one registration/construction row. See registry-current-tests/source-receipt.json
and SWIFTTEST_RegistryCurrent0915__080708.log. This is a local registry test,
not a substitute for engine CI or actual media generation.

The current installed-bundle inventory contains79 bundles,33 admitting images
from config, processor and tensor evidence. A resource-bounded matrix selected26;
seven larger bundles remained blocked by previously measured footprint.
Of eight completed seven-request image rows, six passed and two failed:
Ornith1.5-9B-JANG_2D gave the correct red background but violated the agent route's
one-word contract; ZAYA1-VL-8B-JANGTQ_K answered "one" on the agent route.
NemotronOmni4M, GemmaE2B8bit, Gemma12BQAT4M, LFM2.5VL3B4M,
MuseGlimmer30B4M and Ornith1.5-35BA3B4M passed their recorded cases.
The next NemotronOmni6M row was interrupted and17 later selected rows did not run.
See vision-d0d4-bounded/progress.json and individual numbered reports; there is
no final all-model report. Seven-request coverage includes changed image after
history but does not include a further recall turn after that changed image;
the earlier native latest-image failure therefore remains open.

The private supervisor stopped this matrix when kernel-free RAM fell below24GiB
(23.6GiB), with normal pressure and unchanged6.71GiB swap. It subsequently stopped
a native different-model handoff attempt at23.0GiB before a child result was
observed. The correct Qwen0.6B Writer selection was visually captured in
utility-d0d4-cross-model-writer.png/AX, but selection is not execution proof.
Both owned process trees were cleaned. Logs: SWIFTTEST_VisionBounded0915__081512.log
and SWIFTTEST_ToolNameBoundaryUI__081923.log. The isolated Writer remains Qwen0.6B
pending completion and restoration of this test; production agent settings
were not edited.

Separate direct-residency diagnostics are not qualified substitutes: their
EvalScope does not bind currentModelName/currentSessionSource, so exact-parent
reclaim correctly refuses the different-model case. Their still-resident
assertion also conflicts with the chatUI idle policy when no actual chat window
owns the model. See evals-d0d4-direct-residency-local.json and the corresponding
080807/081048 supervisor logs. Ownership guards were not bypassed to make these
old harness expectations pass.

Actual M4/16GiB acceptance, completed different-model native handoff, remaining
vision cases and unresolved semantic failures remain PARTIAL. No merge or
regression-free claim follows from these results.

A second native attempt, run10, used the unchanged kernel-free guard and the
already selected different-model Writer. It again stopped during parent load,
at23.8GiB kernel-free (08:32:37 local), before any child result. Peak tracked
footprint1.57GiB, swap6.71GiB unchanged; cleanup found zero owned processes.
See SWIFTTEST_ToolNameBoundaryUI__083217.log and combined-ui-run10 artifacts.
This third resource-guard abort, including the vision attempt, is not an app
admission failure. A concrete private-supervisor reclaimable-metric proposal
and nine-fixture/live-Mach-probe receipt are prepared but not applied; the
separate metric choice is awaiting user input. App admission and OS settings
remain unchanged.
