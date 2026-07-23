# Prefill Queue Emergency Gate — 2026-07-22

Status: **PARTIAL / SCOPED EMERGENCY PROVEN-LIVE FOR BONSAI, GEMMA, AND
LAGUNA ROWS — the earlier scoped cancellation emergency proved that a cancelled
direct B=1 generation is drained before its process-wide solo lease is released,
and that cancelled/errored chat runs no longer schedule a hidden proactive
replay of the abandoned prompt. The current 2026-07-23 v3 Release proof adds
source-trace and Computer Use evidence that parsed local tool calls dispatch
without waiting forever for optional stats, Bonsai failed-tool turns do not
trigger the hidden completed-transcript warm-up, Bonsai/Gemma/Laguna restore
SSD-L2 partial prefixes with paged RAM cache Off, and Laguna Thinking On can
produce a separate reasoning row when the model emits non-empty `<think>`
content. TurboQuant, paged-RAM-on fallback, unsupported-family, AppleScript, and
full Settings-toggle rows remain PARTIAL until separately re-proven.**

Scope: shared Osaurus/vMLX request, warm-up, and cache lifecycle. This is not a
Bonsai-only workaround. AppleScript, TurboQuant, routing guidance, and unrelated
model work are parked until this queue stall is closed.

## Reopened report — mid-toolcall hang and failed-tool cache reset

New user evidence received 2026-07-22 21:49:

- `got hung again, stuck in a mid toolcall`
- `if a tool call fails, it resets the kv cache`
- the report appears to describe the request returning to a cold/warm-up
  prefill state after a tool failure; the final counter text was truncated in
  the chat handoff and must be re-collected from runtime logs/UI if available.

This is a different lifecycle edge from the previously proven manual Stop row.
The current proof does **not** establish that failed tool turns preserve the
same cache owner, prefix boundary, disk-restore eligibility, or solo lease
handoff as successful tool turns.

Required closure evidence:

1. Reproduce a mid-toolcall failure in the isolated Release Osaurus app, not
   only through RunBench or an API harness.
2. Capture the exact visible UI state at hang time: queued/prefill/decode label,
   active Stop/Send controls, selected model, Thinking state, and whether the
   final answer or tool row has already rendered.
3. Capture source/runtime traces for the same request:
   `STREAM-DRAINED`, `LEASE-RELEASED`, tool-result commit, cache fetch/store
   counters, disk boundary, suffix token count, and any warm-up cancellation.
4. Verify whether a failed tool result invalidates request-local KV, session
   prefix metadata, disk L2 entry eligibility, or only the UI's warm chip.
5. Prove recovery in a new chat and same chat after the failed tool call:
   SSD-only partial restore with paged RAM cache Off, coherent answer, TTFT,
   token/s, and no hidden proactive replay.
6. Re-run at least one Qwen-hybrid row (Bonsai/Ornith) and one rotating/full-KV
   row (Gemma 4 or Laguna) because tool schemas and companion state differ.

Until those rows exist across the named families and restart path, the global
tool-failure path remains **PARTIAL** even though the Gemma 4 MXFP8 proof below
now covers the concrete same-chat/new-chat recovery mechanics for one
rotating/full-KV family.

## 2026-07-22 patched Release proof: failed tool does not strand cache/prefill

Isolated Release app under test:

- App: `/private/tmp/OsaurusToolHangProof-20260722-2303.app`
- Bundle ID: `com.dinoki.osaurus.toolhangproof20260722`
- Executable SHA-256:
  `ddb7a9f8083a682bc8be30f27a58bc5f768bbfc66acff884801ba2d57c634541`
- Source HEAD at build time: `187f7662ce1d40a2349c1987a814bd5a90d75355`
- vMLX pin in the workspace:
  `85d752e501240bfe2d5c39c6f5d08e7d4e139a68`
- Runtime root: `/private/tmp/osaurus-toolhangproof-root-20260722-2259`
- Trace log: `/tmp/osaurus-toolhangproof-live-20260722-2303.log`

Computer Use live rows:

1. Baseline, model `Gemma 4 12B it MXFP8`, Thinking Off:
   `Say BASELINE-GEMMA-PATCHED in one short sentence.` returned
   `BASELINE-GEMMA-PATCHED` at TTFT 1.22s / 27.4 tok/s / 11 tokens. Runtime
   trace stored the stable prefix (`cache/disk-store count=1729`) and then hit
   disk on subsequent baseline warm rows (`HIT disk boundary=1729 remaining=19`,
   `HIT disk boundary=1748 remaining=12`).
2. Capability-unavailable tool path:
   `Use Workspace Assistant to read the file definitely-missing-proof-2308.txt`
   visibly loaded/searched capabilities and terminated with a normal assistant
   answer asking for a folder, TTFT 1.42s / 53.5 tok/s / 42 tokens. The immediate
   same-chat follow-up `SAME-CHAT-CACHE-RECOVERY` returned at TTFT 0.66s /
   30.2 tok/s / 12 tokens. Runtime trace immediately around that recovery showed
   `HIT disk boundary=5982 remaining=13 ... tokens=5995` and
   `cache/disk-store count=5995`.
3. Real failed built-in tool path:
   after selecting the throwaway folder
   `/private/tmp/osaurus-toolproof-workspace-20260722` through the app folder
   picker, the prompt
   `Use the file_read tool to read definitely-missing-tool-error-2308.txt`
   visibly showed `Failed: File read · 582ms`, then rendered
   `File not found: definitely-missing-tool-error-2308.txt.` at TTFT 4.00s /
   30.2 tok/s / 23 tokens. Source/runtime trace for the same row contains:
   - `[Osaurus][Stream] Tool invocation: file_read`
   - `[Osaurus][Tool] Executing: file_read with args: {"path":"definitely-missing-tool-error-2308.txt"}`
   - `file_read returned ... {"ok":false,...,"kind":"not_found",...,"retryable":false,"tool":"file_read"}`
   - cache telemetry during the row included `MISS all tiers tokens=3114` for
     the changed folder/tool prompt, `cache/disk-store count=3114`, then disk
     reuse for the post-tool continuation such as
     `HIT disk boundary=7141 remaining=245 ... tokens=7386` and
     `cache/disk-store count=7386`.
4. Immediate recovery after the failed `file_read`:
   `After the failed file_read, say FAILED-TOOL-CACHE-RECOVERY in one short
   sentence.` returned `FAILED-TOOL-CACHE-RECOVERY` at TTFT 0.73s / 30.6 tok/s /
   12 tokens, with input unlocked. Runtime trace showed continued SSD use:
   `HIT disk boundary=2924 remaining=183 ... tokens=3107`,
   `cache/disk-store count=3119`, `HIT disk boundary=7369 remaining=40 ...
   tokens=7409`, and `cache/disk-store count=7409`.
5. New chat after the failed tool:
   using the toolbar `New chat` button dropped back to the default no-folder
   prompt. The background warm-up did a new cold store for that changed prompt
   (`MISS all tiers tokens=1729`, then `cache/disk-store count=1729/1725`).
   The actual new-chat prompt
   `Say NEW-CHAT-AFTER-FAILED-TOOL in one short sentence.` returned
   `NEW-CHAT-AFTER-FAILED-TOOL` at TTFT 0.64s / 30.5 tok/s / 13 tokens. Runtime
   trace for the actual send showed SSD restore and stores:
   `HIT disk boundary=1729 remaining=20 ... tokens=1749`,
   `cache/disk-store count=1749`, `cache/disk-store count=1762`,
   `HIT disk boundary=1749 remaining=14 ... tokens=1763`, and
   `cache/disk-store count=1763`.
6. Second same-instance failed-tool pass with the same throwaway folder still
   selected:
   `Use the file_read tool to read definitely-missing-tool-error-second-pass-2319.txt`
   visibly showed `Failed: File read · 711ms`, then rendered
   `The file definitely-missing-tool-error-second-pass-2319.txt was not found.`
   at TTFT 1.06s / 30.3 tok/s / 31 tokens. The immediate follow-up
   `After that failed file_read, say SECOND-PASS-FAILED-TOOL-RECOVERY in one
   short sentence.` rendered `SECOND-PASS-FAILED-TOOL-RECOVERY` at TTFT 0.88s /
   30.8 tok/s / 14 tokens, with input unlocked. Runtime trace during and after
   this pass showed continued partial SSD restore/store:
   `HIT disk boundary=2871 remaining=38 ... tokens=2909`,
   `cache/disk-store count=2909`, `HIT disk boundary=2924 remaining=88 ...
   tokens=3012`, `cache/disk-store count=3012`,
   `HIT disk boundary=3161 remaining=331 ... tokens=3492`,
   `cache/disk-store count=3492`, `HIT disk boundary=3492 remaining=15 ...
   tokens=3507`, and `cache/disk-store count=3507`. The row also produced an
   unnecessary `status.txt` artifact card despite the "say one short sentence"
   wording; that is tracked as an open model/tool-selection behavior caveat and
   is not counted as a clean behavior pass.

Interpretation:

- The original mid-toolcall hang had a source owner: local `streamWithTools`
  waited for optional trailing completion stats after `.toolInvocation`, so the
  chat loop did not receive the thrown `ServiceToolInvocation` and no tool body
  dispatched. The patched source now treats `.toolInvocation` as terminal for
  dispatch.
- The patched live app did not strand the failed `file_read` row. The UI showed
  a terminal failed tool card, assistant error text, TTFT/token/s metrics, and
  unlocked input.
- A real failed tool result did not make the next same-chat or next new-chat
  request permanently queue, hang after final answer, or lose all disk-cache
  ability. Runtime telemetry continued to show disk hit/store rows after the
  failure.
- The second same-instance replay reproduced the failed-file path again and
  still reached a terminal UI state plus a same-chat recovery answer. It adds
  evidence against the reported "failed tool resets KV cache to zero and strands
  prefill" failure for this Gemma row, while preserving the separate caveat that
  the model created an unnecessary artifact card on the follow-up.
- This row does **not** prove the app-restart path, Qwen/Bonsai/Ornith hybrid
  companion path, Laguna path, or TurboQuant-KV opt-in path. It also does not
  replace a same-instance visual Settings-toggle audit; it proves the effective
  runtime cache path in this run through trace lines, including disk hits/stores
  and `paged-store ... blocks=0 payload=false`.

Focused source-test evidence for this patch:

- `xcodebuild -workspace osaurus.xcworkspace -scheme OsaurusCoreTests
  -configuration Debug -destination 'platform=macOS,arch=arm64'
  -derivedDataPath /private/tmp/osaurus-applescript-quote-fix-derived-20260722
  -disableAutomaticPackageResolution -skipPackagePluginValidation test
  -only-testing:OsaurusCoreTests/RuntimePolicySourceTests/localStreamWithToolsDispatchesParsedToolInvocationWithoutWaitingForOptionalStats
  -only-testing:OsaurusCoreTests/ChatWarmupControllerCompletedRunTests/erroredRunDoesNotWarm
  -only-testing:OsaurusCoreTests/RuntimePolicySourceTests/chatClassifiesToolRejectionAsErroredCleanup`
  exited 0 before the Release UI proof. The docs changed afterwards; the source
  under test did not.

## 2026-07-22 live-source trace: complete tool call stuck before dispatch

Isolated Release app under test:

- App:
  `/private/tmp/osaurus-applescript-quote-fix-derived-20260722/Build/Products/Release/osaurus.app`
- Bundle ID: `com.dinoki.osaurus.applequoteproof20260722`
- Executable SHA-256:
  `ab839ffe81afc29ccb3a96e8252ad48bedca88623f3f2381c664ddfcbe93d893`
- Runtime root:
  `/private/tmp/osaurus-toolreject-cache-root-20260722-2229`
- vMLX pin visible in the built checkout: `85d752e501240bfe2d5c39c6f5d08e7d4e139a68`
- Trace log: `/tmp/osaurus-toolreject-cache-live-20260722-2238.log`

Computer Use visibly confirmed Gemma 4 26B JANG_4M, the Configuration
assistant, Thinking On, Prefix Cache On, GPU/Paged Cache Off, Disk Cache On,
codec `Engine Selected`, SSM re-derive On, and saved settings.

Baseline prompt `Say BASELINE-GEMMA in one short sentence.` returned
`BASELINE-GEMMA` at TTFT 0.47s / 66.9 tok/s / 8 tokens. Runtime cache telemetry
for that send showed SSD L2 restore with paged RAM cache off:

- `[vmlx][cache/fetch] HIT disk boundary=2328 remaining=16 ... tokens=2344`
- `cache/disk-store count=2344`

The next prompt asked to use AppleScript and decline the approval card. Because
the active agent was the Configuration assistant, Gemma instead streamed text
and a completed-looking `osaurus_agent` call:

```json
{
  "action": "create",
  "description": "An agent capable of executing AppleScript and shell commands via system tools for testing purposes.",
  "name": "Test Runner"
}
```

The UI then remained active with Stop visible and input queued/disabled. Source
and runtime trace showed this was **not** a tool-body or approval-panel hang:

- No `[Osaurus][Tool] Executing: osaurus_agent ...` line was emitted.
- The tool row existed in the UI, but no tool-result turn was persisted.
- The same request had already restored SSD state:
  `[vmlx][cache/fetch] HIT disk boundary=2353 remaining=39 ... tokens=2392`.

Root cause in current source:

- `ModelRuntime.streamWithTools` surfaced `StreamingToolHint` name/args when it
  saw `.toolInvocation`, then held the runnable `ServiceToolInvocation` in
  `pendingTool` while draining the generation stream for a trailing
  `.completionInfo`.
- If the model/runtime emitted a valid parsed tool call but never reached that
  optional stats/EOS event, `ChatView.processStreamDeltas` never caught
  `ServiceToolInvocation`, so `AgentToolLoop` never called `executeTool`.

Scoped source change under test:

- `Packages/OsaurusCore/Services/ModelRuntime.swift` now treats
  `.toolInvocation` as terminal for local streaming dispatch: it forwards the
  tool name and canonical args, finishes the stream by throwing
  `ServiceToolInvocation`, and lets stream termination cancel the unused decode
  tail.
- `Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift` now pins
  that local `streamWithTools` must not keep a parsed invocation in a pending
  state while waiting for optional completion stats.

Status: **PARTIAL.** Source root is identified and patched, but this is not
closed until the rebuilt app proves the same prompt dispatches or terminates
cleanly, input re-enables, and same-chat/new-chat/restart cache rows still hit
SSD L2 with paged RAM cache off.

## Tool/delegation/cache stress matrix added after the 21:49 report

The failed-tool report must be tested as a full request-lifecycle problem, not
only as a cache counter problem. The following questions are now in scope for
the next isolated Release proof:

1. **Failed tool after valid model step:** approve or force one tool attempt,
   make the tool result fail or be user-rejected, then verify the chat leaves
   pending/toolcall state, does not schedule a completed-transcript warm-up,
   and the next same-chat send is not stranded behind hidden work.
2. **Failed tool before any useful answer:** force an invalid/rejected first
   tool call and verify the system/tool prefix remains SSD-eligible for the
   next prompt even though the failed result text necessarily changes the full
   transcript.
3. **Successful tool control:** run the same prompt with a successful tool
   result and compare the post-tool warm-up, disk restore boundary, suffix
   count, TTFT, token/s, and visible answer against the failed-tool row.
4. **Queued send during failure cleanup:** type a second prompt while the tool
   row is resolving or failing. It must remain explicitly queued for user
   decision on error, not auto-flush behind a failed transcript, and must be
   sendable afterwards.
5. **New chat and app restart:** after the failure row, start a new chat and
   then relaunch the same isolated root. Both rows must show persisted SSD L2
   partial restore with paged RAM cache Off or be recorded as failures.
6. **Subagent/delegation propagation:** spawn/computer-use/appleScript child
   requests must receive the parent turn's explicit Thinking choice and must
   start from their own bounded seed prompt, not from the full parent transcript
   or a prior child run.
7. **Architecture coverage:** repeat at least one Qwen 3.5 hybrid bundle
   (Ornith or Bonsai) and one rotating/full-KV family (Gemma 4 or Laguna).
   Hybrid rows must record SSM/re-derive counters; rotating/full-KV rows must
   record that no false SSM/TurboQuant claim is being made.
8. **Telemetry separation:** distinguish visible warm chip state from runtime
   cache truth. A green dot without `Cache disk hit`/restore telemetry is not a
   cache pass; a yellow dot during a sub-second restore is not a cache failure
   unless the trace shows a miss or cold prefill.

## Reported release evidence

Both screenshots show `Bonsai 27B Ternary JANG`, Thinking enabled, and the same
request stuck at `Queued 0/8823` instead of entering prefill:

- `docs/internal/evidence/2026-07-22-prefill-queue/bonsai-release-queued-weather.png`
  - Prompt: `what's the weather in nyc`
  - Visible memory: `33.2 / 48 GB`
  - SHA-256: `23833a7b6501e3639939b695cfcf0eeaa7689f8306a6cba2763ab8783a9c09bc`
- `docs/internal/evidence/2026-07-22-prefill-queue/bonsai-release-queued-hello-world.png`
  - Prompt: `hello world`
  - Visible memory: `29.3 / 48 GB`
  - SHA-256: `01575cd5741556a0d7fca8a5779b9d1d5ee38ae370d6bf6b4c79af7f669c16be`

User report: the stall occurs on the second turn in the release build and does
not recover. The screenshots prove the visible symptom only. They do **not**
yet prove whether the owner is a leaked BatchEngine slot, an orphaned warm-up,
model unloading, SSD restore, cancellation, or UI progress projection.

## Baseline source truth

- Osaurus base: `0c6563c6618782116aa113dbfe7a4cbc32337b2e`
- Baseline vMLX pin: `bbbf49e090449bb42f6cde8f50b6f230e3578aec`
- Osaurus PR integration pin: merged vMLX PR #176,
  `c59024a1b4b1314bf98ce962f99e1ffaaebfc247`. The exact-pin Release rebuild
  and UI rerun are recorded below.
- Shipped release `0.22.8` resolves to commit
  `402060bce30e802ab0e19a932e05c6afa9c71c99`, published before the SSD repair
  series below.
- Current main contains the merged SSD repair series: #2118, #2119, #2122, and
  #2124. The next-release draft lists all four. The release screenshots therefore
  do not represent the current-main runtime.
- Current vMLX `bbbf49e0` descends from the live-proven SSD restore revision
  `feb35555` through merged PR #173 (`d1312c31`). Its later changes are Laguna
  S2.1 support and numeric tool-argument bridging; the SSD restore is not absent
  from the current pin.

## Queue-stage source trace

- The solo BatchEngine publishes `.queued(completed: 0, total: N)` immediately
  before the iterator begins cache lookup/restore. The first `.prefill` event is
  emitted only after the synchronous coordinator fetch and typed-cache restore.
  A visible `Queued 0/N` therefore does not, by itself, prove model unload or a
  leaked scheduler slot.
- Osaurus holds its solo lease and shared Metal generation gate until the
  upstream stream fully drains, including post-generation SSD store. The live
  traces below show a balanced `STREAM-DRAINED` / `LEASE-RELEASED` pair on every
  observed current-main step.
- A foreground send that arrives during an in-flight proactive warm-up waits for
  that warm-up to finish so the just-materialized SSD prefix can be reused. This
  can display the warm-up's queued/prefill phase in the foreground assistant row.
  Current-main live timing below did not strand the wait.

## Current-main cancellation reproduction — 2026-07-22 follow-up

The earlier current-main proof did not exercise the reported interruption hard
enough and must not be treated as closure. A fresh isolated Release build of
Osaurus `24af4289ff8338de9bd8796ae6fce3517d96ee4f`, pinned to vMLX
`c59024a1b4b1314bf98ce962f99e1ffaaebfc247`, reproduced the failure with
Bonsai 27B Ternary JANG through the real chat UI:

- Prefix Cache On, GPU/Paged Cache Off, Disk Cache On, codec Engine Selected,
  SSM Re-derive On, and Thinking Off were visibly active.
- Completed new-chat turns did use SSD state: examples restored `3612/4067`,
  `4060/5163`, and `3282/3283` prompt tokens.
- A unique 15,109-token prompt restored its cached 3,282-token static prefix and
  entered live prefill. Starting a new chat while that run was active left the
  old runtime request alive after the chat UI had moved on.
- The trace reached `STEP-PREFILL complete 15109/15109` but emitted no matching
  `STREAM-DRAINED` or `LEASE-RELEASED`. At 97 seconds after the interruption,
  the app process was still active at about 84% CPU and the next local send was
  blocked by the old owner.

Source owner:

1. `MLXBatchAdapter.generate` wraps `BatchEngine.generate` in another
   `AsyncStream` and owns the process-wide solo lease.
2. Cancelling the chat cancels the wrapper producer, but its loop previously
   kept iterating the upstream stream while merely dropping non-info events.
3. Because the upstream iterator never terminated, vMLX's stream termination
   handler never cancelled its direct B=1 generation task. Osaurus therefore
   could not reach its lease-release code.
4. Repeated new-chat warm-ups can also leave cancelled tasks in
   `SoloGenerationGate`'s FIFO because its continuations were not
   cancellation-aware.

Scoped repair under test:

- vMLX adds an awaited, idempotent direct-generation cancellation/drain
  boundary. It cancels the producer, waits for its GPU/cache work to exit, and
  clears the same solo id before a serving layer admits the next request.
- Osaurus invokes that boundary immediately when the wrapping stream is
  cancelled and again before releasing its solo/Metal leases.
- The Osaurus solo FIFO removes cancelled waiters instead of letting abandoned
  warm-ups acquire and hand off the lease later.
- No sampler, prompt, parser, model-family, cache-boundary, paged-cache default,
  or TurboQuant setting is changed. No new image artifact is part of this fix.

The first exact-pin Release rerun caught a second owner before merge. With
Ornith 1.0 9B JANG_4M selected, the UI visibly entered prefill at
`1778/17485`; Stop drained and released the cancelled engine in 1.293 seconds.
However, `completeRunCleanup()` then unconditionally scheduled a proactive
warm-up over the abandoned 17k-token user turn. That hidden request began 585
ms later, owned the same solo lease for another 7.555 seconds, and made the UI
look idle while the next chat would still have to wait. This is the reported
"third session stays queued" shape even though the original producer drain is
now bounded.

The follow-up policy repair is intentionally lifecycle-scoped: successful
runs still schedule the completed-transcript checkpoint, while user-cancelled
or errored runs cancel scheduled warm-up instead of replaying abandoned work.
Focused tests prove both sides of that decision, alongside the full
`MLXBatchAdapterTests` suite. The exact rebuilt Release app proof is recorded
below.

## Cancellation/drain Release proof — scoped PR head

Exact candidate:

- Osaurus source: `933186a2b317c293f34f11892e22ba83df2ea4be`
- vMLX pin: merged PR #177,
  `85d752e501240bfe2d5c39c6f5d08e7d4e139a68`
- App: `/private/tmp/Osaurus Prefill Queue Drain 933186a2 20260722.app`
- Bundle ID: `com.dinoki.osaurus.prefillqueueproof20260722`
- Executable SHA-256:
  `a9b5b6ad061733bdf8276adfbdf200328b19032cc290d36ff5363f7f03ef4aa9`
- Isolated root:
  `/private/tmp/osaurus-prefill-queue-drain-root-20260722-1309`

Computer Use visibly confirmed Prefix Cache On, GPU/Paged Cache Off, Disk
Cache On, Engine-selected codec, SSM re-derive On, and saved settings. No new
image file was added to the repository for this proof.

Live rows:

- **Ornith 1.0 9B JANG_4M:** a 17,490-token prompt restored 1,778 tokens;
  Stop drained/released in 1.514 seconds. No hidden 17k replay followed. A new
  chat returned `ORNITH-AFTER-CANCEL` at 0.31s TTFT/68.3 tok/s after restoring
  1,778/1,802. Relaunch against the same root restored 1,772/1,773 from disk
  before any user turn.
- **Bonsai 27B Ternary JANG CRACK:** an 18,068-token prompt restored 1,552
  tokens; Stop drained/released in 2.041 seconds and did not replay. A new-chat
  user turn restored 2,100/2,126, returned `BONSAI-AFTER-CANCEL` at 0.66s
  TTFT/32.2 tok/s, and changed the chip from warming to warm.
- **Gemma 4 12B QAT JANG_4M:** a 14,618-token mixed full-attention/rotating-SWA
  prompt restored 1,708 tokens; Stop drained/released in 2.213 seconds. The
  next new-chat turn restored 1,731/1,749 and returned
  `GEMMA-AFTER-CANCEL` at 0.52s TTFT/31.9 tok/s.
- **Qwen3.6 35B A3B MXFP8 CRACK MTP:** a 15,940-token hybrid prompt restored
  1,623 tokens; Stop drained/released in 2.061 seconds. A natural new-chat
  control restored 2,172/2,205 and answered coherently at 0.55s TTFT/77.5
  tok/s. A second full app process restored 2,172/2,173 in 77ms from SSD and
  showed the warm indicator. An exact-phrase agent prompt separately
  over-selected tools and left empty content; that is retained as a model/tool
  finalization issue, not hidden as a cache pass.
- **Laguna S 2.1 JANG_2L:** after a full app restart, startup restored
  1,644/1,647 from SSD with `KVCacheSimple:12 + RotatingKVCache:36`, paged
  blocks zero. An 86,557-token prompt restored 1,647 tokens; Stop drained and
  released in 5.410 seconds. No 86k replay followed. A user turn sent while
  the new-chat indicator was still warming restored 1,647/1,677 and completed
  in 0.91 seconds; the immediate same-chat control restored 1,691/1,708 and
  returned `Four.` at 0.73s TTFT/39.6 tok/s. Laguna Thinking On rendered the
  exact prompt tail `<assistant><think>`; the model elected to emit an
  immediate `</think>` and therefore stored zero reasoning characters on
  those turns. This is bundle decode behavior, not a missing UI/template flag,
  and no forced-thinking workaround was added.

Across all cancellation rows, the current trace contains a matching
`STREAM-DRAINED` and `LEASE-RELEASED`; cancelled prompts have no subsequent
same-length proactive warm-up. Successful turns still produce the expected
small completed-transcript warm-up and partial SSD store.

## Current-main isolated Release evidence

App:

- Bundle: `com.dinoki.osaurus.prefillqueueproof20260722`
- Configuration: Release, ad-hoc signed, isolated `OSAURUS_TEST_ROOT`
- Source: Osaurus `0c6563c6`, vMLX `bbbf49e0`
- Visible defaults exercised: Prefix Cache On, GPU/Paged Cache Off, Disk Cache
  On, cache codec Engine Selected, SSM Re-derive On.
- Visible settings evidence:
  `docs/internal/evidence/2026-07-22-prefill-queue/cache-settings-release-proof.png`
  (SHA-256 `bbc07f9ded19011e1a8aa4ac0fe190494d9b4ab83e196d71a4cfdc052b9bb856`).
- Full-KV cross-chat evidence:
  `docs/internal/evidence/2026-07-22-prefill-queue/vibe-cross-chat-release-proof.png`
  (SHA-256 `2edb41ee9e4bf9131ab8cd05a1b11fc54a6a62ca8e617d38814b5660a764ea1b`).

Bonsai 27B Ternary JANG (Thinking On):

- Two ordinary turns completed with exact visible answers. Turn 2 restored
  `3027/3045`, TTFT `0.60s`, `46.4 tok/s`; disk hits advanced.
- Exact reported weather prompt completed its model/tool loop without a queue
  leak. Every model step left queued, entered prefill/decode, drained, and
  released its lease. The model itself made excessive/failed search attempts;
  that is a separate agent/tool-quality row, not a queue-liveness pass.
- A new-chat send issued while the chip visibly showed `Warming up…` entered
  prefill and returned exact `RACE-PASS`, TTFT `0.62s`, `39.3 tok/s`.
- A 13,572-token prompt visibly advanced through prefill and returned exact
  `HEAVY-ONE`, TTFT `18.81s`, `40.9 tok/s`; its next turn restored
  `13,577/13,596` and completed instead of remaining queued.
- Quit/relaunch was repeated after moving all 30 recurrent companion files
  (1.1 GB) out of the isolated cache, simulating inherited KV entries without
  separate sidecars. The format-v2 folded hybrid payload restored boundary
  `3005/3024` with `ssm=96` and returned exact `STALE-RECOVERY`, TTFT `0.66s`,
  `43.7 tok/s`.

Gemma 4 12B QAT JANG_4M (Thinking Off):

- Cold isolated load/warm-up completed with `KVCacheSimple: 8` and
  `RotatingKVCache: 40`; paged RAM remained off and disk L2 stored typed
  format-v2 payloads.
- `GEMMA-ONE` restored boundary `1940/1953`, visible TTFT `0.50s`, `38.0 tok/s`.
- `GEMMA-TWO` restored boundary `1962/1975`, visible TTFT `0.49s`, `29.8 tok/s`.
- Both outputs were exact and no reasoning leaked while the visible Thinking
  control was Off.

LFM2.5 recurrent/full-attention hybrid follow-up:

- A clean single-process Release rerun completed a natural new-chat turn and a
  grounded second turn (`Chlorophyll`) at TTFT `0.57s` / `0.51s` and
  `227.4` / `179.8 tok/s`. Queue liveness therefore passed.
- Runtime telemetry showed typed format-v2 SSD stores but no fetch attempt or
  hit; Osaurus L2 counters remained zero. Source trace found the owner in
  `BatchEngine`: every LFM2.5 MXFP8 request carrying tool schemas was routed
  around disk restore, and its tool-prompt seed boundary was suppressed. Since
  normal Osaurus chats carry tool schemas, that name-based safety bypass made
  the family effectively write-only even when Disk Cache was visibly On.
- The current-vMLX patch removes only the LFM name-based bypass and leaves the
  separate unproven Gemma-4 MXFP4 seed exception intact.
- The rebuilt Release app then produced partial SSD hits with paged RAM cache
  Off: boundary `1747/1768` on a new chat, `1793/1815` on its grounded
  follow-up, `1765/1777` on another new chat, and `1747/1750` on startup.
- Visible coherent results were an exact requested sentence, `Rayleigh
  scattering`, and `oxygen`, at TTFT `0.41s`, `0.32s`, and `0.49s` and
  `270.0`, `221.5`, and `239.1 tok/s`. The restored topology was
  `MambaCache:18` plus `KVCacheSimple:6`.

Additional representative cache-path rows:

- Laguna S2.1 JANG_2L restored partial SSD prefixes across turns and a new
  chat with `KVCacheSimple:12` plus `RotatingKVCache:36`; the exact cross-chat
  answer had TTFT `0.93s` at `44.2 tok/s`. The 10 GB disk quota also evicted
  one older entry on the same live path.
- VibeThinker 3B MXFP8 restored full-KV prefixes (`KVCacheSimple:36`) with
  paged RAM Off, including a boundary `81/81` cross-chat hit. Its second turn
  leaked visible deliberation, so cache behavior passes but model coherence
  fails.
- ZAYA1 VL 8B JANGTQ4 restored a `ZayaCCACache:40` prefix, but the generic
  Assistant surface hallucinated an image description after search. This is
  cache-path evidence only, not a usability pass.
- Nemotron Labs Audex 2B 8bit failed to load with `Unsupported model type:
  nemotron_dense_audex`; the pinned runtime cannot close that family row.

Telemetry note: `[vmlx][cache/paged-store]` is logged before tier selection.
The in-memory write is still guarded by a non-nil paged cache. With the visible
GPU Cache toggle Off, that trace label does not prove that paged RAM was
silently enabled.

## Exact merged-pin Release confirmation

This rerun used the scoped Osaurus PR head `5926372363033c22f7497f988fa38e2a967c0414`
with the exact merged vMLX pin
`c59024a1b4b1314bf98ce962f99e1ffaaebfc247` in a fresh Release build. The app
was ad-hoc signed and launched as the isolated bundle
`com.dinoki.osaurus.prefillqueueproof20260722`; its executable SHA-256 was
`070faab1e06e425981410ccbcb7f92714509734dbc7608fc34af111dd4e4289d`.
`OSAURUS_TEST_ROOT` isolated app data, and `OSU_MODELS_DIR=/Users/eric/models`
pointed the proof app at the user-specified local model store instead of
changing or copying any model bundle.

Computer Use visually confirmed Settings -> Server -> Cache with Prefix Cache
On, GPU/Paged Cache Off, Disk Cache On, codec Engine Selected, SSM Re-derive
On, and `All changes saved`. The same exact app then selected and exercised
each model through the visible chat UI:

- LFM2.5 8B A1B MXFP8 CRACK: the exact answer `LFM-EXACT-PIN-ONE` displayed at
  TTFT `0.46s` and `210.6 tok/s`. Runtime fetch restored disk boundary
  `1747/1768` (`remaining=21`, `ssm=18`, format v2). A separate new chat's
  proactive warm-up restored `1747/1750` and drained in `0.45s` rather than
  recomputing from token zero.
- Bonsai 27B Ternary JANG CRACK: the user-visible Thinking control was switched
  Off before the measured turn. That configuration change correctly caused one
  cold seed for the new prompt identity, which stored boundary `3005`; the
  measured turn then restored `3005/3031` (`remaining=26`, `ssm=96`, format v2)
  and displayed exact `BONSAI-EXACT-PIN-ONE` at TTFT `0.95s`, `31.8 tok/s`,
  with zero reasoning deltas. The next new-chat warm-up restored `3007/3008`
  with all 96 hybrid companion states and drained in `0.18s`.
- Gemma 4 12B QAT JANG_4M: Thinking was visibly Off. The first exact-pin warm-up
  stored typed format-v2 rotating payloads. The measured turn then restored
  `1729/1747` (`remaining=18`) and displayed exact `GEMMA-EXACT-PIN-ONE` at
  TTFT `0.65s`, `32.7 tok/s`, with zero reasoning deltas. The next new-chat
  warm-up restored `1725/1729` and drained in `0.20s`. Bundle config contains
  48 layers (8 `full_attention`, 40 `sliding_attention`); live storage reported
  `requiredCompanion=true` plus rotating offsets, matching that mixed topology.

Visible exact-pin answer artifacts:

- `docs/internal/evidence/2026-07-22-prefill-queue/exact-merged-pin-lfm25-mxfp8.png`
  (SHA-256 `f8b01fb868ea8cec70333b12b050fdc84f38f59531054ecaacb1aacef9ac5379`)
- `docs/internal/evidence/2026-07-22-prefill-queue/exact-merged-pin-bonsai-ternary.png`
  (SHA-256 `8f934593ede273bcd36ac08a1ae31abf6be1213d880be4432d83d6396d5c2597`)
- `docs/internal/evidence/2026-07-22-prefill-queue/exact-merged-pin-gemma-jang4m.png`
  (SHA-256 `c7df0859b270b42bc224fb2f2d209e3aeebcf5d3e7eaa5ce054e00a3ffafefeb`)

This closes the exact-pin emergency representative gate only. It does not
convert the open paged-RAM, TurboQuant-KV, unsupported-family, AppleScript, or
all-model matrix rows below into passes.

## Required reproduction matrix

All rows must run through an isolated Release Osaurus app operated through the
visible UI. CLI tests may diagnose but cannot close a row.

| Scenario | Required visible/runtime evidence | Status |
|---|---|---|
| Same chat, second turn | Leaves Queued; enters prefill/decode; coherent answer; TTFT | PASS — Bonsai, Gemma |
| New chat, same model | SSD counters before/after; restored tokens; remaining prefill; TTFT | PASS — Bonsai |
| Send while background warm-up owns load | One load owner; foreground request cannot starve | PASS — Bonsai |
| Stop/cancel then send | Cancelled slot/producer exits; next request starts | PASS — isolated Release UI rows for Ornith, Bonsai, Gemma 4, Qwen MXFP8, and Laguna; every cancelled stream drained/released, no abandoned long prompt replayed, and the immediate new-chat request left queued and completed |
| Switch model and return | Old engine lifecycle completes; returned model starts | PARTIAL — forward switches passed; return-to-prior not rerun |
| Quit/relaunch and send | Disk L2 restore is attached before request publication | PASS — Bonsai folded hybrid restore |
| Paged RAM cache off, SSD on | Default user path; partial/exact disk hit truth | PASS — Bonsai, Gemma |
| Paged RAM cache on, SSD on | Hot RAM then warm SSD fallback; no queue regression | OPEN |
| TurboQuant KV off/on where supported | Setting takes effect; coherent multi-turn output | OPEN |
| Plain KV representative | Shared fix works outside hybrid/rotating paths | PASS for cache path — Vibe full-KV disk hits; FAIL for its turn-2 reasoning leak |
| LFM2.5 MXFP8 hybrid | Disk fetch is not globally bypassed merely because Osaurus supplies tools | PASS — partial SSD hits and coherent new-chat/follow-up output in rebuilt Release app |
| Qwen/Bonsai hybrid representative | Companion-state restore/re-derive remains coherent | PASS — Bonsai queue/cache row |
| Gemma rotating-SWA representative | Rotating/global cache remains coherent | PASS — Gemma 4 12B queue/cache row |
| Laguna mixed full/rotating | Cross-chat partial SSD restore and coherent output | PASS — 12 full + 36 rotating layers |
| CCA representative | Typed disk restore | PARTIAL — ZAYA cache hit; generic Assistant coherence failed |
| Unsupported family detection | Unsupported models fail explicitly | BLOCKED — Audex runtime is not in the pinned engine |

## Release gate

The shipped-build symptom had two current owners under real interruption: the
wrapped direct-generation producer was not awaited through cancellation, and
chat cleanup unconditionally scheduled a proactive warm-up for the abandoned
prompt. The scoped vMLX drain API plus Osaurus lifecycle policy repair close
those owners in the exact Release app. The distinct LFM tool-schema bypass was
already handled by the earlier narrow vMLX/Osaurus pin and is not reimplemented
here. None of this closes unsupported/incoherent family rows.

Before claiming the broader all-setting campaign complete:

1. A root-cause trace naming the request owner, queue condition, and cleanup
   path that failed.
2. Focused regression tests plus relevant full test/build checks.
3. Isolated Release UI proof for second turn, new chat, cancellation, and
   restart with visible settings and cache telemetry.
4. Representative plain-KV, hybrid Qwen/Bonsai, and Gemma rotating-SWA rows.
5. Scoped diff audit and fresh PR CI. No AppleScript or unrelated model work in
   the emergency PR.

## 2026-07-23 final-current follow-up: parsed tool dispatch and failed-tool recovery

This follow-up was run after rebasing on `osaurus/main` `187f7662` and pinning
vMLX to `3d5aa12be1ad4a7e1492e062e6d136a4f31c7dfb`.

Build under test:

- Release app:
  `/private/tmp/osaurus-emergency-finalize-release-derived-20260723/Build/Products/Release/osaurus.app`
- bundle id: `com.dinoki.osaurus.emergencyproof20260723`
- executable SHA-256:
  `51d8452082893fc1baf675950991394aeb4494bc185a91588310bf2018ac8028`
- ad-hoc signature: `codesign --verify --deep --strict --verbose=2` accepted
  the app; `TeamIdentifier=not set`
- proof root:
  `/private/tmp/osaurus-emergency-finalize-proof-root-20260723-0120`
- trace files:
  `/tmp/osaurus-prefill-debug.log`,
  `/tmp/osaurus-emergency-finalize-live-20260723-0120.log`, and
  `/tmp/osaurus-reasoning-prompt-dumps-20260723-0120/`

Source trace for the final diff:

- `Packages/OsaurusCore/Services/ModelRuntime.swift` treats
  `.toolInvocation` as terminal for local tool dispatch, yields the committed
  tool name/arguments, finishes by throwing `ServiceToolInvocation`, and cancels
  the unused decode tail instead of waiting for optional `.completionInfo`.
- `Packages/OsaurusCore/Views/Chat/ChatView.swift` classifies
  `runResult.exit == .toolRejected` as an errored cleanup path so a failed tool
  row does not schedule a hidden completed-transcript warm-up over the failed
  intermediate prompt.
- Focused source tests pinned both seams:
  `RuntimePolicySourceTests/localStreamWithToolsDispatchesParsedToolInvocationWithoutWaitingForOptionalStats`,
  `RuntimePolicySourceTests/chatClassifiesToolRejectionAsErroredCleanup`, and
  `ChatWarmupControllerCompletedRunTests/erroredRunDoesNotWarm`.

Computer Use live proof from the same Release app:

| Row | Visible result | Runtime/cache evidence |
| --- | --- | --- |
| Gemma 4 12B it MXFP8, Thinking Off | exact `GEMMA-SSD-FINAL-OK`, TTFT 1.31s, 27.7 tok/s, input unlocked | prompt restored `1729/1749`, then stats `promptTps=2144.5`, `genTokens=12`, `genTps=27.7`, and disk L2 advanced from 0 to 1 hit with stores 2 -> 4 |
| Bonsai 27B Ternary JANG CRACK, failed `file_read` | visible `Failed: File read`, final answer returned, no stuck Stop state | first step restored `4185/4242`, emitted `TOOL-EXEC-BEGIN name=file_read`, then the post-tool continuation restored `4235/4399`; follow-up file search restored `4235/4421`; final stats `genTokens=86`, `genTps=31.0`; stream drained and lease released after each step |
| Bonsai same-chat recovery after the failed tool | exact `BONSAI-AFTER-FAILED-TOOL-OK`, TTFT 0.87s, 31.6 tok/s, input unlocked | next request restored `4497/4534`; stats `promptTps=15245.8`, `genTokens=13`, `genTps=31.6`; disk L2 hits advanced 4 -> 5 |
| Bonsai new chat after failed tool | exact `BONSAI-CROSSCHAT-SSD-OK`, TTFT 0.81s, 31.5 tok/s, input unlocked | new no-folder warm-up cold-stored the changed prompt shape, then actual send restored `3005/3035`; stats `promptTps=10291.9`, `genTokens=12`, `genTps=31.5`; disk L2 hits advanced 6 -> 7 |
| Ornith 1.0 9B JANG_4M, Thinking Off | exact `ORNITH-JANG4M-SSD-OK`, TTFT 0.37s, 69.2 tok/s, input unlocked | user send restored `2040/2071` with `ssm=48` in vMLX trace; Osaurus trace recorded `promptTps=17644.9`, `genTokens=11`, `genTps=69.2`; the follow-up warm row restored `2064/2087` |
| Laguna S 2.1 JANG_2L, Thinking On | coherent answer and unlocked input, but no reasoning box | source and prompt-dump evidence shows the rendered prompt ended with `<assistant><think>`, so the UI/request path did send thinking-on; the model then immediately emitted `</think>` and placed `internal-check` in visible content on the parser stress prompt |

Interpretation:

- The previously observed "complete-looking tool row but no execution" owner is
  closed for the local streaming path on this build: a parsed `.toolInvocation`
  now dispatches immediately and the UI no longer waits for optional stats/EOS
  before tool execution.
- A real failed built-in tool result did not reset the cache into an unusable
  state in the Bonsai hybrid row. The failed-tool continuation, same-chat
  follow-up, and new-chat follow-up all restored partial SSD prefixes with
  paged RAM cache off and produced visible terminal answers.
- Laguna's missing reasoning box is not proven to be an Osaurus toggle/parser
  miss. The prompt tail contained `<assistant><think>`, and the next prompt
  dump contained `<assistant><think></think>internal-check...`; this is current
  model/bundle decode behavior. No app-side forced-thinking or hidden parser
  nudge was added.
- This evidence does not close TurboQuant-KV, paged-RAM-on fallback, full
  all-model cache matrix, or AppleScript duplicate-edit/no-save rows.

## 2026-07-23 v3 scoped Release proof — current source of truth

This supersedes the older `3d5aa12...` addendum above for the emergency merge
candidate. It does not erase that history; it records the current app/pin that
was actually live-operated for the final scoped rows.

Build under test:

- Release app:
  `/private/tmp/osaurus-emergency-scoped-release-derived-v3b-20260723/Build/Products/Release/osaurus.app`
- bundle id: `com.dinoki.osaurus.emergencyscopedproofv320260723`
- executable SHA-256 after ad-hoc signing:
  `858cadab0912084e66314fc5ba6097e5c235753b9dc90642fb1ea7ef3a99c446`
- `codesign --verify --deep --strict --verbose=2` accepted the app;
  `TeamIdentifier=not set`
- proof root:
  `/private/tmp/osaurus-emergency-scoped-proof-root-v3-20260723-0310`
- pinned vMLX:
  `7d6235316226ba9fe608018f86c463784e48b3d5`
- trace files:
  `/tmp/osaurus-prefill-debug.log`,
  `/tmp/osaurus-emergency-scoped-live-v3-20260723-0310.log`, and
  `/tmp/osaurus-reasoning-prompt-dumps-scoped-v3-20260723-0310/`
- current live process at proof time:
  pid `6222`, same bundle id, same proof root, and open cache files under
  `/private/tmp/osaurus-emergency-scoped-proof-root-v3-20260723-0310/cache/kv_v2`

Current source seams:

- `ModelRuntime.streamWithTools` treats parsed local `.toolInvocation` as
  terminal for dispatch: it yields the tool name/args, throws
  `ServiceToolInvocation`, and returns instead of holding a pending tool while
  waiting for optional completion stats.
- `ChatView` marks `runResult.exit == .toolRejected` as `lastStreamError =
  "Tool call failed."`, so failed/rejected tool runs do not enter the normal
  successful-run cleanup path.
- `ChatWarmupController.handleRunCompleted` now accepts `hadToolActivity`; the
  session computes that from tool turns/calls/results/remote tool activity and
  suppresses hidden completed-transcript warm-up for tool-loop transcripts.
- `LocalReasoningCapability` reads bundle metadata
  `generation_config.default_chat_template_kwargs.enable_thinking` and
  `jang_config.chat.reasoning.default_enabled/default_mode` before presenting
  effective local Thinking defaults.

Focused source verification on this source tree:

```sh
git diff --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -workspace osaurus.xcworkspace \
  -scheme OsaurusCoreTests \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/osaurus-emergency-finalize-derived-20260723 \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  test \
  -only-testing:OsaurusCoreTests/RuntimePolicySourceTests/localStreamWithToolsDispatchesParsedToolInvocationWithoutWaitingForOptionalStats \
  -only-testing:OsaurusCoreTests/ChatWarmupControllerCompletedRunTests \
  -only-testing:OsaurusCoreTests/RuntimePolicySourceTests/chatClassifiesToolRejectionAsErroredCleanup \
  -only-testing:OsaurusCoreTests/LocalReasoningCapabilityTests \
  -only-testing:OsaurusCoreTests/ModelProfileRegistryTests
```

The command exited 0. This is focused source verification only, not a full
Osaurus test-suite claim.

Computer Use live rows from the same v3 Release app:

| Scenario | Visible UI result | Runtime/cache evidence |
| --- | --- | --- |
| Cache Settings | Settings -> Server -> Cache visibly saved Prefix Cache On, GPU/Paged KV Off, SSD/L2 Disk Cache On, SSM rederive On, and "All changes saved." | The rows below are SSD-only/paged-off rows; no paged RAM hit is being counted. |
| Bonsai failed multi-tool path | `Bonsai 27b Ternary JANG CRACK`, Thinking Off. A missing-file/tool prompt produced failed tool rows and then exact `BONSAI-V3-TOOL-FAIL-FINALIZED`, TTFT 0.96s, 31.9 tok/s, 14 tokens, input unlocked. | Initial warm stored `3008`; user prompt restored `3005/3077`; tool-loop continuations restored `3070/3124`, `3117/3817`, `3810/4051`, `4044/4101`, `4094/4451`, and `4444/4498`; disk L2 hits advanced 0 -> 7. |
| Bonsai same-chat after failed tools | Immediate follow-up returned exact `BONSAI-V3-AFTER-TOOL-FAIL-NOT-QUEUED`, TTFT 2.73s, 32.0 tok/s, 18 tokens, input unlocked. | There was no hidden `lastMsgRole=assistant` warm-up between the final tool answer and this follow-up. The follow-up request was `lastMsgRole=user` and restored `3070/4518`; disk L2 hits advanced 7 -> 8. |
| Bonsai new chat | Toolbar `+` new chat, same model/settings. Prompt returned exact `BONSAI-V3-NEW-CHAT-SSD-PARTIAL`, TTFT 0.93s, 32.0 tok/s, 16 tokens. | New-chat warm prefix restored `3007/3008`; user prompt restored `3007/3035`; disk L2 hits advanced 8 -> 10. |
| Bonsai process restart | Same signed app relaunched against the same isolated proof root. Prompt returned exact `BONSAI-V3-RESTART-SSD-PARTIAL`, TTFT 0.86s, 33.1 tok/s, 15 tokens. | In the fresh process, first warm prefix restored `3007/3008` from disk with `diskL2Hits=0 -> 1`; user prompt restored `3007/3034`, then hits advanced 1 -> 2. |
| Gemma 4 MXFP8 | Switched in UI to `Gemma 4 12B it MXFP8`, Thinking Off, new chat. Prompt returned exact `GEMMA-V3-NEW-CHAT-SSD-PARTIAL`, TTFT 0.82s, 29.6 tok/s, 18 tokens. | Earlier cold warm stored `1729`; fresh-chat warm prefix restored `1725/1729`; visible prompt restored `1729/1751`; post-success warm row restored `1751/1770`. |
| Laguna S 2.1 JANG_4M reasoning | UI model picker selected `Laguna S 2.1 JANG_4M`; Thinking value On. The non-trivial arithmetic prompt showed a separate `Thought for 2.9s` row and final answer with `FINAL: 964`; TTFT 0.86s, 38.7 tok/s, 136 tokens, input unlocked. | Prompt dump ended with `<assistant><think>` and the completed dump contained non-empty reasoning before `</think>` followed by the visible answer. Cache trace restored fresh-chat warm prefix `1670/1673`, then user prompt `1673/1706`, with disk L2 hits advancing 4 -> 5. |

Negative/source-trace comparison:

- The older bad pattern is preserved in `/tmp/osaurus-prefill-debug.log` lines
  around 2374-2382: after a Bonsai tool run, Osaurus launched a hidden
  `lastMsgRole=assistant` warm-up that cold-prefilled `0/8467` and took
  15.7s of prompt work before the next visible turn.
- The v3 Bonsai failed-tool run has no such hidden assistant warm-up between
  the final tool answer and the immediate user follow-up. The next request is a
  visible `lastMsgRole=user` send with partial SSD restore.

Current conclusion for this emergency row:

- Source and live evidence cover the local stream finalization bug, failed-tool
  cleanup classification, suppression of hidden tool-transcript warm-up, and
  SSD-only partial restore for the Bonsai/Gemma/Laguna rows above.
- The rows remain scoped. They do not close AppleScript duplicate-edit/no-save,
  generic Computer Use retries, TurboQuant-KV opt-in, paged-RAM-on fallback,
  full all-model media/cache topology, or external-user hardware variance.
