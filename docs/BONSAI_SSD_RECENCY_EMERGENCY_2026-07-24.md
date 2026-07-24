# Bonsai SSD-recency emergency gate — 2026-07-24

Status: **PARTIAL — SOURCE TESTS PASS AT THE NEW vMLX SQUASH PIN; THE
REBUILT EXACT-PIN OSAURUS LIVE UI MATRIX IS PENDING**

This gate covers the user report:

- `it’s intermittent but cache resets to 0`
- `and it doesn’t go up sometimes, stays yellow`
- `feels like the model gets hung`
- `pressed cancel`
- `and kv cache resets to 0`

The acceptance lane is the real Osaurus macOS UI operated through Computer
Use. RunBench, API-only runs, source inspection, and cache counters without a
visible coherent result are diagnostic evidence only.

## Scope

This emergency PR may change only:

1. SSD-L2 eviction recency for a validated cache hit, including a hybrid
   KV-plus-recurrent companion group;
2. the Osaurus vMLX pin and focused integration coverage needed to consume that
   engine fix;
3. narrowly related lifecycle fixes only if the same published-app trace
   reproduces them and the rebuilt app closes them.

Gemma 4 QAT, broad parser cleanup, automatic routing, hardware guidance,
TurboQuant defaults, AppleScript behavior, and unrelated model-family work are
not part of this emergency diff.

## Current-source owner

Current engine baseline: vMLX `f50853514ee00365837be3301c91850ca7ed5877`.

The SSD cache advertises oldest/LRU-style quota eviction, but a successful
read does not update durable recency:

- `Libraries/MLXLMCommon/Cache/DiskCache.swift`: `fetch` validates and returns
  the KV payload without calling its existing `_touchEntryLocked` helper.
- `Libraries/MLXLMCommon/Cache/SSMCompanionDiskStore.swift`: `fetch` validates
  and returns recurrent state without refreshing the paired safetensors and
  metadata modification times.
- `Libraries/MLXLMCommon/Cache/CacheCoordinator.swift`: combined quota groups a
  KV entry with its linked recurrent companion and orders the group by the
  older of the KV timestamp and companion modification time.
- validated stable/system boundaries can skip their completion-time rewrite,
  so a frequently restored prefix has no later store operation that
  accidentally refreshes its timestamp.

The required fix is a successful-restore touch of the complete durable group,
not a Bonsai name check and not a forced prompt/sampler behavior change.

The missing read-side recency update predates the current release, but it
became directly user-visible under the combined hybrid quota introduced by
vMLX `bfd0defcab5ba42ea923de686b5230172036f3a9` on 2026-07-19. That quota
correctly treats linked KV and recurrent-state files as one eviction unit; its
ordering exposed that successful reads never made either half of the unit hot.

## Published 0.22.10 live correlation

App:

- published DMG:
  `/private/tmp/osaurus-02210-published-baseline-20260724/Osaurus-0.22.10.dmg`
- mounted app: `/Volumes/Osaurus/osaurus.app`
- bundle identifier: `com.dinoki.osaurus`
- runtime root:
  `/private/tmp/osaurus-bonsai-02210-baseline-root-20260724`
- selected local bundles:
  - `dealign.ai/Bonsai-27b-1bit-JANG-CRACK`
  - `dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`

Observed through the live UI and matched runtime trace:

1. Bonsai Ternary repeatedly restored the same 2,102-token stable prefix from
   SSD with paged RAM cache absent from the effective store path.
2. The SQLite `created_at` values for those entries remained at their original
   creation times after later successful hits.
3. A same-chat follow-up after manually cancelling a long answer visibly
   resumed at `Prefill 2161/4774` and completed
   `SAME_CHAT_AFTER_CANCEL_OK` at TTFT 8.57s / 28.2 tok/s. This disproves a
   universal cache clear on ordinary Stop: the previously completed prefix was
   restored, while the uncached partial assistant suffix still required real
   prefill.
4. During the same run, combined cache usage crossed the configured 10 GiB
   limit. The trace recorded:
   `before=10781123841 after=10466130665 max=10737418240 kvEvicted=1`.
5. Because successful reads had not refreshed durable recency, quota pressure
   could select a recently used stable prefix as an old entry. Its next use
   then has no SSD boundary and legitimately falls back to a cold `0/N`
   prefill, matching the intermittent user report.

This is source-and-live correlation for the eviction root. It is not
post-fix proof.

## Engine patch checkpoint

Merged vMLX revision:
`c6a2b4d05bec0958146d26fd351782b2fc3e2b13` (squashed from the
live-tested `7aa42711407d59dbd7e371a05c65396ff0f3855a` source tree).

The patch:

- refreshes the indexed KV row after a successful disk read without rewriting
  its safetensors payload;
- refreshes both recurrent-companion file timestamps without rewriting either
  payload;
- after an accepted hybrid restore, refreshes the linked KV and companion
  group with one timestamp under the combined-quota lock, including when
  recurrent state was served from in-memory L1;
- refreshes processor-proven stable system/tool checkpoints only after the
  architecture-specific runtime retains the fetched disk state; rollback
  paths do not receive the new stable-checkpoint touch;
- keeps KV and companion eviction atomic.

Current source-test evidence:

- the final retained-restore LRU rows: 3/3 passed;
- all tests in `DiskCacheTests.swift` at the preceding recency checkpoint:
  14/14 passed;
- `MLXLMCommon` with the final solo, batch, native-MTP, and diffusion call
  sites compiled successfully;
- `git diff --check`: passed.

These are focused source tests. The matching isolated Release Osaurus UI
evidence is recorded below.

## Separate lifecycle patch checkpoint

The published-app trace also exposed a distinct chat-lifecycle race; it is not
being conflated with SSD eviction:

- the pre-send model-switch/warm-up handshake previously ran in an unretained
  task, so Stop, reset, or session load could not reliably cancel it;
- after the awaited switch completed, that stale task could dispatch the turn
  captured from the previous chat;
- while the handshake was suspended, the composer appeared idle, allowing a
  second draft to be dropped or queued without a visible active-send state;
- an initial candidate retained and epoch-bound the handshake, but adversarial
  review then found that `load(from:)` also had to clear the outgoing chat's
  queued draft and one-off skill selection.

The current candidate retains and epoch-binds the handshake, invalidates it on
Stop/reset/session load/deinit, guards the dispatch boundary, exposes the
handshake as composer activity, preserves a reentrant draft in the existing
single-slot queue, and clears that queue plus one-off skill state when loading
another chat.

Focused current-source evidence:

- `ChatSessionStopTests`: 13/13 passed, 0 failed or skipped;
- the suite includes a cancellation-ignoring handshake, an old-chat queued
  draft carrying a one-off skill, a session load, and assertions that the
  loaded transcript remains unchanged and no stale model request dispatches;
- an additional same-controller reset row proves that releasing an old
  cancellation-ignoring model switch cannot cancel the incoming chat's newly
  scheduled warm-up;
- `git diff --check`: passed.

The Stop -> New Chat lifecycle race is also covered by the matching isolated
Release Osaurus UI evidence below.

Separately, cache persistence remains synchronous after the final visible model
delta and before terminal stream metadata. Existing traces can localize a
visible-answer spinner to that postflight region, but cannot yet distinguish
GPU synchronization, cache snapshot, SSM rederive/write, quota enforcement, or
advisor drain. No exact postflight stage is being claimed without a matching
live stall trace.

Sampled published-app tool steps did emit stream-drained and lease-released
events, with subsequent lease waits of 33–69 ms. Therefore an ordinary tool
step orphan is not being claimed as the eviction root.

## Rejected hybrid candidate and retained Stop-work follow-up

Adversarial review after the first exact-squash smoke found two narrower
contracts that the earlier proof did not close:

1. `DiskCache.fetch` refreshed KV recency as soon as a payload deserialized,
   before `CacheCoordinator` validated the recurrent companion required by a
   hybrid SSM/GDN restore. Missing or incomplete companion state rejected the
   candidate, but the unusable KV payload had already been made hot.
2. Stop cancelled the outer pre-send handshake without cancelling and
   retaining the controller-owned model-switch/warm-up work it awaited. A
   suspended switch could therefore resume and schedule a hidden warm-up, and
   a cancellation-ignoring warm-up could later resurrect the green warm claim.

vMLX PR #182 was squash-merged as
`7545ba66bf1060694ca4516cdf18768fef4b7c47`. The coordinator now fetches a
candidate without touching recency and refreshes KV, or the linked
KV-plus-companion pair, only after required companion validation succeeds.

Current source-test evidence:

- exact `c6a2b4d` baseline production source plus the two new rejected-candidate
  tests: 0/2 passed; both missing and incomplete companion rows changed the KV
  timestamp and failed;
- patched source: the same 2/2 passed;
- broader `DiskCache` selection: 17/17 passed;
- `MLXLMCommon` build: completed;
- corrected Osaurus Stop tests on `033fc0e2` production source: 12/14 passed,
  with exactly the hidden post-Stop warm-up and cancellation-ignoring late
  warm-state rows failing;
- patched Osaurus source: `ChatSessionStopTests` 14/14 passed;
- `git diff --check`: clean in both worktrees.

The Osaurus controller now invalidates the suspended switch epoch, cancels
scheduled/switch/warm-up work, keeps active tasks tracked until they actually
unwind, and refuses a cancelled engine completion permission to write `.warm`.
This is source/test evidence only until the exact
`7545ba66bf1060694ca4516cdf18768fef4b7c47` Release app completes the live
Stop/new-chat/tool/cache matrix below.

## Post-fix isolated Release UI proof

Exact app:

- source checkout: this Osaurus worktree with vMLX
  `7aa42711407d59dbd7e371a05c65396ff0f3855a`;
- Release app:
  `/private/tmp/osaurus-bonsai-final-7aa-app/osaurus.app`;
- isolated bundle identifier:
  `com.dinoki.osaurus.bonsaissdfinal7aa20260724`;
- isolated root:
  `/private/tmp/osaurus-bonsai-ssd-final-7aa-root-20260724`;
- executable SHA-256:
  `17b9e27abfb8d74ad670e56e41851a45708b68f6ea1723a4295bc306f0aa44ba`;
- runtime trace:
  `/private/tmp/osaurus-bonsai-ssd-final-7aa-live-20260724.log`.

Computer Use visibly saved and re-read the effective Settings -> Server ->
Cache state before model testing:

- Prefix Cache: On;
- Enable GPU Cache: Off;
- Disk Cache: On;
- Disk Cache Size: 1.5 GB;
- Codec: Engine Selected (TurboQuant was not forced on);
- Re-derive SSM State After Generation: On.

### Bonsai Ternary cancellation, new-chat, and restart

Bundle:
`/Users/eric/models/dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`.

1. The initial warm-up stored a 3,007-token stable checkpoint. The first chat
   restored boundary 3,005 with 24 tokens remaining and `ssm=96`, then visibly
   completed `BONSAI_FINAL_A` at TTFT 1.21 s / 31.4 tok/s.
2. A new chat warm-up restored boundary 3,007 with only 1 token remaining and
   `ssm=96`. Its request restored boundary 3,007 with 22 tokens remaining and
   visibly completed `BONSAI_FINAL_B` at TTFT 0.62 s / 31.6 tok/s.
3. A long response was allowed to produce 643 visible deltas, then Stop was
   pressed. New Chat was opened immediately and a send was issued in the
   outgoing-handshake race window. The incoming warm-up restored 3,007 tokens
   with 1 remaining; the request restored 3,007 with 23 remaining and visibly
   completed `BONSAI_FINAL_CANCEL_OK` at TTFT 0.70 s / 27.8 tok/s. Stop
   disappeared and the composer unlocked.
4. The app was quit and relaunched from the same executable and isolated root.
   The first post-restart warm-up restored boundary 3,007 with 1 token
   remaining and `ssm=96`, proving disk persistence rather than process-memory
   reuse. `BONSAI_FINAL_RESTART_OK` visibly completed at TTFT 0.69 s /
   32.3 tok/s and the composer returned to its terminal state.

### Adjacent architecture rows

All rows used a clean chat with paged RAM still Off and visibly reached a
terminal UI state.

| Bundle | SSD restore | Visible result |
| --- | --- | --- |
| `JANGQ-AI/Ornith-1.0-9B-JANG_4M` | new-chat warm-up boundary 3,007, 1 remaining, `ssm=48`; request boundary 3,007, 22 remaining | coherent factual answer, TTFT 0.37 s / 66.8 tok/s; Stop absent and input unlocked |
| `OsaurusAI/OsaurusAI--gemma-4-E2B-it-8bit` | rotating-SWA warm-up boundary 1,091, 4 remaining, `ssm=-1`; request boundary 1,095, 19 remaining | `GEMMA4_FINAL_A` at 0.42 s / 43.2 tok/s and new-chat `GEMMA4_FINAL_B` at 0.20 s / 82.9 tok/s |
| `JANGQ-AI/Laguna-S-2.1-JANG_2L` | warm-up boundary 2,841, 3 remaining, `ssm=-1`; request boundary 2,844, 19 remaining | `LAGUNA_FINAL_A` at 2.43 s / 42.4 tok/s and new-chat `LAGUNA_FINAL_B` at 0.77 s / 43.2 tok/s |

Every traced paged-store attempt reported
`effectiveKVLayers=0 blocks=0 payload=false`, so none of these hits came from
the disabled GPU-paged tier. Gemma and Laguna retained their required rotating
companion offsets. The 1.5 GB disk quota also evicted complete KV/companion
groups during the run without leaving a permanently yellow `Queued 0/N` or
`Prefill 0/N` state.

## Exact final-squash-pin smoke

After vMLX PR #181 was squash-merged, all Osaurus dependency and pin-guard
surfaces were changed to the resulting commit
`c6a2b4d05bec0958146d26fd351782b2fc3e2b13`. Xcode resolved that exact
checkout and built the Release app again.

Exact final-pin app:

- app:
  `/private/tmp/osaurus-bonsai-final-c6a2b4d-oldid-app/osaurus.app`;
- isolated bundle identifier:
  `com.dinoki.osaurus.bonsaissdfinal7aa20260724`;
- isolated root:
  `/private/tmp/osaurus-bonsai-ssd-final-7aa-root-20260724`;
- executable SHA-256 after the final ad-hoc seal:
  `ddbb639351f058e4dc6bc0e31803b0f1ee9a2f86816653a22b532915f90daf5c`;
- runtime trace:
  `/private/tmp/osaurus-bonsai-final-c6a2b4d-oldid-live-20260724.log`.

Computer Use visibly re-read the effective cache settings in that exact app:
Prefix Cache On, Enable GPU Cache Off, Disk Cache On, 1.5 GB, Codec Engine
Selected, and SSM re-derive On.

The reused proof root had gained a changed agent/onboarding configuration, so
the first final-pin warm-up correctly rejected the older stable identity and
stored a new 3,005/3,007-token boundary instead of reusing stale state. The
subsequent rows then proved the intended current-configuration path:

1. The first request restored boundary 3,005 with 26 remaining and `ssm=96`,
   visibly completed `FINAL_PIN_BONSAI_A` at TTFT 1.09 s / 31.2 tok/s, and
   returned to an unlocked terminal UI.
2. New Chat restored boundary 3,007 with 1 remaining; its request restored
   3,007 with 25 remaining and visibly completed
   `FINAL_PIN_BONSAI_NEW_CHAT` at TTFT 0.74 s / 31.2 tok/s. Stop disappeared.
3. The app was quit and relaunched from the same final-pin executable and
   root. The new process restored boundary 3,007 with 1 remaining and
   `ssm=96`; its request restored 3,007 with 25 remaining and visibly
   completed `FINAL_PIN_BONSAI_RESTART` at TTFT 0.73 s / 31.7 tok/s. Stop
   disappeared and the composer unlocked.
4. Final-pin quota rows evicted complete KV/companion pairs, including
   `before=1735023124 after=1300546508 max=1610612736` with
   `kvEvicted=1 companionEvicted=1`.
5. Every final-pin paged-store trace still reported
   `effectiveKVLayers=0 blocks=0 payload=false`.

### Honest limits

- This emergency gate proves the product-default paged-Off SSD-L2 path. It does
  not prove the separate paged-RAM-on recency policy.
- Bonsai Ternary is the reported regression reproducer used for the
  cancellation and restart stress. The final candidate did not repeat a
  separate Bonsai 1-bit UI row.
- Failed-tool recovery and broad tool/parser behavior remain separate campaign
  rows; they are not claimed by this cache/lifecycle diff.
- Osaurus is pinned to and was rebuilt/smoke-tested against the final vMLX
  squash commit `c6a2b4d05bec0958146d26fd351782b2fc3e2b13`; Osaurus CI is still
  required before merge.

No image files are to be added to Git history or a pull request. Local
screenshots may be used only for operator inspection.
