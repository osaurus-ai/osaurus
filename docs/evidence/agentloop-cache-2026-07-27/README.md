# Agent-loop finalization and disk-cache proof — 2026-07-27

Status: `PARTIAL`. The exact merged-pin Release app passed the Gemma 4
terminal lifecycle and effective-cache-settings smoke. A broader Release app
whose tested vMLX head is changed-path tree-identical to the squash-merged pin
also passed terminal lifecycle rows for Gemma 4, Bonsai/Qwen-family, and
Laguna, but the Bonsai instruction-fidelity row and Laguna reasoning-emission
row remain explicitly partial. This document deliberately separates source
tests, model-backed evals, and live UI evidence.

## Source identity

- Osaurus base: `5929b0d9b7021b1f7b0ca506833816b4716fa84e`
  (`osaurus-ai/osaurus#2178`, merged).
- vMLX pin: `64b6ca2433c12af2dd6955f317366f0f9626e061`
  (`osaurus-ai/vmlx-swift#189`, squash-merged).
- Osaurus branch: `codex/agentloop-cache-evals-20260727`.

The model-backed JSON reports were captured on PR #189 head
`9fd41573448eef2411725dcb04e2efce9ad96c79`. A changed-path tree comparison
between that tested head and squash commit `64b6ca24` was empty; the focused
source suites below were then rerun against the exact merged pin. The Release
app row below names its own build identity separately.

The agent-loop ownership change is in merged PR #2175: valid final prose is
terminal even when a display-only Todo remains unchecked. This branch does not
add a continuation nudge, forced final answer, forced reasoning delimiter,
sampler override, or model-family prompt patch. It adds a scoreable regression
case and cache proof instrumentation on top of that runtime behavior.

The branch was rebased after the live campaign when upstream advanced from
`3c694182` to `5929b0d9`. That intervening commit changes only
`Packages/OsaurusCore/Resources/Localizable.xcstrings`; it does not change the
agent loop, eval runners, cache instrumentation, model runtime, or vMLX pin.
The final Release smoke below is rebuilt from the rebased current source.

## Source-test gates

| Gate | Result | Evidence |
|---|---:|---|
| Focused OsaurusCore AgentLoop/Todo/streaming suites | 186/186 passed | Exact merged vMLX pin, fresh DerivedData; `Test-OsaurusCoreTests-2026.07.27_03-22-02--0700.xcresult` |
| New OsaurusEvals decoding/compatibility tests | 3/3 passed | `AgentLoopCacheProofCampaignTests` |
| vMLX TokenIterator disk restore regression | 1/1 passed | PR #189 source checkout |
| vMLX CacheCoordinator | 13/13 passed | PR #189 source checkout |
| vMLX DiskCache | 16/16 passed | PR #189 source checkout |
| vMLX canonical cache boundaries | 7/7 passed | PR #189 source checkout |

The first OsaurusCore attempt reused stale DerivedData and failed before tests
because of a stale Sentry PCM/header mismatch. It is not counted. The table
uses the fresh isolated result only.

## OsaurusEval AgentLoop scores

Case:
`agent_loop.final-after-success-with-pending-todo`.

| Model | Score | Steps / tools | TTFT | Decode | Prefill | Peak footprint | Cache delta | Classification |
|---|---:|---:|---:|---:|---:|---:|---|---|
| Gemma 4 26B A4B JANG_4M | 3/3 | 3 / 2 | 143 ms | 35.3 tok/s | 17,346 tok/s | 22,507 MB | L2 +2 hits / +5 stores | `PASS` |
| Bonsai 27B Ternary JANG | 3/3 | 3 / 2 | 236 ms | 17.9 tok/s | 7,302 tok/s | 6,788 MB | L2 +2/+4; SSM +2 hits | `PASS` |
| Ornith 1.0 9B JANG_4M | 0/3 | 2 / 1 | 235 ms | 35.5 tok/s | 16,347 tok/s | 4,210 MB | L2 +1/+3; SSM +1 hit | `FAIL` — skipped the explicitly required Todo, but did not reopen or loop after final |
| Ornith 1.0 35B JANG_4M | 2/3 | 3 / 2 | 265 ms | 21.4 tok/s | 13,572 tok/s | 15,988 MB | L2 +2/+4; SSM +2 hits | `FLAKY` — one trial repeated Todo before the side effect; no post-final loop |
| Laguna S 2.1 JANG_4M | 3/3 | 4 / 3 | 122 ms | 26.6 tok/s | 6,999 tok/s | 12,786 MB | L2 +3/+6 | `PASS` |

The score requires `todo -> file_write`, the exact file side effect, one
`REMINDER_CREATED` final, `finalResponse`, at most six model steps, and no
“still working” or “in progress” prose. A model that skips Todo is not promoted
merely because it stops cleanly.

## OsaurusEval Frontier score

| Model / case | Score | Iterations / calls | Tool chain | TTFT | Peak footprint | Cache delta | Classification |
|---|---:|---:|---|---:|---:|---|---|
| Gemma 4 26B A4B JANG_4M / `frontier.kitchen-sink` | 1/1 | 14 / 15 | Todo, file reads, DB create/insert/query, file write, Todo, shell, share, Todo, complete | 330 ms | 27,351 MB | L2 +14 hits / +16 stores | `PASS` for behavior; decode tok/s unavailable because this tool-complete path emitted no visible-token stat |

## Structured cross-session disk-L2 scores

Case:
`cache_proof.cross-session-partial-disk-restore`.
Paged RAM was off and the disk-L2 lane was on. Passing requires a structured
vMLX `cacheRestore` event with `tier=disk`, at least 128 restored tokens, a
nonzero divergent tail that is still prefilled, nonempty visible output, and
closed reasoning. Aggregate counters or UI color cannot pass this row.

| Model | Score | Restore / remaining | TTFT cold -> warm | Prefill cold -> warm | Decode | Peak footprint | Companion evidence | Classification |
|---|---:|---:|---:|---:|---:|---:|---|---|
| Gemma 4 12B JANG_4M | 3/3 | 240 / 21 | 525 -> 429 ms | 1,059 -> 2,484.5 tok/s | 35.9 tok/s | 6,313 MB | Full attention | `PASS` |
| Laguna S 2.1 JANG_4M | 3/3 | 240 / 22 | 890 -> 549 ms | 431 -> 1,041 tok/s | 26.9 tok/s | 9,554 MB | Full attention | `PASS` |
| Bonsai 27B Ternary JANG | 2/3 | 245 / 21 | 1,205 -> 915 ms | 443.8 -> 887.6 tok/s | 18.2 tok/s | 3,028 MB | SSM +1 hit | `FLAKY` — one trial reasoned to the 512-token cap without a visible final |

The Bonsai row was first run with a 64-token diagnostic cap and failed 3/3 in
reasoning-only length stops despite proving the restore. The case now uses 512
tokens so the cache test does not manufacture an artificial reasoning
failure. One of three 512-token trials still hit the cap, so the model row
remains `FLAKY`; the runtime is not silently clamped or prompted around it.

## Full Gemma disk-only CacheProof suite

Exact score: **6/9 cases passed**.

Passing cases:

- cross-session partial disk restore;
- disk-L2 lane persists;
- five-turn footprint growth (731 MB, L2 +4 hits / +16 stores);
- hybrid companion and hybrid disk cases, with their hybrid-only gates
  explicitly skipped on this full-attention topology;
- thinking-toggle boundary.

The three failures are older RAM-prefix-counter assertions:

- identical replay restored 22 tokens from disk and prefetched 35, but required
  a RAM `kvPrefixHitsDelta`;
- second-turn reuse restored 36 and prefetched 37, but required a RAM hit;
- three-turn reuse restored 36/69 and prefetched 33/30, but required two RAM
  hits.

Gemma rotating-SWA is paged-incompatible in this run and correctly used disk
L2 with paged RAM off. These rows therefore expose stale eval semantics rather
than evidence that disk restore failed. They remain reported as failures until
the legacy cases become tier-aware; this PR does not relabel them as passes.

## Raw text evidence

The `raw/` directory contains the exact JSON reports behind every table. It
contains no screenshots, user credentials, API keys, or absolute home paths.

## Release-app live UI evidence

Build:
`/private/tmp/osaurus-agentloop-cache-release-derived-20260727/Build/Products/Release/osaurus.app`.
The app used the isolated bundle id
`com.dinoki.osaurus.agentloopcacheproof20260727` and isolated test root
`/private/tmp/osaurus-agentloop-cache-live-root-20260727`.

Before generation, Settings -> Server -> Cache visibly showed:

- prefix cache on;
- paged GPU/RAM cache off;
- disk cache on with a 10.0 GB limit;
- cache codec `Engine Selected` (TurboQuant was not selected);
- SSM re-derivation on;
- active Gemma KV window 65,536 tokens.

After the live rows, Settings -> Server -> Live Activity showed one loaded
model, zero active/queued slots, engine `Accepting requests`, TurboQuant
compressions 0, and Disk L2 `5 hits / 17 misses / 14 stores`. These aggregate
counters corroborate activity but do not replace the structured restore events
in the CacheProof scores above.

All three rows used the real chat UI, selected the same isolated workspace,
and requested a two-item Todo with item 1 completed by `file_write` and the
optional item left pending.

| Model | Thinking setting / UI | Tool and Todo lifecycle | Final lifecycle | Follow-up | Classification |
|---|---|---|---|---|---|
| Gemma 4 26B A4B JANG_4M | On; separate reasoning card closed after 5.5 s on an additional arithmetic turn, with no inline `<think>` | Todo stayed 1/2; one finished file-write card; exact 16-byte file | One `REMINDER_CREATED`; Stop disappeared and input unlocked; 0.45 s TTFT, 66.2 tok/s | Exact `FOLLOW_UP_OK`; 0.60 s TTFT, 65.1 tok/s; terminal UI | `PASS` |
| Bonsai 27B Ternary JANG (Qwen family) | On; multiple separate reasoning cards closed, with no inline `<think>` | Todo stayed 1/2; one finished file-write card; exact 16-byte file | Stop disappeared and input unlocked, but the model expanded the requested one-token final into a checklist/report; 1.35 s TTFT, 40.7 tok/s | Exact `FOLLOW_UP_OK`; reasoning closed after 2.0 s; 3.06 s TTFT, 34.0 tok/s; terminal UI | `PARTIAL` — no post-final loop, but final instruction fidelity failed |
| Laguna S 2.1 JANG_2L | On; no reasoning block emitted for these simple turns | Todo stayed 1/2; one finished file-write card; exact 16-byte file | One `REMINDER_CREATED`; Stop disappeared and input unlocked; 0.65 s TTFT, 45.1 tok/s | Exact `FOLLOW_UP_OK`; 1.15 s TTFT, 39.6 tok/s; terminal UI | `PARTIAL` for reasoning proof; `PASS` for agent-loop finalization |

The Gemma arithmetic turn visibly opened and closed a reasoning card and
returned the coherent result 1776. Laguna's toggle was visibly on, but its
template/model chose not to emit reasoning for the simple file and follow-up
turns; the toggle alone is not counted as reasoning proof.

No row reopened after final prose, repeated a completed side effect, retained
the Stop control, or blocked the follow-up. The Bonsai row is intentionally not
promoted to a full pass because its final text did not obey the exact-output
instruction even though the tool side effect and terminal state were correct.

### Exact current-main, squash-merged-pin Release smoke

The final current-source smoke used:

- app:
  `/private/tmp/osaurus-agentloop-cache-mergedpin-release-derived-20260727/Build/Products/Release/osaurus.app`;
- bundle id:
  `com.dinoki.osaurus.agentloopcacheproofmerged20260727`;
- embedded vMLX revision:
  `64b6ca2433c12af2dd6955f317366f0f9626e061`;
- executable SHA-256:
  `f2e1c1ae63069a482378336b6748e46f08e81a899d03f3c825a4c741cd8814e4`.

The real chat UI ran Gemma 4 26B A4B JANG_4M with Thinking visibly on.
The first turn visibly ended with Todo `1/2`, exactly one finished
`file_write` card, exact final `CURRENT_MAIN_FINAL`, closed reasoning cards,
TTFT 0.47 s, 67.8 tok/s, no post-final output, Stop removed, and input
unlocked. The written file was exactly 16 bytes (`CURRENT_MAIN_OK\n`) with
SHA-256
`2e5f668bb9e2548b033f7824e811700ca14667c8f496aef45e1cbe626ffa12d8`.

The same live chat then completed the exact follow-up
`CURRENT_MAIN_FOLLOW_UP`; its 355-character reasoning card closed after
1.3 s, TTFT was 0.91 s, decode was 81.1 tok/s, Stop disappeared, and input
unlocked. The pending optional Todo remained display state and did not reopen
the model loop.

In that exact app, Settings -> Server -> Cache visibly reported active Gemma
KV 65,536 tokens, prefix cache on, paged RAM off, disk L2 on at 10.0 GB,
codec `Engine Selected` (TurboQuant not enabled), and SSM re-derivation on.
Settings -> Server -> Live Activity then showed zero active slots, zero
queued, one loaded/cache-enabled model, engine `Accepting requests`,
TurboQuant compressions 0, and Disk L2 `5 hits / 45 misses / 11 stores`.
These counters corroborate the exact app lifecycle but do not replace the
structured per-turn disk-restore scores above.
