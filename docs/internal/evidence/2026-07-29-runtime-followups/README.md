# Runtime follow-ups — 2026-07-29

Status: `PARTIAL` — fixes for the four reported issues are committed in the
coordinated Osaurus and vMLX branches. Focused source/runtime tests and the
exact-pin Osaurus production Release build pass. Computer Use was explicitly
stopped, so the real-app lifecycle rows remain unverified and this work is not
described as release-ready or regression-free.

## Exact source baseline

- Osaurus baseline: `f33c9eca144a84beb4bbde705af649bed060acf8`
- tested Osaurus code head: `e3399d130dd5908ff60f5589d4044f5717c5bfe5`
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
| Osaurus exact-pin focused suites | 33/33 passed across 5 suites |
| Osaurus four-surface pin guard correction | 3/3 passed across 2 suites |
| OsaurusCore production Release build | passed in 528.55 seconds |

The exact-pin focused command covered the Seatbelt integration, Laguna local
metadata paths, external model discovery, and iteration-cap source policy in
one invocation. The real UI lifecycle and the model-dependent full AgentLoop /
AgentLoopFrontier lanes remain `PARTIAL`; the PR's cold CI supplies the full
core and deterministic eval gates, not those live/model-dependent rows.

The first GitHub `test-core` attempt ran the runtime suites but failed five
source-policy assertions because the initial pin commit updated
`Packages/OsaurusCore/Package.resolved` while missing both Xcode workspace
`Package.resolved` files and their two expected-revision guard constants.
Xcode regenerated both workspace pins and origin hashes at the same merged
vMLX SHA; the two focused guard suites then passed `3/3`. This was pin hygiene,
not a model/runtime assertion failure. The final-head core rerun is the merge
gate.

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

Remaining proof: run the exact patched Osaurus pin through the real Chat UI and
inspect reasoning, tool-card completion, final answer, Stop disappearance,
input unlock, and a follow-up turn.

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
root fixes, the complete focused Seatbelt suite passed `14/14`; the combined
exact-pin focused run passed `33/33`.

Remaining proof: one authorized live agent continuation showing that the call
completes and the loop reaches a coherent final instead of retrying to the cap.

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

Remaining proof: an authorized real-UI iteration-cap row showing typed
telemetry, no visible/exported sentinel bytes, reasoning closure, Stop
disappearance, input unlock, and coherent finalization.

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

Remaining proof: the exact Osaurus pin with paged RAM off, a small disk quota,
measured group bytes/eviction identity, restored and remaining-prefill tokens,
KV/companion hits, coherent output, and app-restart reuse.

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

Remaining proof: an authorized Settings/UI relaunch row confirming that each
installed Laguna quant displays its measured local size without recursive
UI-time scanning.

## Proof boundary

Computer Use was explicitly stopped for this follow-up. Source tests and
non-UI runtime harnesses may proceed, but user-facing lifecycle rows remain
`PARTIAL` until visible app testing is authorized again. During any future
user-authorized isolated live proof, a permission popup for the test agent's
new tool type must be handled with **Always Allow** so a one-time prompt does
not masquerade as a runtime failure; this does not authorize unrelated grants.

The exact tested Osaurus code head and merged vMLX pin compile as a production
OsaurusCore Release build (`528.55s`). `swift test -c release` cannot compile
the repository's existing Release *test module* independently of this change
because tests reference helpers compiled only under `DEBUG` (for example
`forceChatEngineRouteForTests` and `_setKeyForTesting`). Focused tests therefore
use the repository's normal Debug configuration; the production Release module
was gated separately above.
