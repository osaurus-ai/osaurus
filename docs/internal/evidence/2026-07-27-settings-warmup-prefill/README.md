# Settings-change warm-up / Prefill 0 regression

Status: `PARTIAL` — the Gemma 4 prompt-shape defect has an owning-layer fix,
focused tests, real OsaurusEval passes on Ornith, Gemma 4, and Bonsai, and the
current Osaurus UI-cache fix has passed the isolated Release-app lifecycle. The
remaining gates are current-main integration and PR CI. The
vMLX fix is squash-merged at
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

## Remaining proof

- Integrate onto current `osaurus/main` and repeat affected tests if the
  rebase changes relevant files.
- Run Osaurus PR CI and only then close this row.
