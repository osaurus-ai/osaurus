# Runtime follow-ups — 2026-07-29

Status: `PARTIAL` — fixes for the four reported issues are committed in the
coordinated Osaurus and vMLX branches. Focused source/runtime tests, the full
deterministic harness, the raw Ornith AgentLoop/AgentLoopFrontier lanes, and
the affected exact-pin isolated Release live-UI rows are complete. Committing
and pushing this evidence does not alter the tested runtime code; fresh GitHub
checks/review on the resulting PR head and the merge audit remain. This work
is therefore not yet described as release-ready or regression-free.

## Exact source baseline

- Osaurus baseline: `f33c9eca144a84beb4bbde705af649bed060acf8`
- tested Osaurus runtime code head: `e810eda8a1df72b48cf2eb515e6d3e49522cb504`
- baseline Osaurus vMLX pin: `439f53694f3d630663e97612c264ae73e499121a`
- follow-up vMLX PR: `osaurus-ai/vmlx-swift#195`, merged as
  `cf50cf9cc424726df93187f5542faf03bacdcc95`
- tested Osaurus vMLX pin: `cf50cf9cc424726df93187f5542faf03bacdcc95`
- Paged RAM cache: off for the reported cache row
- host/toolchain: macOS 26.4 (`25E246`), Apple Swift 6.3.1
- Local bundles:
  - `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-JANG_4M`
  - `/Users/eric/models/JANGQ-AI/Ornith-1.0-9B-MXFP8`
  - `/Users/eric/models/dealign.ai/Laguna-S-2.1-JANG_2L-CRACK`
  - `/Users/eric/models/dealign.ai/Laguna-S-2.1-JANG_4M-CRACK`
  - `/Users/eric/models/dealign.ai/Laguna-S-2.1-JANG_6M-CRACK`

## Automated proof summary

| Lane | Result |
| --- | ---: |
| vMLX GatedDelta precision source contract | 1/1 passed |
| vMLX tiny Qwen 3.5 VLM forward/cache dtype | 1/1 passed |
| vMLX linked oversized-boundary quota regression | 1/1 passed |
| vMLX complete focused `DiskCache` lane | 18/18 passed |
| Osaurus `AgentToolLoop` / `AgentLoopBudget` / `RuntimePolicy` regressions | 205/205 passed |
| Osaurus iteration-cap wrap-up regressions | 2/2 passed |
| Osaurus complete focused Seatbelt suite | 15/15 passed |
| Osaurus four-surface pin guard correction | 3/3 passed across 2 suites |
| OsaurusEvals Swift harness | 299 passed in 36 suites; 3 host-sampler rows skipped by platform/resource guards |
| OsaurusEvals deterministic lanes | 101/101 passed across 8 suites |
| Ornith local `AgentLoop` raw lane | 33/40 passed; 4 failed; 3 skipped; 0 errored |
| Ornith local `AgentLoopFrontier` raw lane | 21/39 passed; 18 failed; 0 skipped; 0 errored |
| OsaurusCore production Release build | passed in 528.55 seconds |

The exact-pin focused commands covered the Seatbelt integration, Laguna local
metadata paths, external model discovery, iteration-cap source policy, agent
tool-loop terminal behavior, and runtime policy. The real UI lifecycle and
the model-dependent AgentLoop / AgentLoopFrontier lanes were run locally; the
raw non-perfect model scores are preserved and attributed below rather than
summarized as passing. The PR's cold CI remains a separate final-head gate.

The first GitHub `test-core` attempt ran the runtime suites but failed five
source-policy assertions because the initial pin commit updated
`Packages/OsaurusCore/Package.resolved` while missing both Xcode workspace
`Package.resolved` files and their two expected-revision guard constants.
Xcode regenerated both workspace pins and origin hashes at the same merged
vMLX SHA; the two focused guard suites then passed `3/3`. This was pin hygiene,
not a model/runtime assertion failure. The final-head core rerun is the merge
gate.

Investigated eval-reporting discrepancy:
`agent_loop.spawn-batch-two-different-local-workers` completed successfully
with the requested Nanbeige and Ornith child models and both exact tokens, but
its per-case telemetry reported impossible negative deltas (`SSM -75 hits`,
`disk L2 -75 hits / -838 misses / -140 stores`) across the model handoff.
`Packages/OsaurusEvals/Sources/OsaurusEvalsKit/EvalRunner.swift` subtracts
before/after snapshots from `ModelRuntime.batchDiagnosticsSnapshot()`, while
`Packages/OsaurusCore/Services/ModelRuntime.swift` aggregates only the model
summaries resident at that instant. A different-model unload/reload changes
the represented model set, so subtracting the two signed aggregates can be
negative even though no cache counter decremented. The row is not counted as
cache proof. Correcting cross-model eval-report continuity is deferred to a
focused eval-telemetry follow-up because it is not one of these four runtime
fixes and does not invalidate the successful child executions.

### Raw model-eval attribution

No remote judge key was available, so the local bundle self-judged rubric
conditions; raw reports and transcripts are retained for manual attribution.

- `AgentLoop`: `33/40` passed, `4` failed, `3` skipped, `0` errored.
  `answer-direct-no-complete` produced the correct TCP/UDP prose but failed
  only because the self-judge output was empty/unparseable. The three skipped
  AppleScript delegation rows withheld their required tools because no
  AppleScript-capable model was installed. The genuine model-task misses were
  `compaction-stress` (four of five reads and no compaction),
  `idempotent-already-satisfied` (an invalid `complete` call before a correct
  final, without corrupting the already-correct file), and
  `todo-discipline-multistep` (five of seven todo items, invalid todo syntax,
  and the gamma edit left incomplete).
- Runtime-relevant AgentLoop rows passed: `wrap-up-on-budget` finalized
  without fabricated work or private sentinels; the same-model two-worker
  spawn batch settled both workers at effective concurrency two; and the
  Nanbeige + Ornith different-local batch completed in two serialized model
  waves with both exact tokens and no `Unsupported model type: nanbeige`.
- `AgentLoopFrontier`: `21/39` passed, `18` failed, `0` errored. Compaction was
  never triggered in `constraint-retention-carry-token`,
  `constraint-retention-format-marker`, `constraint-retention-no-redo`, or
  `constraint-retention-ordering-rule`, although their requested outcomes
  were otherwise correct. `constraint-retention-do-not-touch` preserved the
  protected file but omitted its summary; `compaction-under-load` stopped
  after two reads. The remaining deliverable/model-quality misses were
  `agent-db-workflow`, `audit-file-write`, `code-review-findings`,
  `csv-aggregate-by-region`, `exact-bytes-version-contract`,
  `implement-from-spec`, `kitchen-sink`, `long-horizon-project`,
  `multi-file-refactor-with-todo`, `no-false-clarify`, `ordered-procedure`,
  and `self-schedule-followup`.
- Across both raw lanes there were no errored rows, runtime crashes, hangs,
  parser exceptions, U+FFFE leaks, exclamation degeneration, unsupported-model
  errors, or protocol-debris finals. The genuine failures above remain model
  task-quality evidence; they are not relabeled as runtime passes.

Raw artifacts:

- harness log: `/private/tmp/osaurus-pr2235-final-evidence/evals-harness-e810.log`,
  SHA-256 `8588a9f93ed0b55e48e5e4266fcc54d22f1d46b291bafd321bbb65f95b2f417f`
- deterministic log:
  `/private/tmp/osaurus-pr2235-final-evidence/evals-deterministic-e810.log`,
  SHA-256 `3ac8d018dcac39989fe72868b71157bd5b33db144c47386ea824af39ea3e8ff0`
- AgentLoop combined log:
  `/private/tmp/osaurus-pr2235-final-evidence/agentloop-ornith-e810.log`,
  SHA-256 `14ee1e8470397ea7136d62b8fc0f16ac0092ed436c6c0cc7b7a4bf353df37a6f`
- AgentLoop report SHA-256
  `60f318f95e205cf883adbe33b78a40d981996efda096913fde551ae105c082af`;
  AgentLoopFrontier report SHA-256
  `2d31cc01f6dc26d7ba6d28f4dcffe4f048a8df211108a3dc7e98c5ff53161415`

### Pre-existing broad-guard debt

The umbrella `assert-osaurus-pr-hygiene.sh` is not a green signal on this
branch, but its failed source assertions are not changes made by this PR. The
same individual guards were run from a clean archive of base
`f33c9eca144a84beb4bbde705af649bed060acf8` and produced the same failures:

- `assert-server-settings-runtime-wiring.sh`: seven missing batching/
  memory-safety UI/runtime text contracts;
- `assert-osaurus-no-forced-behavior-pr.sh`: a false-positive match on the
  existing defensive comment `rely on parser repair` in
  `CapabilityTools.swift`;
- `assert-tool-choice-required-routing.sh`: one missing named-tool source-text
  contract; and
- `assert-model-tool-capability-surfaces.sh`: two missing family-guidance
  source-text contracts.

This PR changes none of the files named by those failures. The vMLX readiness
wrapper also reports two unrelated Gemma 4 unified-media/test expectations;
the exact baseline-to-tested vMLX diff changes GatedDelta, disk/companion cache
coordination, RunBench, and their focused tests, but no Gemma 4 source or test
file. Pin equality, the pinned checkout SHA, keychain-free checks, cache/
Responses wiring, reasoning routing, HTTP cancellation, and hidden-sampler
guards all pass. The broad-guard debt is explicitly deferred rather than
silently repaired in this four-issue PR; it is not used as favorable proof,
and the fresh required GitHub checks still gate merge.

## 1. Ornith 1.0 9B JANG_4M exclamation degeneration

Observed behavior: after a file read and repeated database/tool turns, the
model produced a very long run of `!` characters instead of a coherent final.

Source finding and fix:

- The duplicated Qwen 3.5 GatedDelta implementations in the text and VLM
  routes stored decay, beta, and recurrent state at the query dtype. That
  diverged from the upstream full-precision recurrent-state correction in
  `mlx-lm` PR 997 and `mlx-swift-lm` PR 317 (merged as `93cf322`).
- Both routes now keep decay, beta, recurrent state, and state updates in
  float32; output is cast back to the query dtype. The strict MTP path retains
  its intended per-step BF16 value rounding while keeping a float32 state
  container.
- Focused source-contract test: `1/1` passed.
- Tiny VLM forward/cache-state test: `1/1` passed and asserts float32 recurrent
  state.

Current patched-worktree non-UI replay evidence:

| Seed | Cache | Result |
| ---: | :---: | --- |
| 1 | on | `stop`; valid tool call; disk KV hits `2`; companion-state hits `2`; zero exclamation run |
| 1 | off | `stop`; valid tool call; zero exclamation run |
| 2 | on/off | raw tokens matched; coherent open full-file `file_write` envelope exceeded the 512-token diagnostic cap |
| 2 | on | the same large envelope still reached the 4,096-token diagnostic cap |
| 3 | on | `stop`; valid tool call; zero exclamation run |
| 4 | on | `stop`; valid tool call; zero exclamation run |
| 5 | on | coherent large full-file write envelope reached the 512-token diagnostic cap; zero exclamation run |

The JANG_4M bundle's `generation_config.json` supplies EOS ids but no
temperature, top-p, top-k, min-p, repetition-penalty, or sampling override.
The replay therefore used bundle defaults, a 512-token prefill step, the named
seed, and the stated 512/4,096-token diagnostic cap; it did not inject sampler
or template behavior.

The exact reported seed-1 cache-dependent corruption no longer reproduces,
and seed 2 is equivalent with cache on and off. Seeds 2 and 5 remain honest
terminal-lifecycle failures under the diagnostic output caps because the model
chooses a very large file-write call. They are not counted as successful final
turns and are not hidden with repetition penalties, sampler overrides, forced
stop tokens, prompt coercion, or parser masking.

Final-head real Chat UI proof used Ornith 1.0 9B JANG_4M with Thinking enabled
and bundle-driven generation settings:

- Two independent long tool-sequence runs produced coherent reasoning and
  terminal answers with no exclamation run, malformed character, leaked
  reasoning tag, parser debris, hang, or retry loop. Every visible tool card
  that was emitted settled, reasoning rows closed, Stop disappeared, and
  input unlocked.
- The strict five-call prompt exposed a separate model-compliance miss in both
  runs: the model executed Python, two writes, and the alpha read, then claimed
  it had also read beta. It did not emit the fifth tool call. This first turn
  is therefore **not** counted as a strict five-call task pass. In the final
  rerun's persisted session `89805BD9-B85F-4506-A033-71564DB70235`, the
  corrective turn emitted the missing beta read as a distinct successful card
  returning `beta-two`, then finalized exactly
  `SEQ2_FOLLOWUP_BETA=beta-two; DONE`.
- A tool-free third turn in the same session rendered exactly
  `SEQ2_TERMINAL_FOLLOWUP_OK`; its reasoning closed, Stop disappeared, input
  unlocked, and visible metrics were TTFT 0.42 s, 99.3 tok/s, and 40 output
  tokens. The beta-read turn showed TTFT 0.36 s, 88.0 tok/s, and 180 output
  tokens.
- This proves the reported recurrent-state/second-read runtime degeneration
  no longer occurs through the full UI lifecycle. The model's skipped-call
  task compliance remains honestly captured in the raw eval quality results;
  no sampler override, forced token, prompt coercion, or fabricated tool result
  was added to disguise it.

## 2. Agent-loop terminal failures

### 2a. Seatbelt Python launch denial and retry loop

Observed behavior: `sandbox_exec` repeatedly invoked `python3`; Apple's
`/usr/bin/python3` shim reached Xcode's `libxcrun.dylib`, but the generated
deny-default Seatbelt profile lacked read access to the active Xcode developer
directory. Every attempt failed and consumed another agent iteration.

Fix:

- Resolve `DEVELOPER_DIR` or `xcode-select -p` and accept only the standard
  Xcode/CommandLineTools directory shapes.
- Add a narrow read-only grant for the validated toolchain. For Xcode, the
  grant covers `Contents` because `xcrun` also loads sibling
  `Contents/SharedFrameworks`; CommandLineTools remains self-contained.
  Workspace and scratch remain the only writable host paths; there is no home
  read grant and no Xcode write grant.
- Always replace inherited/tool-supplied `TMPDIR` with the Seatbelt-writable
  scratch directory. A caller cannot redirect xcrun's cache to a denied path.
- Unit coverage checks the profile shape and omission of invalid paths.
- A focused integration test uses the production `SeatbeltExecutor` to execute
  `/usr/bin/python3 -c ...` with a deliberately denied inherited `TMPDIR`.

The first real integration run exposed two distinct owning failures and was
retained as diagnostic evidence: xcrun attempted to write its cache under the
inherited denied `TMPDIR`, and `DVTSystemPrerequisites` was loaded from Xcode's
`Contents/SharedFrameworks`, outside a Developer-only read grant. After both
root fixes, the then-complete focused Seatbelt suite passed `14/14`; the
combined exact-pin focused run passed `33/33`. The final-head focused Seatbelt
rerun, including the added regression coverage, passed `15/15`.

Final-head live proof is recorded in session
`89805BD9-B85F-4506-A033-71564DB70235`. The expanded `sandbox_exec` card ran
`/usr/bin/python3 -c 'print(6*7)'` once, completed in 467 ms with exit code 0,
stdout `42`, and empty stderr. There was no xcrun denial, denied-cache path,
`getcwd` failure, or retry. The loop continued through both file writes and a
file read, reached a coherent terminal answer, accepted a corrective read
follow-up, and then completed a tool-free follow-up with Stop gone and input
unlocked.

### 2b. U+FFFE prefill/stats sentinels leaked at the iteration cap

Observed behavior: after the agent reached its iteration cap, the tool-free
final wrap-up visibly and persistently included private `U+FFFE` prefill and
stats sentinel payloads.

Confirmed source mechanism and fix:

- Normal turns pass deltas through `ChatView.processStreamDeltas`, which
  decodes prefill, stats, billing, reasoning, and tool sentinels into typed UI
  state.
- The iteration-cap branch instead used a raw `StreamingDeltaProcessor`, so
  the sentinels became `ChatTurn.content` and were later exported faithfully.
- The branch now uses the shared typed stream-decoding path. A focused source
  regression asserts that it cannot regress to the raw processor.

The focused source regression passed inside the `33/33` exact-pin run.

Proof requirement at this stage was an authorized real-UI iteration-cap row
showing typed telemetry, no visible/exported sentinel bytes, reasoning closure,
Stop disappearance, input unlock, and coherent finalization.

Current-head live discovery (`236d832eddbae5c0ecbf0364bfc37860f29900fa`,
isolated Release executable SHA-256
`d41412a2cea987a3fd654382316143d333e19970a94e63f43c236c2b3aef424d`):
with **Max Tool Attempts** changed through Settings from `30` to `1` and
verified after navigating away and back, the capped turn rendered typed
reasoning/stats with no visible U+FFFE sentinel, settled the one permitted
`sandbox_read_file` card, removed Stop, and unlocked input. However, its
tool-free wrap-up then printed a fabricated `sandbox_read_file` JSON result
for the unexecuted second read and changed the known file content from
`beta-two` to `beta-one`. This is a related terminal-integrity failure, not a
passing cap row. Fix the generic cap-finalization contract so it reports only
confirmed completed work and explicitly identifies unfinished work, then
rebuild and repeat the live row before calling this section verified.

Final-head live retest (`e810eda8a1df72b48cf2eb515e6d3e49522cb504`,
isolated Release executable SHA-256
`ce43c49ea5d8bdbfca595b7a79f0af4dfa6b008c6c47976f8958efdf35622d82`):

- The real Chat Settings UI persisted **Max Tool Attempts = 1** after
  navigating to General and back, and after launching this final-head build
  against the existing isolated root.
- The requested two-read turn executed exactly one settled
  `sandbox_read_file` call with `{"path":"alpha-clean.txt"}`. Its expanded
  card showed `alpha-one` from the agent workspace. The tool-free cap wrap-up
  then said `Read alpha-clean.txt: alpha-one. Still need to read
  beta-clean.txt before responding.` It did not imitate a tool call/result,
  invent a beta value, claim the unfinished read succeeded, or expose a
  U+FFFE telemetry sentinel.
- Both reasoning rows closed, the card settled in 364 ms, Stop disappeared,
  and input unlocked. Visible generation metrics were TTFT 0.30 s, 90.2
  tok/s, and 61 output tokens.
- A separate follow-up executed one settled `sandbox_read_file` call for
  `beta-clean.txt`; its expanded card showed `beta-two`, and the visible final
  was exactly `FOLLOWUP_BETA=beta-two; DONE`. Its reasoning rows closed, Stop
  disappeared, input unlocked, and metrics were TTFT 1.01 s, 94.4 tok/s, and
  60 output tokens.
- The setting was restored through the UI to **30**, verified after navigating
  away and back, then verified again after quitting and relaunching the exact
  isolated app. No new tool-kind permission popup appeared because this
  isolated agent already retained its file-read grant.

## 3. Warm-up prefix lost during disk-L2 quota enforcement

Observed trace:

- warm-up request: 4,012 prompt tokens, 4,001 restored, 11 remaining;
- real request: 4,424 prompt tokens, 4,312 restored, 112 remaining;
- post-tool continuation: 6,758 prompt tokens, 4,419 restored, 2,339 remaining.

Those supplied rows are partial-prefix hits, not two cold prefills. The
reported failure is the small-quota case where the warm-up group can be
evicted between its KV and recurrent-companion writes and the real request
then restores zero tokens.

Confirmed source mechanism and vMLX fix:

- KV and recurrent-companion stores previously enforced their quotas
  separately while writing one logical persistent boundary.
- The coordinator now stores both parts under one combined transaction lock
  and enforces the combined quota once after the group is complete.
- If the new complete group itself cannot fit, it is removed before older
  fitting LRU groups so a failed warm-up cannot destroy a usable prefix.
- Longest-valid-prefix probing remains longest-first and model namespaces stay
  isolated, so reuse does not cross incompatible models/templates.
- Deterministic oversized-new-group regression: passed.
- Full focused `DiskCache` lane: `18/18` passed.

Final-head isolated Release live proof
(`e810eda8a1df72b48cf2eb515e6d3e49522cb504`, executable SHA-256
`ce43c49ea5d8bdbfca595b7a79f0af4dfa6b008c6c47976f8958efdf35622d82`):

- The real Server -> Settings -> Cache UI showed Prefix Cache on, GPU/paged KV
  off, Disk Cache on, a 1.0 GB cap, the isolated directory
  `/private/tmp/osaurus-pr2235-ui-root-9fOXXs/prefix-cache`, and Re-derive SSM
  State After Generation on. The active coordinator line reported
  `KV 65,536 tokens; RAM off; SSD 1.0 GB`; all values remained after navigating
  away and back.
- After quitting and relaunching the exact app, Ornith warm-up tokenized 3,632
  prompt tokens and restored 3,631 from disk, leaving one token to prefill
  (`promptMs=34`, `promptTps=104611.3`). Disk and SSM-companion hits both
  incremented while paged-RAM hits stayed zero.
- The visible `CACHE_TRACE_LIVE` turn restored 3,631 / 3,742 tokens, leaving
  111 to prefill (`promptMs=106`, `promptTps=35081.8`). It closed reasoning,
  rendered exactly `CACHE_TRACE_LIVE`, removed Stop, unlocked input, and showed
  TTFT 0.33 s, 100.9 tok/s, and 41 output tokens. Its post-turn warm-up then
  restored 3,737 / 3,753, leaving 16.
- The visible follow-up restored the newer longest valid checkpoint,
  3,750 / 3,863 tokens, leaving 113 (`promptMs=124`,
  `promptTps=31043.3`). It closed reasoning, rendered exactly
  `CACHE_TRACE_FOLLOWUP`, removed Stop, unlocked input, and showed TTFT 0.35 s,
  82.7 tok/s, and 184 output tokens. Its post-turn warm-up restored
  3,858 / 3,874, leaving 16.
- Final counters were disk hits/misses/stores `6/7/4`, companion-state
  hits/misses/re-derives `6/0/0`, and paged-RAM hits `0`. Candidate probing can
  increment miss counters, but every named request above recorded a non-zero
  disk restore and a companion hit; no request restored zero tokens.
- Quota enforcement left three complete groups and no orphan KV or companion
  files: boundary 3,631 / hash `d71b427d...` = 273,533,859 bytes; boundary
  3,858 / hash `57755659...` = 280,972,149 bytes; boundary 3,871 / hash
  `99a95f73...` = 281,398,133 bytes. Each companion metadata file was complete,
  named its matching KV hash and boundary, and contained 48 states. The cache
  occupied 798 MiB under the 1.0 GB cap; older 3,737 and 3,750 groups were
  evicted as the newer groups were committed while the reused 3,631 group
  survived.
- Raw prefill trace: `/tmp/osaurus-prefill-debug.log`, SHA-256
  `0bd764a1c13a3e42c4f81ded763da7f7dd4cf248cc249345c868d08977716447`.

## 4. Installed Laguna S size displayed as 19.03 GB

Observed local bundle truth:

| Bundle | Weight bytes | Approx. GiB |
| --- | ---: | ---: |
| Laguna S 2.1 JANG_2L | 44,298,536,392 | 41.3 |
| Laguna S 2.1 JANG_4M | 68,093,609,576 | 63.4 |
| Laguna S 2.1 JANG_6M | 96,480,659,088 | 89.9 |

For 2L, `du` reported 43,267,856 KiB and
`model.safetensors.index.json.metadata.total_size` reported exactly
44,298,536,392 bytes.

Confirmed source mechanism and fix:

- Local discovery validated the bundle but created `MLXModel` without a local
  byte count. An exact-ID merge then retained the curated/Hub row's stale
  cached remote size, producing 19.03 GB in the UI.
- Local and external discovery now read bounded authoritative weight size from
  index metadata, a bounded `weight_map`, direct weight files, or a shallow
  safetensors fallback.
- Exact-ID refresh preserves curated identity and description while replacing
  installed path, size, and model type with local truth.
- Exact-ID refresh is explicitly limited to background local discovery and
  does not consult the potentially stale pre-scan `isDownloaded` cache.
- Index JSON reads are capped at 16 MiB; shard paths must remain inside the
  bundle; shard sums reject integer overflow.
- Tests cover index metadata, malformed-index fallback, exact-ID refresh,
  path traversal, local scan, and external-bundle discovery.

All affected Laguna/local-discovery assertions passed in the combined `33/33`
exact-pin focused run.

Final-head Settings/UI proof used the same isolated Release executable:

- Filtering the real On Device grid to `Laguna` displayed all three installed
  Laguna S variants as 44.3 GB (JANG_2L), 68.09 GB (JANG_4M), and 96.48 GB
  (JANG_6M). The erroneous 19.03 GB value was absent.
- The values remained identical after navigating to General and back. After a
  full app quit and relaunch, the Laguna S version sheet visibly showed all
  three variants together with those same sizes.
- The displayed values match each bundle's current
  `model.safetensors.index.json.metadata.total_size` (44,298,536,392,
  68,093,609,576, and 96,480,659,088 bytes). A shallow sum of all files is
  slightly larger because it also includes bundle metadata; the UI correctly
  reports authoritative weight size without recursive UI-time scanning.

## Proof boundary

Computer Use resumed under explicit user authorization and the affected
real-app rows above were completed against the isolated Release build. A
permission popup for a test agent's new tool type must be handled with
**Always Allow** so a one-time prompt does not masquerade as a runtime failure;
this does not authorize unrelated grants. No new permission-kind popup
appeared in the final file-read/cache/Laguna rows because the isolated agent's
existing grants were sufficient.

The original isolated Release app was built at
`/private/tmp/osaurus-pr2235-236d832e-release-derived-20260730-1/Build/Products/Release/osaurus.app`;
its executable SHA-256 is
`ce43c49ea5d8bdbfca595b7a79f0af4dfa6b008c6c47976f8958efdf35622d82`.
A post-build keychain-free deep ad-hoc seal used for distribution-path checks
removed the virtualization entitlement, so a disposable copy was signed with
the repository's minimal eval entitlements solely for the final sandbox/
Seatbelt recheck. That copy used the same compiled source and isolated root,
passed strict deep signature verification, and had executable SHA-256
`2c71103b7b345a748358a38113023c88e89383bdf0f9ba0bcf8030d73fde0e95`.
No screenshots are committed or uploaded to the repository.

The exact tested Osaurus code head and merged vMLX pin compile as a production
OsaurusCore Release build (`528.55s`). `swift test -c release` cannot compile
the repository's existing Release *test module* independently of this change
because tests reference helpers compiled only under `DEBUG` (for example
`forceChatEngineRouteForTests` and `_setKeyForTesting`). Focused tests therefore
use the repository's normal Debug configuration; the production Release module
was gated separately above.
