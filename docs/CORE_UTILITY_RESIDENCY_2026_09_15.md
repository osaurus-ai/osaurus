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
