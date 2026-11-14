# SSD quota notice and indexed clear

Isolated from the combined RAM/vision branch onto main `0b33e116e5f5c4f3d65e80f736eed3a89df604a9`.
Engine remains `5b0c8e6b8b29a7ead21fe785688bc0621580cc62`.

The composer polls active coordinator quota and eviction counters. A notice is
claimed once per directory/effective quota per app launch, only in an eligible
idle foreground chat. Poll identity includes the chat and presentation gate.
Main's existing RAM/swap notices retain priority. Clear targets the measured
root; Settings Clear covers active roots plus the saved root.

Deletion is serialized with runtime cache IO and SQLite writers. Only indexed
KV payloads and explicitly linked recurrent companions are removed. Unknown
files, model directories, symlinks, the index, weights and volatile caches are
preserved. Errors are shown to the user. Clearing can make the next reply slower
while its cache rebuilds; it is not a speed optimization.

## Initial reproduction (historical)

PARTIAL: Release `a26300209a56a3f0bf5a10e84a9d23728d20f9c0` completed
native percentage/save, real quota eviction, popup and Settings Clear, refill,
streaming suppression and same-quota dismissal checks with the unchanged engine.
The resident clear reduced indexed bytes from 1,016,752,392 to zero while the
model remained resident; Settings Clear reduced 919,365,824 bytes to zero.
Clear preserved the unindexed sentinel; the engine later removed that invalid
safetensors sentinel on reload, a separate existing validation behavior.

That run exposed a stale notice after Disk Cache was disabled and saved. A
follow-up returned Blue at 20.1 tok/s with disk caching absent from the live
model, but the old 152 MB warning remained. The follow-up change invalidates
the notice on saved cache changes and accepts samples only from coordinators
built with the matching cache contract. Disabled caches cannot present notices.
It also discards a Clear result if its notice was invalidated while IO ran.
These checks were pending at that point; the correction verification below
records their later results.

Private artifacts: `ssd-isolated-resident-clear-timeline.json`,
`ssd-isolated-after-settings-clear.json`, `ssd-isolated-cache-off-turn.ax.txt`,
`ssd-isolated-cache-off-turn-runtime.json` under the 2026-09-14 vision evidence
directory. Run 1 exited cleanly with no owned processes left, 26.42 GiB peak
tracked footprint and unchanged 5.59 GiB swap. This is not physical 16 GiB proof.
Earlier combined-branch receipts do not substitute for this source and engine.
The full combined agent sweep (50 pass / 32 fail / 4 skip) remains on PR #2774;
no agent/model behavior change or claim is included here.

## Correction verification, 2026-09-15

SOURCE EVIDENCE: production source `a6ad60227a8d2a3fe6b380ccb50eba61cc8daf63`,
unchanged engine `5b0c8e6b8b29a7ead21fe785688bc0621580cc62`. Coordinator install
captures the same saved cache contract passed into configuration building;
notice polling filters for that contract. A saved cache change invalidates the
visible snapshot and poll identity. The existing resolver gates disabled tiers.

LIVE EVIDENCE: fresh isolated Release binary SHA256
`5735192382efb4877cbf6d1bdd1fe977328f93078ca4923362b83daf714d7242`.
Native runs 2 and 3 exercised Settings, Chat, save and relaunch using the local
`lmstudio-community/Qwen3.8-27B-MLX-6bit` qwen3_5 bundle. T=1, top-k=20,
top-p=.95, max tokens=16384; telemetry reported sampler unchanged. Main's tool
adapter supplied enable_thinking=false; this is not native-thinking proof.

- All 13 authored image questions across these two runs had matching visible
  answers, at 20.5–21.0 tok/s. Real clipboard image attachment and same-image
  history were exercised. Follow-up suggestions sometimes invented a grid;
  those suggestions are not counted as correct image descriptions.
- Real eviction at the 1,198,883,072-byte quota displayed the warning; generation
  hid it. Popup Clear removed 1,026,058,736 indexed bytes. The collector shows
  zero bytes while the model remained resident, before later idle unloading.
- Settings Clear removed a 358,905,942-byte refill; an unindexed text sentinel
  retained its hash. Later turns refilled the cache and completed.
- Warning visible -> Disk Cache off -> Save removed the old notice. The next
  turn returned Red at 20.6 tok/s with disk_l2_enabled=false and the disk store
  disabled. This closes the observed stale-notice row from run 1.
- Saved 10%, quit/relaunched and read 10% in Settings. The loaded effective
  quota was 185,286,803,456 bytes, reflecting the available-disk ceiling. Both
  post-relaunch turns completed and the warm turn recorded a cache hit.
- Dismiss then a fresh same-model pasted-image chat caused additional quota
  evictions without repeating the notice. Blue/Red answers completed at
  20.9/20.6 tok/s. Final isolated profile restored 10%.

Runs 2/3 exited zero with no owned processes left; tracked physical-footprint
peaks were 23.42/24.42 GiB, swap 5.58->5.58/5.58->5.57 GiB and normal pressure.
The private receipts are `ssd-isolated-a6ad-native-receipt.json`,
`ssd-isolated-a6ad-cache-timeline.json` and
`ssd-isolated-a6ad60227-release-receipt.json` in the existing evidence directory.
PNG/AX/runtime artifacts and hashes are listed in the native receipt.

CI run https://github.com/osaurus-ai/osaurus/actions/runs/35041596610 completed
successfully at a6ad60227. Quota-notice tests 5/5, purge tests 6/6 and settings
wiring tests 14/14 passed. Evals harness unit tests passed 350/350. Core's XCTest
portion recorded 417 tests, 8 skipped and zero failures; its Swift Testing
suites also completed successfully. These are separate from local model evals.

The full local CacheProof suite completed 14/14 cache-contract cases with zero
case-level failures/skips. Artifact: `evals-ssd-isolated-a6ad60227-cache/CacheProof.json`
and `ssd-isolated-a6ad-cacheproof-receipt.json`. Harness SHA256
`6278c77001506a465c604b03ab0e5682ee8ec0088a16f304e08fb5e247a294cc`;
model `OsaurusAI/gemma-4-E2B-it-8bit`, revision
`433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, bundle T=1/top-k=64/top-p=.95,
with authored per-case token budgets and thinking-toggle inputs. Runtime showed
3 KV + 12 rotating layers, disk-backed restore, paged RAM off, TurboQuant
layers zero. Suite totals:30 disk hits,129 stores; decode94.4–100.8 tok/s;
supervisor peak1.90GiB, swap5.56GiB unchanged, exit0/cleanup0.

Qualification limits: seven fixture turns stopped at their output caps, so the
raw cache scores do not certify those turns' completion/coherency. Hybrid-only
SSM assertions were conditionally skipped on this non-SSM model. No claim of
physical16GiB admission, native-thinking behavior, all-model vision quality or
SSM companion hits follows from this SSD-only evidence. The 13 native UI answers
above completed separately. The pre-existing sequential numeric field formatter
changed a typed0.005 into5 in run1; full-value paste saved0.005 correctly. This
PR does not modify that formatter. No source generation defaults, parser,
engine pin, delegation or RAM-admission policy changed in this isolated lane.
