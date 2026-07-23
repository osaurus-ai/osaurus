# SSD L2 new-chat partial-restore gate — 2026-07-21

## Status

`PARTIAL / SCOPED BONSAI-GEMMA-LAGUNA SSD-L2 PARTIAL RESTORE PROVEN-LIVE ON
THE 2026-07-23 V3 RELEASE APP; BROADER CACHE MATRIX PARTIAL`

This gate covers the report that a model becomes responsive in one chat but a
new chat appears to prefill from zero while paged RAM cache is Off and Disk L2
is On. Aggregate counters are supporting evidence only. A row is credited only
when a request trace identifies the tier, matched boundary, remaining suffix,
companion-state behavior, TTFT, token/s, and a coherent visible answer.

## New open failure mode: failed tool call appears to reset KV/cache state

User report received 2026-07-22 21:49 says a run hung inside a mid-toolcall and
that, when a tool call fails, the warm KV/cache state appears to reset back to
the cold prefill path. The report is not yet paired with a complete trace, so
the exact owner is open.

Working hypotheses to test, without assuming a fix:

- the tool-failure turn may be clearing request-local KV/session prefix state
  when only the tool continuation should be invalidated;
- the failed tool result may be changing the canonical prompt/tool schema
  enough to miss the previously stored SSD prefix;
- an error path may skip disk store or companion-state re-derive metadata while
  still updating the visible chat/session state;
- a lease/stream cleanup path may leave a stale active owner, making the next
  request show cold queued/prefill even when disk entries exist;
- UI warm-state projection may be reset even if runtime disk entries remain
  valid, which must be separated from a real cache miss.

Required proof rows before closure:

1. Force a deterministic failing tool call in the live Osaurus app, with Prefix
   On, paged RAM cache Off, Disk L2 On, and trace flags enabled.
2. Immediately send a same-session follow-up that should share the same
   system/tool prefix. Record disk boundary, suffix tokens, TTFT, token/s,
   visible answer, and whether the chip shows warm versus cold.
3. Start a new chat and repeat the same prompt. Record whether SSD partial
   restore uses the already stored system/tool prefix.
4. Quit/relaunch against the same test root and repeat the prompt to prove the
   cache is truly persisted, not only resident in process memory.
5. Compare at least one successful-tool row with one failed-tool row on the
   same model and same settings.
6. Run the comparison on at least:
   - one Qwen 3.5 hybrid family bundle such as Ornith or Bonsai;
   - one rotating/full-KV family such as Gemma 4 or Laguna.

Until these rows exist across the named families and restart path, SSD partial
restore is not globally verified for tool-failure recovery. The Gemma 4 MXFP8
row below now proves the failed built-in `file_read` path does not globally
poison SSD cache fetch/store inside the same app process.

### 2026-07-22 patched failed-tool cache-retention proof

Isolated Release app:

- App: `/private/tmp/OsaurusToolHangProof-20260722-2303.app`
- Bundle ID: `com.dinoki.osaurus.toolhangproof20260722`
- Executable SHA-256:
  `ddb7a9f8083a682bc8be30f27a58bc5f768bbfc66acff884801ba2d57c634541`
- Source HEAD: `187f7662ce1d40a2349c1987a814bd5a90d75355`
- vMLX pin: `85d752e501240bfe2d5c39c6f5d08e7d4e139a68`
- Runtime root: `/private/tmp/osaurus-toolhangproof-root-20260722-2259`
- Trace log: `/tmp/osaurus-toolhangproof-live-20260722-2303.log`

Live UI model row: `Gemma 4 12B it MXFP8`, Thinking Off. The run did not use
image evidence in git; the proof is the Computer Use accessibility transcript
plus the runtime trace above.

Observed sequence:

| Step | Visible UI result | Cache trace result |
| --- | --- | --- |
| Baseline | `BASELINE-GEMMA-PATCHED`, TTFT 1.22s, 27.4 tok/s, 11 tokens | initial `MISS all tiers tokens=1729`, then stores `1729/1725`; later baseline warm rows hit `boundary=1729 remaining=19` and `boundary=1748 remaining=12` |
| Capability-unavailable tool path | loaded/searched capabilities, answered that folder tools were unavailable, TTFT 1.42s, 53.5 tok/s, 42 tokens | context continued to store/hit disk; immediate recovery hit `boundary=5982 remaining=13 ... tokens=5995` |
| Same-chat recovery after capability failure | `SAME-CHAT-CACHE-RECOVERY`, TTFT 0.66s, 30.2 tok/s, 12 tokens | `cache/disk-store count=5995` after the disk hit |
| Real failed built-in tool | `Failed: File read · 582ms`; answer `File not found: definitely-missing-tool-error-2308.txt.`, TTFT 4.00s, 30.2 tok/s, 23 tokens | trace shows `Tool invocation: file_read`, `Executing: file_read`, and an `ok:false kind:not_found retryable:false` tool envelope; changed folder/tool prompt first missed/stored `3114`, then the post-tool continuation reused disk `boundary=7141 remaining=245 ... tokens=7386` |
| Same-chat recovery after real failed tool | `FAILED-TOOL-CACHE-RECOVERY`, TTFT 0.73s, 30.6 tok/s, 12 tokens | disk hits/stores continued: `boundary=2924 remaining=183 ... tokens=3107`, `cache/disk-store count=3119`, `boundary=7369 remaining=40 ... tokens=7409`, `cache/disk-store count=7409` |
| New chat after failed tool | `NEW-CHAT-AFTER-FAILED-TOOL`, TTFT 0.64s, 30.5 tok/s, 13 tokens | new no-folder warm-up first cold-stored `1729/1725` because the folder/tool prompt changed; the actual new-chat send hit `boundary=1729 remaining=20 ... tokens=1749`, stored `1749/1762`, then hit `boundary=1749 remaining=14 ... tokens=1763` |
| Second same-instance failed tool | `Failed: File read · 711ms`; answer `The file definitely-missing-tool-error-second-pass-2319.txt was not found.`, TTFT 1.06s, 30.3 tok/s, 31 tokens | with the same throwaway folder still selected, the row and its immediate follow-up continued to hit/store disk: `boundary=2871 remaining=38 ... tokens=2909`, `store count=2909`; `boundary=2924 remaining=88 ... tokens=3012`, `store count=3012`; follow-up `boundary=3161 remaining=331 ... tokens=3492`, `store count=3492`; then `boundary=3492 remaining=15 ... tokens=3507`, `store count=3507` |
| Second same-chat recovery caveat | `SECOND-PASS-FAILED-TOOL-RECOVERY`, TTFT 0.88s, 30.8 tok/s, 14 tokens, input unlocked | recovery proves the failed tool did not strand this live Gemma session, but the UI also displayed an unnecessary `status.txt` artifact card; that behavior is not counted as a clean tool-selection pass |

Interpretation:

- The user-visible `Prefill 0/3114` frame was reproduced during the real
  missing-file row and advanced to completion. It did not become a permanent
  `Queued 0/N` hang.
- The failed `file_read` result did not clear all SSD eligibility or block the
  next request. Both same-chat and new-chat follow-ups produced visible coherent
  answers with TTFT/token/s and runtime disk hit/store evidence.
- A second same-instance failed `file_read` replay also completed and was
  followed by continued disk partial restore/store. This narrows the failure
  report away from a universal "failed tool clears all KV/SSD cache" explanation
  for Gemma 4 MXFP8, but still leaves Qwen/Bonsai/Ornith hybrid, Laguna,
  app-restart, and TurboQuant opt-in rows open.
- The no-folder new chat did a cold store before the actual send because the
  prompt shape changed when the throwaway folder context was removed. That row
  must not be misreported as proof that every new chat always starts with a disk
  hit; it proves the failed tool did not poison the default prompt path and that
  the subsequent send reused the just-stored SSD prefix.
- Still open: same-root app restart, Qwen 3.5 hybrid rows, Laguna row,
  TurboQuant-KV opt-in rows, quota/eviction pressure rows, and a visual
  Settings-toggle audit in this exact app instance.

### 2026-07-22 cache observation during the streamed-tool hang

An isolated Release app live run reproduced a complete-looking tool row that
never dispatched. The cache trace for that same stuck request showed SSD L2 was
not absent:

- Baseline send: disk hit restored boundary 2,328 with 16 remaining prompt
  tokens, then stored 2,344.
- Pre-hang tool-call send: disk hit restored boundary 2,353 with 39 remaining
  prompt tokens, then stored 2,392.
- Paged RAM cache was visibly Off in Settings; the stored payload had no paged
  blocks and used the runtime's disk/companion state path.

This narrows the reopened failure: the visible hang was not caused by the
stable system/tool prefix failing to restore from SSD before generation. The
patched owner is local streaming finalization: Osaurus waited for optional
trailing completion stats after vMLX had already emitted `.toolInvocation`, so
the tool call was never thrown to the chat loop and the failed-tool cleanup path
could not run.

Status remains **PARTIAL** until the rebuilt app proves:

1. parsed local tool calls dispatch/terminate without waiting forever;
2. a failed/rejected tool result does not trigger hidden completed-transcript
   warm-up;
3. same-chat, new-chat, and post-relaunch prompts still restore partial SSD
   blocks with paged RAM cache Off.

### Cache questions that must be answered by the next harness/UI run

- Does a failed tool result alter only the suffix of the prompt, or does it
  also invalidate the stable system/tool prefix entry that should remain
  reusable across chats and restarts?
- Does Osaurus attempt to warm the failed intermediate transcript as though it
  were a successful checkpoint? If yes, that hidden warm-up can own the same
  solo slot and make the next visible send look cold or permanently queued.
- Do tool schemas, loaded-tool manifests, frozen soul/system prompt text,
  folder/sandbox mode, and Thinking options produce the same fingerprint in
  warm-up and real-send paths?
- When paged RAM cache is Off, can the next same-chat send, a fresh chat, and
  a post-relaunch chat still restore the shared prefix directly from SSD L2?
- For hybrid models, does the restored disk boundary include the required
  companion-state/re-derive behavior instead of falsely restoring an unsafe
  full boundary?
- For subagents and delegated runs, does the child prompt start from a stable
  child seed so its own system/tool prefix can be cached, or does it inherit
  enough parent context to make every child request a one-off miss?
- If a tool call is rejected by policy or by the user, is queued follow-up input
  intentionally left for user action instead of being auto-flushed behind a
  failed transcript?

## Root cause and scoped change

Qwen 3.5-family templates such as Bonsai and Ornith can require a user message
before they render. vMLX derives their stable system/tool prefix by intersecting
two divergent synthetic user renders with the real request; synthetic content
is never sent to the model or admitted to the stored stable prefix.

Path-dependent hybrid restores deliberately reject an exact disk boundary.
The GDN/Mamba/CCA state must be restored at N-1 and the final token re-fed.
The previous stable-prefix writer stored N, so the first brand-new chat missed,
did a cold prefill, and only then created a usable shorter snapshot for later
chats. vMLX `feb35555900398dc638c82a3e13e98f8b1adbf41` stores the
processor-proven stable checkpoint at N-1 for disk-backed hybrid topologies and
keeps that safe seed in the preferred lookup set even after the bounded disk
index contains more than 128 larger historical entries.

Dense/full-KV and rotating-SWA topologies retain their existing boundary
policy. ZAYA CCA remains explicit: its typed v2 payload owns CCA state and does
not require a separate recurrent sidecar.

Osaurus also labels runtime cache lookup/restore stages separately from actual
transformer prefill. An initial cache lookup event is no longer displayed as a
cold `Prefill 0/N`.

## Source/test evidence

- vMLX PR #173, head `feb35555`.
- `HybridStripBoundaryPrefillTests`: 8/8, including first-new-chat N-1 restore.
- canonical/coordinator matrix: 19/19.
- topology and growing-chat source suites: 59/59.
- updated BatchEngine growing-chat source suite: 17/17.
- Osaurus consumes the same revision in all four package-pin surfaces.

These checks are not live app proof.

## Current `feb35555` Release-app proof

The freshly built app at
`/private/tmp/osaurus-ssd-warm-prefill-release-derived-20260721/Build/Products/Release/osaurus.app`
was ad-hoc signed as `com.dinoki.osaurus.ssdwarmfeb355proof20260721`.
Its executable SHA-256 was
`488b2ce7106cb8e85bb3f27e69d4db7941abb6f977bc3174e09131169d22a3ea`,
and the resolved vMLX checkout was exactly
`feb35555900398dc638c82a3e13e98f8b1adbf41`.

Computer Use visibly confirmed Prefix On, GPU/paged cache Off, Disk Cache On,
codec `Engine Selected`, SSM re-derive On, and Thinking Off. Disk Cache was
turned Off and saved for the negative control, then restored On and saved
before the Gemma/Bonsai rows.

| Model / scenario | Cache trace | Visible UI result |
| --- | --- | --- |
| Qwen AgentWorld 35B A3B MXFP8, first new chat | disk boundary 2,992; one token remaining; 60 recurrent states | warm-up first delta 0.36 s; `Au`, TTFT 0.51 s, 49.0 tok/s |
| Same Qwen bundle after quit/relaunch | disk boundary 2,992; one token remaining; 60 recurrent states | warm-up first delta 0.21 s; `Au`, TTFT 0.49 s, 47.8 tok/s |
| Same Qwen request, Disk Cache Off | `MISS all tiers`; true UI prefill visibly reached `1024/3010` | `Au`, TTFT 1.89 s, 47.9 tok/s |
| Gemma 4 12B QAT JANG_4M, later new chat | disk boundary 1,629; four tokens remaining; `ssm=-1` | warm-up 0.28 s; `Au`, TTFT 0.41 s, 35.3 tok/s |
| Bonsai 27B Ternary JANG, later new chat | disk boundary 2,922; one token remaining; 96 recurrent states | warm-up 0.20 s; prior `Au`, TTFT 0.50 s, 30.7 tok/s |

The emergency first-new-chat/restart defect is verified on current source.
Intervening quota pressure, paged-hot-to-SSD fallback, TurboQuant opt-in,
media salts, and the remaining model-family matrix stay explicitly partial.

## Prior live diagnostic evidence

An isolated Release app at the earlier `c21cf7b0` pin was operated through the
UI with Bonsai Ternary JANG, Thinking Off, Prefix On, paged RAM Off, Disk L2 On,
and TurboQuant not enabled. A disk hit restored boundary 3,808 with seven
tokens remaining and produced `Au` at TTFT 0.37 s and 30.6 tok/s. Turning Disk
L2 Off in Settings and saving caused the same prompt to miss all tiers and take
TTFT 5.23 s at 30.3 tok/s. This proves SSD-only restore materially affects
latency, but it does not prove the new N-1 first-new-chat change.

## Current-source acceptance matrix

The original acceptance checklist now stands as follows:

1. **PASS:** settings visibly saved with Prefix On, paged RAM Off, Disk L2 On,
   default non-forced codec, and SSM re-derive On.
2. **PASS:** Qwen 3.5 MXFP8 cold store, first-new-chat N-1 restore, coherent
   answer, and quit/relaunch persistence.
3. **PARTIAL:** Gemma 4 QAT JANG_4M rotating-SWA/full-attention restore is
   proven across a new chat without false SSM/TurboQuant claims; its separate
   app-restart row remains open.
4. **PASS:** Bonsai Ternary JANG disk-only partial hit, coherent answer, TTFT,
   token/s, and recurrent companion restore.
5. **PASS:** Disk L2 Off produced request-local misses and slower true prefill;
   Disk L2 was restored On and saved afterward.
6. **PARTIAL:** the miss visibly showed runtime `Prefill 1024/3010`, and source
   tests distinguish `Checking cache` and `Restored`; the sub-second hit stages
   were too brief to capture as separate live frames.
7. **PARTIAL:** quit/relaunch persistence is proven for Qwen; broader
   intervening-pressure and non-adjacent eviction rows remain open.
8. **PARTIAL:** earlier diagnostic telemetry showed quota eviction, but this
   current Release run did not force a fresh quota eviction.

For every model row capture the full visible response, TTFT, token/s, matched
and total tokens, suffix size, disk hit/miss/store deltas, effective cache
topology, and companion restore/re-derive counters. Any stale text, reasoning
drift, loop, protocol marker leak, hidden-only answer, or length-cap stop fails
the row even if the cache counter increments.

TurboQuant-KV On is a separate opt-in matrix. JANGTQ weights are not
TurboQuant KV encoding. This emergency merge keeps the default policy unchanged
and does not claim TurboQuant coverage.

## 2026-07-23 final-current SSD-only partial-restore addendum

The final-current Osaurus follow-up used the Release app
`/private/tmp/osaurus-emergency-finalize-release-derived-20260723/Build/Products/Release/osaurus.app`
with bundle id `com.dinoki.osaurus.emergencyproof20260723`, executable
SHA-256 `51d8452082893fc1baf675950991394aeb4494bc185a91588310bf2018ac8028`,
and pinned vMLX `3d5aa12be1ad4a7e1492e062e6d136a4f31c7dfb`.
The app was operated through the visible UI with model selection and
Thinking-state controls in the picker. Settings had Prefix Cache On, GPU/Paged
Cache Off, Disk Cache On, cache codec Engine Selected, and SSM Re-derive On.
Evidence lives in `/tmp/osaurus-prefill-debug.log`,
`/tmp/osaurus-emergency-finalize-live-20260723-0120.log`, and
`/tmp/osaurus-reasoning-prompt-dumps-20260723-0120/`; no screenshot artifacts
are committed for this addendum.

Representative SSD-only rows on this final pin:

| Family | Scenario | SSD/cache evidence | Visible outcome |
| --- | --- | --- | --- |
| Gemma 4 MXFP8 rotating/full-attention | same-chat warmed send after startup store | restored `1729/1749`; post-answer warm row restored `1749/1762`; disk L2 hits advanced 0 -> 2 | exact `GEMMA-SSD-FINAL-OK`, TTFT 1.31s, 27.7 tok/s |
| Bonsai Qwen 3.5 hybrid | failed `file_read` and tool-result continuation | required-tool step restored `4185/4242`; tool-result continuation restored `4235/4399`; file-search continuation restored `4235/4421`; disk L2 hits advanced through the failed tool | visible failed tool card and terminal answer; no stuck queued/stop state |
| Bonsai Qwen 3.5 hybrid | same-chat after failed tool | restored `4497/4534`; disk L2 hits advanced 4 -> 5 | exact `BONSAI-AFTER-FAILED-TOOL-OK`, TTFT 0.87s, 31.6 tok/s |
| Bonsai Qwen 3.5 hybrid | new chat after failed tool | changed no-folder warm-up cold-stored a new prompt shape, then actual send restored `3005/3035`; disk L2 hits advanced 6 -> 7 | exact `BONSAI-CROSSCHAT-SSD-OK`, TTFT 0.81s, 31.5 tok/s |
| Ornith Qwen 3.5 hybrid JANG_4M | same-chat warmed send | vMLX trace restored `2040/2071` with `ssm=48`; next warm row restored `2064/2087` | exact `ORNITH-JANG4M-SSD-OK`, TTFT 0.37s, 69.2 tok/s |
| Laguna S 2.1 mixed full/rotating | post-relaunch same-root send | after relaunch, vMLX restored `1673/1732` from disk; later user prompt restored `1866/1915`; disk L2 hits advanced 0 -> 3 in the new process | coherent train answer at 47.0 tok/s, then parser stress output at 45.3 tok/s; no request hang |

Notes:

- The Bonsai failed-tool row is the current strongest evidence against the
  report that a failed tool universally resets KV/cache to zero. It does not
  prove every tool family or AppleScript child path.
- The new no-folder chat intentionally changed the tool/folder prompt identity.
  The cold warm-up for that changed prompt is not a cache failure; the actual
  following send restored the newly stored SSD prefix.
- The Laguna app-restart row proves the disk-backed path survives process
  restart for the mixed full/rotating cache topology on this pin. Its missing
  reasoning box is documented separately as model/bundle behavior because the
  rendered prompt did contain `<assistant><think>`.
- TurboQuant-KV remains default Off and unproven in this addendum. Paged RAM
  cache remains Off in the rows above; paged-hot-to-SSD-warm fallback is still
  an open matrix row.

## 2026-07-23 v3 scoped SSD-L2 proof — current source of truth

Current app/pin:

- app:
  `/private/tmp/osaurus-emergency-scoped-release-derived-v3b-20260723/Build/Products/Release/osaurus.app`
- bundle id: `com.dinoki.osaurus.emergencyscopedproofv320260723`
- SHA-256:
  `858cadab0912084e66314fc5ba6097e5c235753b9dc90642fb1ea7ef3a99c446`
- proof root:
  `/private/tmp/osaurus-emergency-scoped-proof-root-v3-20260723-0310`
- pinned vMLX:
  `7d6235316226ba9fe608018f86c463784e48b3d5`
- runtime trace:
  `/tmp/osaurus-prefill-debug.log`

The current v3 Computer Use proof ran with Prefix Cache On, GPU/Paged KV Off,
SSD/L2 Disk Cache On, and SSM rederive On. These rows therefore count only the
disk-backed partial restore path, not paged RAM cache.

| Family | Scenario | SSD-L2 evidence | Visible outcome |
| --- | --- | --- | --- |
| Bonsai Qwen 3.5 hybrid | tool-failure run with multiple failed tool rows | cold warm stored `3008`; user prompt restored `3005/3077`; successive tool continuations restored `3070/3124`, `3117/3817`, `3810/4051`, `4044/4101`, `4094/4451`, and `4444/4498`; disk L2 hits advanced 0 -> 7 | exact `BONSAI-V3-TOOL-FAIL-FINALIZED`, TTFT 0.96s, 31.9 tok/s, input unlocked |
| Bonsai Qwen 3.5 hybrid | same-chat follow-up after failed tools | no hidden assistant warm-up between final answer and follow-up; follow-up restored `3070/4518`; disk L2 hits advanced 7 -> 8 | exact `BONSAI-V3-AFTER-TOOL-FAIL-NOT-QUEUED`, TTFT 2.73s, 32.0 tok/s |
| Bonsai Qwen 3.5 hybrid | new chat | new-chat warm prefix restored `3007/3008`; visible prompt restored `3007/3035`; disk L2 hits advanced 8 -> 10 | exact `BONSAI-V3-NEW-CHAT-SSD-PARTIAL`, TTFT 0.93s, 32.0 tok/s |
| Bonsai Qwen 3.5 hybrid | process restart, same proof root | fresh process warm prefix restored `3007/3008` from disk; visible prompt restored `3007/3034`; disk L2 hits advanced 0 -> 2 in the new process | exact `BONSAI-V3-RESTART-SSD-PARTIAL`, TTFT 0.86s, 33.1 tok/s |
| Gemma 4 MXFP8 rotating/full-attention | new chat after earlier cold store | earlier cold warm stored `1729`; fresh-chat warm prefix restored `1725/1729`; visible prompt restored `1729/1751`; post-success warm restored `1751/1770` | exact `GEMMA-V3-NEW-CHAT-SSD-PARTIAL`, TTFT 0.82s, 29.6 tok/s |
| Laguna S 2.1 mixed full/rotating | Thinking-On arithmetic prompt | fresh-chat warm prefix restored `1670/1673`; visible prompt restored `1673/1706`; post-success warm restored `1842/1846`; disk L2 hits advanced through 6 | separate reasoning row plus `FINAL: 964`, TTFT 0.86s, 38.7 tok/s |

Interpretation for the user report:

- A new chat or app restart can still show a short prefill stage because the
  suffix after the restored SSD boundary must be processed. The pass condition
  is not "no prefill frames"; it is an identified disk boundary, small remaining
  suffix, coherent output, and no permanent queued/hung state.
- The v3 Bonsai rows specifically address the report where a failed tool seemed
  to reset cache state: failed tool continuations, same-chat follow-up, new
  chat, and same-root process restart all hit SSD partial prefixes with paged
  RAM cache Off.
- The v3 Gemma row addresses a rotating/full-attention family with the same
  SSD-only user setting.
- The v3 Laguna row addresses mixed full/rotating cache plus reasoning-parser
  output, but it is not a TurboQuant-KV or media/VL row.

Still open:

- TurboQuant-KV explicit On proof and cache-size growth;
- paged RAM cache On as hot tier with SSD as warm fallback;
- quota/eviction pressure;
- media/VL/audio companion-cache rows;
- AppleScript/Computer Use child-loop behavior and duplicate-edit/no-save;
- broader model matrix beyond the scoped Bonsai/Gemma/Laguna slices.
