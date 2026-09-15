# Core utilities must preserve resident ownership

Status: regression reproduced; focused correction tests passed. Native verification of
the correction and reporter-hardware confirmation remain pending.

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

Status remains PARTIAL: the persistence correction still requires a fresh
Release build and the same native clear/relaunch test. The reporter's utility
configuration is unknown; continue both off and on. Repeated and sequential
native delegation on the final combined source is still required. No M4/16GB
acceptance or blanket regression-free claim is made.
