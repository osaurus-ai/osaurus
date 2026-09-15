# SSD quota notice and template defaults

Status: PARTIAL — implementation prepared; current-source build, focused suites,
Release UI quota/clear/refill, Qwen default-thinking image turns, and affected full
evals remain required before promotion.

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
