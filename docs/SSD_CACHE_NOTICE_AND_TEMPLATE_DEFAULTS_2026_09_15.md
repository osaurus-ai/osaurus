# SSD quota notice and template defaults

Status: PARTIAL overall. The Release SSD quota/clear/refill UI scenarios and
Qwen native-default image turns have current evidence below. Focused tests and
RAM evals passed; the 26-bundle vision sweep has four retained failures. Full
AgentLoop/Frontier qualification is in progress. This is not all-model or
physical M4/16 GiB proof.

This integrates PR #2698 (7ec9004063ecfed9d0e4d1d0cdb2312c05825889) on the combined
RAM/residency/vision source 92d81b1070c6add69acb7fad72c4d9bf50eb9ec0. The original
worktrees and public draft branches remain intact.

The composer samples resident coordinator snapshots: actual disk directory,
current payload bytes (including recurrent companions), enforced quota, and
logical eviction count. It presents once per standardized directory/quota/app
launch at full usage or after actual eviction, so janitor trimming before the
sample does not suppress the notice. It waits for the active chat to settle and
avoids other alerts. The notice clears the measured root. Settings clears both
active roots and the currently configured root. Purging uses the runtime IO lock,
SQLite ownership records, and explicitly linked companion metadata; unrecognized
files and model bundles are preserved. Errors remain visible. No OS swap policy,
RAM admission, model weights, or volatile cache is changed by this action.

Native Release92 Qwen3.8 LM Studio6bit tests returned Blue then Red from a real
pasted image, but UI Thinking Default/On disagreed with the rendered closed-think
prompt. MLXBatchAdapter.additionalContext synthesized enable_thinking=false when
options were omitted. The inherited behavior and required-tool suppression trace
to 4fdfa4af9b024f672af70973d22190f431bce492 (#1268). They compensated for earlier
reasoning-only/length-stop failures. This change removes those implicit overrides;
explicit options and tool-choice metadata remain separate. Bundles control omitted
defaults. A model that loops with its native settings is a failed row, not a reason
to restore hidden thinking suppression.

Evidence is private under /Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14.
Prior source92 receipts: integrated-92d81b-release-receipt.json,
lmstudio-eight-Qwen3.8-27B-MLX-6bit-receipt.json, qwen38-92-clipboard-answer.png,
qwen38-92-clipboard-followup.png, combined-ui-run12-prompts. These are baseline
receipts, not proof of this changed source. Exact Qwen3.6 35B6bit load exceeded the
28GiB private footprint bound at34.29GiB and aborted before inference. No physical
M4/16GB run has been performed on this M5 Max128GiB host.

Focused source b966f372940a02ab8bc381eb5ae2b53e1ceef33e: 175/175 tests
(161 Swift Testing across6suites,14 XCTest cache wiring). Command and output:
SWIFTTEST_SSDDefaults0915__141006.log; xcresultssd-defaults-b966f3729-debug.xcresult.
Supervisor exit0,peak10.70GiB,swapflat5.69GiB,cleanup0. CoreData XPC warnings were
logged by the isolated test host; no test failures. The first attempt02ca failed
compilation of mutating #expect receivers; corrected test evaluation, no policy
change. Following review, the localization catalog retains the baseline key order
without changing its JSON values, and SQLite handles now close even when open fails.
Those last changes require the next current-source test/build receipts.

## Native checkpoint and follow-up: 2026-09-15 14:57 PDT

Source `edace13d0e93c7a633885b1aecf7676c1d2ec0a0`, engine
`441d9a8e8df19f4c364b50903cbc62b4059639c9`, Release app SHA256
`eb39b8a63cdcfb2b2bcd6666a0d1a2db7311f8e2bd87abab2cc157e92f1b090f`:
175/175 focused tests; both app and Evals Release builds completed.
Receipts: `ssd-defaults-edace13d0-focused-receipt.json`,
`ssd-edace13d0-release-receipt.json`, `evals-edace13d0-release-receipt.json`
in the private evidence root documented above.

Native run13 changed the real Settings quota from 10% to 0.005%; the UI
resolved it to 191 MB and `/admin/cache-stats` reported 199,813,840 bytes.
Settings Clear removed 261 indexed entries / 6,930,448,505 indexed bytes,
leaving zero indexed entries and preserving an unindexed sentinel plus SQLite
index files. Evidence: `ssd-run13-{before,after}-settings-clear.json` and
`ssd-edace-settings-cleared.{ax.txt,png}`.

The reporter PNG was copied in Preview and pasted into native Chat. With
Qwen3.8-27B-MLX-6bit and Thinking reset to its bundle default, answers were
Blue (55 tokens, 20.6 tok/s) and Red (198 tokens, 20.6 tok/s). Both reasoning
segments closed and the input unlocked. The second turn recorded one real
L2 hit; topology remained 16 KV + 48 Mamba, paged off, TurboQuant layers 0.
Do not infer an SSM companion hit: that counter was zero. Artifacts:
`qwen38-edace-clipboard-{attached,answer,followup}.{ax.txt,png}`,
`ssd-run13-cache-stats-after-followup.json`, `combined-ui-run13-prompts/`.
The isolated supervisor exited 0, peak owned footprint 21.42 GiB, swap
5.67 GiB unchanged, all owned processes cleaned up.

The warning row failed this native checkpoint: after a real quota eviction,
no SSD notice appeared in the fresh same-model chat. The polling task was keyed
only by model and retained old view/session/presentation values. This follow-up
keys it by model, session, and current eligibility and uses the same eligibility
for visible presentation. Settings Clear also gets an explicit accessibility
label because the native AX button was unnamed. These follow-up changes require
fresh focused and native proof; the previous 175 tests and runtime results do
not establish the follow-up source as verified. The isolated profile remains
at 0.005% for the next reproduction and must be restored to 10% through Settings.

## Native popup qualification on 425d42ec5

The follow-up source `425d42ec5d040b366ba119321c4c0b1b18aa04b9` passed
177/177 focused tests. App and Evals Release builds completed within the
unchanged 1800-second supervisor: peak 22.50 GiB, swap 5.65 -> 5.64 GiB,
exit 0 and zero remaining owned processes. App SHA256
`bc56f54534d32eac76196fe1bd354ed1da769b667853584bd6f5f1f0fbf588bc`;
Evals SHA256 `b6cf1dcc352f1ca6c63ae792bdc5e240b0de63a731fce9b2cfcf7833d7b42bd9`.
Engine pin remains `441d9a8e8df19f4c364b50903cbc62b4059639c9`.

Native run14 now showed the 191 MB quota notice after a real eviction in a
fresh same-model chat. It hid during the next image turn and returned only
when the turn settled. Popup Clear reported 164 MB; the live coordinator's
indexed bytes fell from 172,455,808 to zero while the model remained loaded
at 22:36:48 and 22:36:51 UTC. Idle unload followed at 22:36:54. Unknown
sentinel data and the SQLite index remained; linked cache payloads were gone.
Dismiss was exercised. A coherent follow-up refilled the cache, and another
fresh chat evicted again without a duplicate notice.

Run14 answers were Blue / Red / Blue / blue, with 50/261/59/74 generated
tokens and 20.8/20.7/20.7/20.6 tok/s. These were real Preview-copy/native-paste
requests and retained-image follow-ups, using the LM Studio Qwen3.8 27B 6-bit
bundle and native thinking/sampling defaults. Reasoning closed, Stop cleared,
and input unlocked. The history turn accepted a disk restore at boundary188,
64 layers; topology is 16 KV + 48 Mamba, not TurboQuant. Separate SSM companion
hit counters remain zero and are not claimed as a hit.

Settings Clear also worked on this build (159 MB). The original 10% share was
saved, the app relaunched (run15), and the real Settings field still showed
10%. An actual post-relaunch image-history turn returned red (34 tokens,
20.8 tok/s). The loaded engine enforced 187,078,148,096 bytes, matching the
174.2 GiB host-limited readout rather than the unbounded 372.2 GiB share.
Both runs exited 0 with owned cleanup zero. Peaks were 21.42 / 20.42 GiB;
swap 5.64 -> 5.63 / 5.63 -> 5.63 GiB. This is not a physical16GiB qualification.

Raw evidence in the same private root: `ssd-425-*.{ax.txt,png}`,
`ssd-run14-{before-popup-clear-resident,after-popup-clear,resident-clear-timeline,
fresh-chat-after-refill-cache}.json`, `ssd-run15-restored-active-cache.json`,
`combined-ui-run14/15-{launch.json,measurements.jsonl,prompts/,timing/}`,
`SWIFTTEST_SSDUI0915__153424.log`, `SWIFTTEST_SSDUI0915__154102.log`.
The Settings Clear button's visible label and action were exercised; CUA still
reported its AX button as unnamed, so no claim of a resolved AX-label issue.

CI run35028563781 retained five issues in two RuntimePolicySourceTests cases:
one expected a single-line alignment-authorization assignment that formatting
split; four explicitly required the obsolete closed-thinking family defaults.
The tests now normalize whitespace while checking the complete authorization
ternary, and require the omitted-options guard before family overrides with
no reasoning-context writes before it. Explicit reasoning overrides and all
other policy assertions remain. This follow-up changes tests/documentation
only; production source is identical to 425d42ec5. Its focused test rerun is
pending. Current-build full vision and AgentLoop evaluations remain required;
prior non-perfect scores and the oversized-model resource abort are retained.

## Current tests and full bounded vision sweep

SOURCE EVIDENCE: review source `552c4a4335508a4d2e902be15930e4072c7f56ab`
differs from the built `425d42ec5d040b366ba119321c4c0b1b18aa04b9` only in
`RuntimePolicySourceTests.swift` and this document. Production sources, eval
suites and dependency pins are byte-identical. The built app/Evals hashes and
engine pin remain those recorded above; the binaries are not relabelled as
builds of the later test/documentation commit.

LIVE EVIDENCE: focused source552 tests passed 287/287 (272 Swift Testing and
15 XCTest, zero failures), including RuntimePolicySourceTests. Log
`SWIFTTEST_SSDDefaults0915__154742.log`, receipt
`ssd-defaults-552c4a433-focused-receipt.json`, xcresult
`ssd-defaults-552c4a433-debug.xcresult`. Peak owned footprint 9.41 GiB,
swap 5.63 GiB unchanged, exit0 and owned cleanup0. All seven app CI jobs
passed on552 in run35032615838; Release Drafter also passed separately.

The current Release Evals passed 21/21 across RAMAdmission,
AgentLoopRAMAdmission, AgentLoopRAMControls, AgentLoopBatchNative and
AgentLoopBatchDisabled. This includes three fresh chats followed by sequential
children, RAM/handoff/coexistence controls, and same-model batching on/off.
The 13 deterministic memory cases include expected refusals; they do not
emulate physical M4 memory pressure. Log
`SWIFTTEST_SSDTargeted0915__155259.log`, receipt
`ssd-425-targeted-ram-receipt.json`. Exit0, peak1.47 GiB, swap5.63 GiB unchanged,
owned cleanup0. Iterator timing artifacts are retained alongside the reports.

Matching LM Studio `Qwen3.8-27B-MLX-6bit` completed all eight Vision requests
with native thinking and bundle T1/top-k20/top-p0.95. Image replay, streaming,
custom-agent routing, changed-image history and latest-image recall passed.
Request decode rates were20.4–21.2tok/s; no request ended at its token limit.
Receipt `lmstudio-defaults-425d42ec5-Qwen3.8-27B-MLX-6bit-receipt.json` records
the publisher revision, shard hashes, report hash and iterator timings
(including the separate warmup). Supervisor log
`SWIFTTEST_LMStudioDefaults0915__155501.log`: peak20.29 GiB, swap5.63 GiB flat,
exit0/cleanup0. This does not identify the reporter's unknown exact files.

The complete current 26-bundle/eight-request Vision sweep scored **22 passed,
4 failed**, exit1. All selected bundles ran; none crashed or hit the supervisor
limit. Peak owned footprint16.01 GiB, swap5.63 GiB unchanged, owned cleanup0.
Log `SWIFTTEST_SSDImage0915__155553.log`; raw reports in
`vision-ssd-defaults-eight/`; combined receipt
`ssd-425-vision-matrix-receipt.json` records every score, failure, report hash,
cache telemetry and throughput. Seven earlier oversized bundles remain unrun
under the unchanged28 GiB cap.

| Failed bundle | Observed failure |
| --- | --- |
| Ornith1.5-9B-JANG_2D | Agent route returned the correct red color with repeated prose, violating the exact answer contract. Raw deltas contain the repetition and one normal stop; the report did not duplicate a final whole-message event. |
| ZAYA1-VL-8B-JANGTQ_K | First image and agent route answered blue instead of red. |
| Nemotron-3-Nano-Omni-30B-A3B-JANG_6M | Changed image after history answered red instead of blue. |
| ZAYA1-VL-8B-JANGTQ4 | Changed-image and later-recall colors were wrong; the agent route answered white instead of red. |

These four also failed the prior sweep. CRACK Qwen27B2D passed this run after
failing the prior run; both outcomes remain recorded. No newly failing bundle
appeared in this single comparison, which is not a regression-free claim.
The prior native LFM later-recall failure remains separate from its passing
API row. Source/default changes are never compensated by hidden sampling,
thinking suppression or answer filters.

Full AgentLoop/Frontier started serially after the vision process exited and
cleanup was verified, using the same exact Release Evals binary. Results are
pending in `evals-425d42ec5-agent-full/` and
`SWIFTTEST_SSDAgent0915__164030.log`; earlier58pass/24fail/4skip remains the
baseline, not the current score.
