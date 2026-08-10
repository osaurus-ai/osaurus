# Settings-change warm-up / Prefill 0 regression

Status: `PARTIAL` — the Gemma 4 prompt-shape defect has an owning-layer fix,
focused tests, real OsaurusEval passes on Ornith, Gemma 4, and Bonsai, and the
current Osaurus UI-cache fix has passed the exact rebased isolated Release-app
lifecycle. The branch is rebased on current `osaurus/main` at `929f8c25`; the
remaining gate is fresh PR CI on the rebased head. The vMLX fix is
squash-merged at
`5aa5f160725187d327449628709d472add127541`, Osaurus is pinned to that exact
commit in every workspace/package lockfile, and the Gemma runtime row was
repeated on the merged pin.

## User-visible regression

After changing prompt-affecting chat settings, the model chip could continue
to represent an older warmed context. The next real turn then composed the
new system prompt, diverged from the stale warm-up, and visibly restarted at
`Prefill 0`. Reports reproduced this intermittently with Bonsai, Ornith, and
Qwen models. A user Stop could make the stale/cold transition more obvious,
but Stop was not the source of the prompt mismatch.

## Current-source trace

1. `DefaultAgentConfigurationStore.save` and `ChatConfigurationStore.save`
   publish `.appConfigurationChanged`.
2. `ChatWindowState` consumes that notification only to refresh its cached
   agent/system-prompt display state.
3. `ChatSession`'s equality-guarded prompt-shape pipeline listens for agent,
   tool, channel, folder, and model changes, but not
   `.appConfigurationChanged`. Therefore the composed preview is not compared
   after a chat/default-agent setting changes, and the warm fingerprint can
   remain stale.
4. `ChatWarmupPayload.fingerprint` already hashes the full rendered system
   prompt. The cache identity is correct once a fresh payload is composed; the
   missing link is triggering that composition and rewarm.
5. `invalidateWarmupAfterContextShapeChange` currently schedules an ordinary
   500 ms debounced warm-up. `ChatSession.send` intentionally cancels such a
   scheduled warm-up before dispatch and only waits for model switches or
   already-running warm-up generations. A send inside that debounce window can
   therefore cancel the only warm-up for the new prompt and start cold.
6. The first Osaurus fix changed a proven prompt-shape edit into required
   rewarm work, but the proof task is not created until the 80 ms
   `contextEstimateCancellable` debounce fires. `send()` checks
   `needsPreSendHandshake` synchronously. If the user saves Settings and sends
   before that debounce expires, the controller still reports the old warm
   state and the real send starts without reconciling the current rendered
   prompt.
7. The synchronous send-time reconciliation still failed in the real app
   because `ChatWindowState.refreshAgentConfig()` cleared both the send
   context and the old `cachedPreviewContext`. A SwiftUI redraw between
   Settings Save and the 80 ms observer then lazily cached the new preview.
   Both the observer and Send compared the new bytes to those same new bytes,
   so neither could detect that the green warm claim belonged to the old
   prompt.

## Required root fix

- Feed `.appConfigurationChanged` into the existing 80 ms, full-prompt
  equality-guarded preview pipeline. Unrelated settings must remain a no-op
  after recomposition.
- Represent a proven prompt-shape change as a required, tracked rewarm rather
  than ordinary speculative scheduled work. A real send may cancel unrelated
  speculative warm-up, but must wait for this current-prompt rewarm.
- Make `send()` synchronously reconcile the authoritative composed prompt shape
  before it decides whether the async warm-up handshake is needed. This must
  derive from current stores and composed bytes, not a blind delay.
- When an agent/default-agent settings refresh invalidates display/send caches,
  retain the prior prompt-shape preview only as the comparison baseline until
  the equality-guarded detector consumes it. A lazy UI read must not overwrite
  the old warmed shape before Send compares it.
- Preserve the existing model-switch, Stop, shutdown, RAM-safety, and
  single-resident-model rules.

## Permanent regression coverage

- Unit: warm revision A, mutate the session payload to revision B, trigger a
  context-shape rewarm, immediately follow the same cancellation path used by
  send, and require revision B to finish warming.
- UI-state unit: seed revision A through `ChatWindowState`, save revision B,
  flush the real configuration observer, force the intervening lazy preview
  read performed by the UI, and require synchronous pre-send reconciliation
  to detect B exactly once.
- OsaurusEval CacheProof: use three fresh sessions with system prompt
  revisions A, B, B. Turn 2 must not claim an incompatible stale full restore;
  turn 3 must restore the newly persisted B prefix from disk with typed,
  monotonic prefill accounting and coherent terminal output.
- Live Release app: change a prompt-affecting setting through Settings, return
  immediately to chat, send, inspect restored/remaining prefill counts and
  terminal UI state, then repeat in a new chat and after app restart.

No screenshot or video artifact belongs in Git history. Local visual evidence
is retained outside the repository.

## Current implementation

- `ChatView` now feeds `.appConfigurationChanged` into the existing
  equality-guarded prompt-shape pipeline.
- `ChatWarmupController` tracks prompt-shape rewarm separately from ordinary
  speculative warm-up. The send path may cancel speculative work, but it waits
  for the required current-prompt rewarm before dispatch.
- `send()` now performs exact current-store prompt recomposition before
  cancelling speculative work or deciding whether the required handshake is
  needed.
- `ChatWindowState` invalidates the authoritative send context after a
  settings/active-agent edit while retaining the old prompt preview solely as
  the shape-comparison baseline. This closes the lazy-redraw race without a
  timer, forced prompt, or global warm-up.
- `cache_proof.settings-prompt-revision` permanently scores three fresh
  sessions with prompt revisions A, B, B:
  - turn 2 must not restore the incompatible A state;
  - turn 3 must restore the newly stored B state from disk;
  - typed restored/remaining prefill accounting, closed reasoning, coherent
    output, disk stores, and hybrid companion evidence remain required.
- The eval harness gained exact per-turn cache tier/restore expectations
  instead of inferring correctness from aggregate counters.

## Source and focused-test evidence

- `ChatWarmupControllerPromptShapeTests`: 2/2 passed.
- All focused `ChatWarmupController` suites: 20/20 passed.
- Final standalone OsaurusEval contract gate: 15/15 passed across
  `AgentLoopCacheProofCampaignTests` (13/13) and
  `EvalCatalogManifestTests` (2/2) after the per-turn cache assertions and
  permanent case were added.
- Exact-pin OsaurusCore gate: 119/119 passed across the focused
  `ChatWarmupController` and `RuntimePolicySourceTests` suites.
- Final broad OsaurusCore warm-up/runtime-policy gate: 131/131 passed. This
  includes the exact `ChatWindowState` Save -> observer -> lazy-preview ->
  immediate-Send regression, prompt-shape signals, required rewarm,
  model-switch, Stop, shutdown, RAM-gate, runtime-residency, completed-run, and
  pin-policy coverage.
- Post-rebase focused regression gate: 48/48 passed from the current workspace
  source. It covers first-preview initialization, immediate prompt-shape
  reconciliation, every Stop/reset/handshake row, every queued-send
  persistence/privacy/regeneration row, and the exact merged-vMLX source
  contract. The result bundle reports 48 tests, 0 failures, and 0 skips:
  `/private/tmp/osaurus-settings-warmup-tests-derived-20260727/Logs/Test/`
  `Test-OsaurusCoreTests-2026.07.27_16-05-25--0700.xcresult`.
- vMLX `gemma4ProcessorPreservesTextOnlySystemContent`: 1/1 passed with the
  Xcode Swift toolchain after preparing the package Metal library.
- All related vMLX chat-message processor tests: 17/17 passed before the
  owning-layer fix was squash-merged.
- `prepare-evals-env.sh` no longer aborts under `set -u` when Xcode metallib
  candidates are absent.

## Real OsaurusEval runtime evidence

### Ornith 1.0 9B JANG_4M — PASS

Report:
`/private/tmp/osaurus-settings-prompt-revision-ornith9b-20260727-pass2.json`

- turn 1 / revision A: no restore; 217 prompt tokens; 1,142.6 prefill tok/s;
  364 ms TTFT.
- turn 2 / changed revision B: no restore; 212 prompt tokens; 1,125.6 prefill
  tok/s; 326 ms TTFT.
- turn 3 / repeated revision B: disk restored 205/212 tokens with 7 remaining;
  3,427.3 prefill tok/s; 217 ms TTFT.
- Run deltas: disk L2 +1 hit / +5 stores; SSM companion +1 hit; 38.2 decode
  tok/s; 2,654 MB peak physical footprint; nonempty visible output; reasoning
  closed.

### Gemma 4 E2B 8-bit — PASS after owning-layer fix

Merged-pin report:
`/private/tmp/osaurus-settings-prompt-revision-gemma4-merged-pin-v2-20260727.json`

- turn 1 / revision A: no restore; 215 prompt tokens; 300.2 prefill tok/s;
  867 ms TTFT.
- turn 2 / changed revision B: no restore; 210 prompt tokens; 3,083.8 prefill
  tok/s; 235 ms TTFT.
- turn 3 / repeated revision B: disk restored 209/210 tokens with 1 remaining;
  4,558.1 prefill tok/s; 220 ms TTFT.
- Run deltas: disk L2 +1 hit / +14 stores; 45.7 decode tok/s; 6,148 MB peak
  physical footprint; nonempty visible output; reasoning closed.
- Both the OsaurusCore and OsaurusEvals SwiftPM checkouts resolved vMLX to
  `5aa5f160725187d327449628709d472add127541` before this run.

Before the vMLX fix, the same strict case tokenized all three prompts to only
25 tokens and incorrectly restored 24/25 tokens after the settings change.
The cache matched the invalid sequence it received. The defect originated in
`Gemma4MessageGenerator`, which converted every nonempty text message,
including a plain leading system message, into a content-parts array. Real
Gemma 4 bundle templates read the leading system/developer content directly as
a scalar string before their generic content-parts branch. The fix preserves
scalar content for text-only turns and uses content-parts arrays only when
media is present; the strict eval was not weakened.

### Bonsai 27B Ternary JANG — PASS

Report:
`/private/tmp/osaurus-settings-prompt-revision-bonsai-fixed-20260727.json`

- turn 1 / revision A: no restore; 215 prompt tokens; 283.3 prefill tok/s;
  1,067 ms TTFT.
- turn 2 / changed revision B: no restore; 210 prompt tokens; 393.4 prefill
  tok/s; 783 ms TTFT.
- turn 3 / repeated revision B: disk restored 203/210 tokens with 7 remaining;
  1,300.1 prefill tok/s; 451 ms TTFT.
- Run deltas: disk L2 +1 hit / +5 stores; SSM companion +1 hit; 18.4 decode
  tok/s; 2,914 MB peak physical footprint; nonempty visible output; reasoning
  closed.
- With the eval's 1 GB disk limit, the run also logged one KV entry and its
  companion entry being evicted, reducing the cache from 1.229 GB to
  0.994 GB.

### Full CacheProof family matrix — one Bonsai finalization row remains red

These runs used the current PR source with paged RAM cache off and typed disk
L2 on. The JSON reports remain outside Git; PR reporting must preserve the
exact pass/fail count rather than flattening a family to “cache works.”

| Exact model | Cases | Decode tok/s mean (min-max) | Peak physical footprint | Disk L2 hits / stores |
| --- | ---: | ---: | ---: | ---: |
| `Ornith-1.0-9B-JANG_4M` | 11/11 pass | 31.66 (24.37-37.55) | 2,793 MB | +18 / +35 |
| `Bonsai-27b-Ternary-JANG-CRACK` | 10/11 pass | 14.52 (12.58-18.03) | 3,232 MB | +18 / +35 |
| `OsaurusAI--gemma-4-E2B-it-8bit` | 11/11 pass | 41.81 (29.38-45.76) | 6,422 MB | +18 / +116 |
| `dealign.ai/Qwen3.6-27B-JANG_4M-CRACK` | 11/11 pass | 12.51 (8.64-15.96) | 16,322 MB | +18 / +35 |
| `dealign.ai/Laguna-XS-2.1-JANG_4M-CRACK` | 11/11 pass | 33.09 (30.71-34.59) | 15,183 MB | +18 / +103 |

The Bonsai failure is
`cache_proof.cross-session-partial-disk-restore`. Its cache assertions passed:
turn 2 restored 298/319 tokens from disk, freshly prefilling the remaining 21;
disk L2 moved +1 hit/+3 stores; and the hybrid SSM companion moved +1 hit.
The row failed because turn 1 consumed its 512-token budget entirely in
reasoning, stopped for length, and produced no visible final answer.

A fresh-root three-trial replay made that distinction repeatable: 0/3 trials
passed, but every trial again restored 298/319 tokens from disk with 21
remaining and the companion hit. Both turns length-stopped with empty visible
output and unclosed reasoning. This is evidence of a Bonsai
reasoning/finalization defect, not evidence of an SSD reset.

The clean-main control reached the same result before this PR. A detached
`osaurus/main` checkout at `235027b2`, using its exact pinned vMLX revision
`d2f6f98265fabe2f017a9eb4af237b962154228a`, failed the row 0/3. The
representative trial restored 295/316 tokens from disk with 21 remaining,
moved disk L2 by +1 hit/+3 stores and the hybrid companion by +1 hit, then
failed because its cold first turn stopped for length with reasoning but no
visible answer. The report is retained outside Git at
`/private/tmp/osaurus-main-cacheproof-bonsai-partial-repeat3-20260727.json`.
This classifies the red Bonsai finalization row as pre-existing; the current
settings-warmup branch neither caused it nor converts it into a cache pass.

## Isolated Release UI findings — FAIL before current UI-cache fix

App:
`/private/tmp/osaurus-settings-warmup-release-derived-20260727/Build/Products/Release/osaurus.app`

- Bundle identifier:
  `com.dinoki.osaurus.settingswarmupproof20260727`
- Test root:
  `/private/tmp/osaurus-settings-warmup-live-root-20260727-2`
- Active real model:
  `OsaurusAI--gemma-4-26B-A4B-it-qat-JANG_4M`
- The built-in Osaurus agent warmed prompt revision A to a terminal green chip.
  Trace: 2,442 token cold warm-up, static-prefix hash
  `e06b309998e06fed`.
- In Settings -> Chat, the system prompt was changed to revision B. The user
  immediately returned to chat and sent `What is 19 plus 23?`.
- The model honored revision B and answered `forty-two`; the final answer was
  coherent, the Stop control disappeared, input unlocked, and the visible
  terminal metrics were TTFT 1.55 s / 67.8 tok/s / 8 tokens.
- Cache behavior failed: the chip still claimed warm at send time, the UI
  visibly progressed through `Prefill 512/2557`, and the trace recorded
  `prefill completed=0/2557` with no restore. Revision B had static-prefix hash
  `8eaa2ab9444677de`.
- Therefore this row is a settings-to-send ordering failure, not a slow SSD:
  the current prompt bytes reached generation correctly, but the send began
  before the debounced observer invalidated and rewarmed them.
- After adding synchronous send-time reconciliation, revision C still failed
  the same live row. The model answered `42` coherently at TTFT 1.45 s and
  66.6 tok/s, then finalized and unlocked input, but generation started at
  `Prefill 0/2556`. Trace hash `5e5b6ffddaf8de0c` showed no cache restore;
  disk misses increased from 2 to 11 and stores from 2 to 7. A later idle warm
  restored 2,556/2,563 tokens, proving disk L2 itself was usable.
- Source tracing of that second failure found the UI-cache race described
  above: the Settings observer erased revision B, and an intervening UI preview
  cached revision C before either the debounced detector or Send compared
  shapes.

## Isolated Release UI evidence — PASS on current UI-cache fix

Binary:
`/private/tmp/osaurus-settings-warmup-release-derived-20260727/Build/Products/Release/osaurus.app`

- Built from the current worktree at `2026-07-27 13:26:50`, using the dedicated
  bundle identifier and test root listed above.
- Runtime settings were read back from the isolated root: block-disk cache on,
  prefix cache on, paged KV off, legacy disk cache off, and safe-auto memory
  safety. This is an SSD-L2-only proof; no RAM prefix hit was credited.
- On app start, revision C restored 2,441/2,445 prompt tokens from disk.
- Through Settings -> Chat, the system prompt was changed to revision D and
  the arithmetic turn was sent immediately. The required revision-D system
  warm-up completed first. Because D intentionally diverged from C near the
  beginning, that warm-up correctly performed a cold 2,445-token prefill
  rather than reusing incompatible C state.
- The real user turn then visibly began at `Prefill 2445/2556`, and trace
  recorded `cacheRestore completed=2445/2556 detail=disk`. It answered `42`,
  TTFT was 0.47 s, decode was 69.1 tok/s, Stop disappeared, and input unlocked.
- A same-chat follow-up restored 2,563/2,674 tokens from disk, answered `42`
  at TTFT 0.50 s / 71.0 tok/s, and finalized normally.
- A fresh chat visibly entered warm-up, restored 2,444/2,445 system tokens from
  disk, then its first user turn restored 2,445/2,556. It answered `42` at
  TTFT 0.44 s / 69.1 tok/s and finalized normally.
- After quitting and relaunching the exact same Release app and isolated root,
  startup again restored 2,444/2,445 tokens from disk. Its first user turn
  restored 2,445/2,556, answered `42` at TTFT 0.47 s / 68.5 tok/s, and
  finalized normally.
- Current live trace artifacts remain outside Git:
  `/tmp/osaurus-prefill-debug-pass-revision-d-ui-20260727.log` and
  `/tmp/osaurus-prefill-debug.log`.
- The exact corrected source was also exercised with the detected
  `qwen3-0.6b-8bit` bundle in the same isolated Release app. With paged RAM off
  and disk L2 on, Settings revision E was saved through the visible UI and the
  immediate user turn restored 2,138/2,254 tokens from disk, prefilling only
  116. The model answered `44 + 19 = 63.`, the visible terminal metrics were
  TTFT 0.17 s / 312.2 tok/s, Stop disappeared, and input unlocked. The exact
  trace is retained outside Git at
  `/tmp/osaurus-prefill-debug-pass-revision-e-qwen-latest-20260727.log`.

### Exact post-rebase Release lifecycle

- The exact Release binary was built from Osaurus head
  `7306a4017e51d37839f2afe2a3c0e8b96462ea18`, rebased onto
  `osaurus/main` `929f8c25`, with vMLX pinned to
  `5aa5f160725187d327449628709d472add127541`.
- Binary SHA-256:
  `6c1a9992d70598b7ba499382e424eb436e9dc0463ab9991cf1a24cfbca24bc25`.
  The proof used bundle identifier
  `com.dinoki.osaurus.settingswarmupproof20260727` and isolated root
  `/private/tmp/osaurus-settings-warmup-live-root-20260727-2`.
- With paged RAM off and block-disk L2 on, Settings -> Chat changed the system
  prompt to revision G and the user immediately returned to chat and sent
  `What is 58 plus 27?`. The revision-G warm-up established the new
  2,447-token system prefix. The real user turn restored 2,447/2,558 tokens
  from disk, prefilling only 111; prompt throughput was 9,269.6 tok/s and disk
  L2 hits increased 0 -> 1.
- The visible answer was `85`, TTFT was 0.44 s, decode was 68.1 tok/s, no
  reasoning or protocol debris appeared, Stop disappeared, and input
  unlocked.
- The same-chat follow-up `What is 31 plus 12?` restored 2,565/2,676 tokens
  from disk, prefilling 111; prompt throughput was 9,486.2 tok/s and disk L2
  hits increased 2 -> 3. It answered `43` at TTFT 0.44 s / 69.1 tok/s and
  finalized normally.
- After quitting only the isolated proof app and relaunching the exact binary
  against the same root, startup restored 2,446/2,447 system tokens from disk
  with zero disk misses. The first new-chat turn visibly showed
  `Prefill 2447/2558`, restored those same 2,447 tokens from disk, and
  prefilling only 111 increased disk hits 1 -> 2.
- The post-restart answer was `91` for `What is 72 plus 19?`, with TTFT
  0.45 s / 63.4 tok/s. Stop disappeared and input unlocked.
- The current trace remains outside Git at
  `/tmp/osaurus-prefill-debug-rebased-revision-g-with-restart-20260727.log`.

## Remaining proof

- PR CI run `30304013300` passed `test-evals`, `test-cli`, `test-packages`,
  `test-statspack`, `swiftlint`, and `shellcheck`, but `test-core` failed.
  This row therefore remains open.
- One failure was a stale source-contract assertion:
  `ImageGenerationBridgeContractTests` still expects vMLX revision
  `d2f6f98265fabe2f017a9eb4af237b962154228a`, while the four actual package
  pins and the runtime-policy source tripwire use the merged, live-proven
  revision `5aa5f160725187d327449628709d472add127541`. The assertion now names the
  exact merged revision and passes.
- `reset_incomingWarmupSurvivesCancelledPreviousHandshake` timed out in the
  cold CI run. It now passes in both workspace test-plan executions together
  with every other Stop/reset/handshake row.
- Two queued-send persistence tests observed a nil session ID in the same run.
  Focused local execution reproduced those failures and additional privacy
  rollback failures. Source tracing found a real shared cause: the first
  preview composition has no older prompt shape to invalidate, but the new
  required-rewarm path treated that nil-to-initial transition like a Settings
  edit. An immediate first send was therefore moved into an unnecessary async
  handshake instead of synchronously appending and persisting its user turn.
  This also introduced an extra cancelled required-warmup task into the reset
  lifecycle test. Initial preview priming must update the estimate without
  creating required rewarm work; only a change from one established preview
  shape to another is evidence that a warmed prefix became stale.
- After that owning-layer correction, the original nil-session failures and
  cancelled-handshake timeout passed. Additional local-only queue-suite rows
  then exposed an independent test isolation defect: tests that inject a
  `ChatEngineProtocol` double did not activate the existing
  `forceChatEngineRouteForTests` seam. On a developer machine whose detected
  picker currently resolves an image model first, regeneration bypassed the
  injected cancellation double and produced `Enter a prompt to generate an
  image.` This is not a production route change; all injected-engine rows are
  made deterministic by selecting the existing test-only chat-engine route
  explicitly. All queued-send rows now pass in both workspace test-plan
  executions.
- Push the rebased, live-proven head and require a fresh PR CI run. Close this
  row only after every required check passes on that exact head.
