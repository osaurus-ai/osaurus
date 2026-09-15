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
