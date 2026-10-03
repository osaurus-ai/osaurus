# GLM vision and complete cache restoration follow-up

The broad installed-model inventory in #2772 exposed GLM prefill rank errors,
second-image rejection and incomplete hybrid cache restoration. This change
pins vmlx-swift#475 at `6244dfe2c8715ae0ff68c43afb596b987573ade6`.
It does not introduce a model-name allowlist or change sampling settings.

The engine processor preserves ordered media patches and placeholder IDs,
normalizes the generic generation token rank, and handles decoded video
frames without opening a fake asset. A versioned `DiskCacheStateProviding`
contract persists model-owned tensors and metadata. All six production disk
restore callers stage payload validation and reject zero restoration before
applying arrays in place. The generation coordinator subsequently validates
all layer offsets against the prompt boundary and resets on mismatch.

## Source and observed evidence

Source: engine `ffee904d4f4f0680aa6a2c39c3dedff9cedae010`, host
`3fd0e69a35d42c987eb80d841249ada0c2710c2b` with the isolated local dependency
used for the initial tests. The public dependency pin in this change points
to the same engine source. No absolute dependency path is committed.

Local evidence root:
`/Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14/`.

- 65 focused tests passed: 13 GLM input/copy, 20 TQ serializer, 8 ZAYA,
  10 Mamba, 5 architecture damage matrix, 5 QSA persistence, 1 token iterator
  restore progress and 3 hybrid restore boundary tests.
  Receipts: `glm-final-shared-v7-receipt.json`,
  `glm-final-pipeline-regressions.json`.
- Real-weight follow-up: 11 cases across 10 architectures, **10 passed,
  1 failed**. Each case exercises seven image/replay/cache/stream/agent/history
  requests. All 11 cases accepted three complete disk restores; ZAYA still
  answered red for the changed blue image after history. Cache admission alone
  is not answer correctness. `glm-v7-architecture-receipt.json` and
  `glm-v7-architecture-summary.json` retain every row.
- Both GLM MTP and non-MTP completed all seven requests, with accepted restores
  at boundary 55 across all 45 layers. Measured throughput was approximately
  15–16 tok/s; physical footprint was full-model size, approximately 95–98 GiB.
- Release UI app SHA256:
  `53108875528cb782f2d365dd4496adb141a6071cd94d1c4a42e7f2af9d94ba6d`.
  Real native file-picker attachments: GLM answered Red, a retained-image
  follow-up was cancelled through Stop, then a new attachment in the same
  history answered Blue and finished normally. The cancelled row had no
  visible answer and is not promoted. A 111-token disk boundary restored all
  45 layers. UI throughput was only 0.7–1.3 tok/s; measured peak physical
  footprint was 99902.315 MiB. This is not low-RAM or performance qualification.
  `glm-ui-v7-receipt.json`, `glm-ui-history-v7.json`, and
  `glm-ui-v7-footprint.jsonl` retain results and the interrupted turn.
- LFM UI initially answered blue to an unqualified fills-image question for
  a red background with a blue center. Retained as failed/ambiguous. Explicit
  background questions then returned red and changed-image blue at 269.7 and
  326.9 tok/s. The initial answer is not erased by those follow-ups.

The original all-installed run remains **25 passed / 7 failed / 1 crashed**
from 33 attempted bundles and 79 inventoried bundles. Its other failures are
listed in `INSTALLED_VISION_QUALIFICATION_2026_09_14.md`. Earlier AgentLoop:
24 passed / 19 failed / 4 skipped; Frontier: 3 passed / 36 failed under a
local self-judge. No manual score promotions.

## Pending and limits

The public-pin build at engine `ffee904d` completed the 33-case installed
sweep: 28 passed, four failed, and one GLM MTP case was interrupted. The
four failing bundles were Ornith 9B 2D, both ZAYA quantizations, and CRACK
Qwen3.8 27B 2D; all had failed earlier. Five declared-vision bundles were
rejected by inventory evidence, with zero header exclusions. Receipt:
`glm-public-full-matrix-receipt.json`. The new process-policy candidate
requires another full matrix and Release UI model-switch run. No
blanket family, low-RAM, video-understanding or regression-free claim is made.
Video has numerical decoded-frame input coverage only.

The UI model switch exposed an unlimited load plan retaining the preceding
model's 70% process limit. The engine now applies the existing shared
`requiresUncappedResidentPools` policy instead of a separate DSV4-only
check. The new test reproduces six failed GLM assertions before the change.
Afterward, all 42 load-configuration tests, 65 cache/input tests and nine
wired-memory/safety tests passed (`glm-resident-policy-green-2.log`,
`glm-policy-regressions.json`). The native ceiling formula and wired reserve
are unchanged. Both compared CLI builds already had the native 95% ceiling,
so this mismatch does not explain their full speed variance. The final UI
transition and public-pin matrix remain pending.

Engine CI has four successful Linux builds, advisory repository-wide style
failure, and queued self-hosted Mac/CUDA jobs. The repository runner API
reported zero registered runners. This is not a green CI claim.

## September15 admission edge cases

The next pin is `441d9a8e8df19f4c364b50903cbc62b4059639c9`, adding the shared
processor-registration/override contract. Local vision evidence now rejects unknown
processors and malformed tensor dtype/payload length with overflow-safe arithmetic.
The three false positives were reproduced by the old executable: five of eight
admission probe checks passed. New regressions and corrected-runtime proof are
pending; the unchanged local build supervisor refused at7.48GiBswap>2GiB.
See `VISION_IDLE_EDGE_CASE_AUDIT_2026_09_15.md` for exact sources, independent parser
oracle, storage-dtype inventory, full prior scores and remaining UI/settings gates.
The prior combined CI and model sweep do not verify these new changes.
