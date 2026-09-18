# First-send reasoning controls

NOW: PR #2822; correction `9a3a3a696ef3cf2dacd6c82970c6809a5950c304`
has executable before/after regressions and isolated native-app evidence below.
Full core CI is still running; no merge or release is claimed here.
DO NOT: change templates, synthesize reasoning tags, hide generated reasoning,
alter sampling, disable memory protection, or publish a release.
BATCH OWNER: first-send reasoning presentation, explicit-choice persistence,
and the shared Chat/agent/delegation/batch request contract.
NEXT: finish normal PR CI and exact diff review, then merge this bounded fix.

## Reproduced baseline findings

1. `ModelProfileRegistry.profile` memoizes `AutoThinkingProfile` and nil even
   though that fallback depends on asynchronously discovered bundle metadata.
   The name-only cache added in #2817 can freeze a provisional cold miss.
2. `ChatTurnGenerationControls.captureForSend` recovers only `disableThinking`.
   A saved segmented effort (including Bonsai/Qwen Off) has no cold recovery.
3. Declared effort options replace the legacy boolean definition during
   normalization, while the picker still independently offers that boolean.
   Trace and reproduce explicit Off loss and contradictory presentation.
4. Internal agent loops load persisted options on the main actor before
   authoritative bundle discovery. Verify this path and same/different-model
   child scoping, rather than adding a separate delegation-only default.

## Implementation and proof plan

- Keep cheap name-only profile memoization; resolve the dynamic fallback from
  its own invalidatable capability cache. Do not reintroduce main-thread I/O.
- Use one native reasoning control contract for display, normalization,
  first-send snapshots and reconstructed requests. Preserve explicit Off;
  unknown capability must not be displayed as an authoritative Off default.
- Await authoritative local metadata only where required; retain remote API
  isolation and do not turn absent choices into invented defaults.
- Reproduce cold-to-warm behavior with fixtures, then exercise actual Off/On
  controls, first message, follow-up, saved/relaunched state and a model switch
  in an isolated app. Check request/template values and visible completion.
- Cover target-model choices in delegated/batched requests and tool-loop
  reconstruction; inspect schema/cache behavior without changing their policy.
- Record exact source/pin, binary identity, model, defaults, token/s, raw
  outcomes and remaining gaps. No all-model claim from one live row.

## Existing work: do not duplicate

GitHub checked 2026-09-18: Osaurus #2796/#2798 (handoffs), #2814 (bundle
sampling), #2815 (unnecessary tool prefill), #2816 (document hydration),
#2818 (Bonsai load/media prefill), #2820 (FP16 KV / FP32 recurrence) are merged.
Their existing proof limits remain in their PRs and linked documents.
This branch must retain those implementations and engine pin `6026359408f02c5867643d84300b0ca2225a2e88`.

Separate remaining items: global manual-MTP/model-switch UX from #2785;
unqualified long-context/sustained speed rows; reporter-hardware RAM/resource
coverage and remaining helper quality rows. Do not reopen already-qualified
idle/handoff settings or claim these remaining items closed by reasoning tests.

## Evidence

Artifacts and runners are in
`/Users/eric/vmlx-private-evidence/reasoning-first-send-2026-09-18/`.
The first two optimized test attempts could not compile unrelated plugin/agent
tests that use DEBUG-only seams. They are harness failures, NOT evidence that
the new regressions executed. The attempted narrow exclusions were abandoned.
The canonical Debug baseline ran from the separate unchanged production
worktree `osaurus-reasoning-baseline-0918`, with just the three new regressions.
This keeps the before/after comparison separate from implementation.

Implemented: name-only memo plus invalidatable dynamic fallback; recovery of
both persisted reasoning controls; preservation of legacy explicit Off when
the declared effort picker appears; capability-completion rehydration without
overwriting a newer click; no provisional Off display; one thinking/effort
picker rail; effort frozen into wire requests and existing same-model subagent
scope/runner parameters. Different-model children continue using their own
stored choices. No template, sampling, cache, RAM or residency policy changed.

The isolated UI profile is `/Users/eric/.codex-work/reasoning-proof.UWcReG`,
port 19418, with curated symlinks to JANGQ-AI Bonsai 1.75-bit and OsaurusAI
Gemma E2B 8-bit. The older proof symlinks under OsaurusAI/Bonsai are stale;
current Bonsai bundles are under `~/models/JANGQ-AI/`. Do not reuse those
old symlinks or their proof as current evidence.

Current Bonsai metadata declares default xhigh, supported low/medium/xhigh,
native enable_thinking Off, and sampling 1.0 / 0.95 / top_k 20. This is source
metadata, not a live result. Preserve it unchanged during proof.

## Executable results

- Baseline `Tests-red-debug-1.xcresult`: 84 tests / 7 suites; 81 passed,
  three new regressions failed (four assertions). Legacy explicit Off became
  missing/Extra High; cold-send effort-Off was omitted; dynamic profile
  discovery remained stuck after a cold miss. Production baseline was unchanged.
- Fixed `Tests-fixed-debug-1.xcresult`: 106 tests / 8 suites passed.
- Expanded `Tests-fixed-debug-2.xcresult`: 110 tests / 9 suites passed,
  including AgentReasoningDispatch, SpawnTool's reconstructed streamed steps,
  same/different-model scope, and real scripted child-host TaskLocal capture.
- `build-first.log` / `Build-first.xcresult`: optimized Release-configuration
  **development** build succeeded, not a product release. Unique bundle ID
  `com.dinoki.osaurus.reasoning0918`; engine pin unchanged at `6026359408f02c5867643d84300b0ca2225a2e88`.
- Ad-hoc signed binary SHA256
  `770e5b2ed18c1738f75162e3b4ec44953c5e7ba4fc7277ade09f2c79ed22cd2c`,
  Mach-O UUID `B97CBFAE-B6BF-3EBB-A35D-476AB24B2043`.

## Native UI and runtime receipts

Actual native controls were exercised through PID-bound Accessibility and
mouse input, not an HTTP-only replacement for the UI. CUA inventory timed out;
System Events could ambiguously address two identically named apps, so the
proof uses `AXUIElementCreateApplication(pid)`. The grouped Thinking AXPress
can activate its reset action; the explicit Gemma Off row instead used the
actual switch, with the persisted versioned boolean separately decoded.
The earlier default-Off rows are not mislabeled as saved explicit choices.

| Row | Observed behavior | Decode rate / receipt |
| --- | --- | --- |
| Bonsai cold default | Selector showed Extra High before first send, matching bundle metadata; no false Off default | `ui1-before-first-send.png`, `ui1-default-effort.png`; no generation in this row |
| Bonsai explicit None, first send | Kept None after model load; 12 sandwiches; zero stored/generated reasoning; native closed-thinking template, stop=stop | 32.0 tok/s; `ui1-off-first-answer.ax.jsonl`, first `ui1-prompts/` dump |
| Bonsai follow-up | Correctly updated to 16 sandwiches; None unchanged; disk restore accepted 3,967 tokens / 64 layers after idle unload | 32.6 tok/s; `ui1-off-followup.ax.jsonl`, `ui1.stdout` |
| Restart with saved None | New cold chat retained None; two parsed spawn calls reached execution. Existing one-local-child limit rejected the excess call; parent continued it sequentially. Both children and all parent tool steps had zero reasoning | Parent final 31.8; children 32.3 and 31.7 tok/s; `ui2-cold-off-restored.ax.jsonl`, `ui2-spawn-complete.ax.jsonl`, `final-turns.json` |
| Bonsai None → Light → None | Light produced 228 reasoning characters and a coherent final answer; subsequent None produced zero reasoning and recalled the earlier child result | 31.7 then 31.8 tok/s; `ui2-light-answer.ax.jsonl`, `ui2-off-after-light.ax.jsonl` |
| Gemma explicit boolean Off | Real switch persisted `disableThinking=true`; unloaded first send returned five cups; follow-up recalled reusable cups; selector remained Off and both turns had zero reasoning | 86.7 then 84.5 tok/s; `ui2-explicit-options.txt`, `ui2-gemma-explicit-off-{first,followup}.ax.jsonl` |
| Different-model child | Bonsai Light → unload parent → Gemma saved Off → unload child → reload Bonsai Light. Child returned Picnic Provisions with zero reasoning; parent resumed coherently with Light | Parent 31.1 / 31.7; child 86.8 tok/s; `ui3.stdout`, `ui3-handoff-complete.ax.jsonl`, `final-turns.json` |

These are short correctness-row decode rates, **not sustained speed claims**.
The different-model child result also reports 2.4 completion tokens/s inclusive
of its very short run; this is distinct from the engine's 86.8 decode tok/s.
No row above ended at a length cap. No prompts asked the model to suppress
reasoning; no generation defaults, tags, templates, seeds, cache, or RAM policy
were changed to make a row pass.

`ui1/2/3-launch.json` bind source, engine, signed binary, PID, port and profile.
`native-prefill-excerpt.log` contains matching STEP-BEGIN/STATS/END and cache
restore counters; `ui1/2/3.stdout` and `ui1/2/3-prompts/` are PID-bound runtime
and rendered-template receipts. `final-turns.json` retains all visible answers,
stored thinking lengths, stop reasons, tool results, and child session IDs.

Cache scopes changed from `reasoning=off` to `reasoning=on|effort=low` and back,
with distinct salts. Parent post-tool restores accepted disk boundaries 3,989
and 4,511; the cross-model return restored 3,988 tokens / 64 layers. Existing
Bonsai dtype logs remained attention stored K/V FP16 and recurrent state FP32.
Gemma reports 3 KV / 12 rotating layers and disk-backed restore; no TurboQuant
layer claim is made. `ui3-measurements.jsonl` observed at most one resident model
and peak sampled physical footprint 13,669,960,056 bytes. This is not a low-RAM
16 GB reporter-machine stress test.

The two curated model links are the loaded proof targets. Custom-folder
discovery also populated the picker with other models; those were not loaded.
The isolated Helper fixture's defaultModel was set while the app was stopped:
first Bonsai, then Gemma, leaving its stock system prompt unchanged. The user
installed app/profile was not modified; all three isolated app PIDs were
gracefully closed after their rows.

## Retained failures and scope limits

- An earlier Gemma **default-Off** arithmetic follow-up returned 18 table legs
  instead of 20. It is retained as FAILED content in
  `ui2-gemma-off-followup-failed-content.ax.jsonl` and `final-turns.json`.
  Thinking stayed Off; the engine pin/model math was not changed in this PR.
  This prevents claiming general Gemma family correctness or a speed win.
- The live batch requested two children, but the existing configured local
  concurrency limit was one. Both completed through sequential continuation;
  this is not proof of two simultaneously admitted local workers.
- A mid-generation picker automation attempt did not select None (no matching
  control after model-load refresh). It is **not** live proof of a changed
  in-flight selection. Newer-choice and per-turn snapshot behavior has focused
  executable coverage, plus successful between-turn native changes above.
- Browser/computer-use/AppleScript entrypoints compile and share the tested
  explicit-effort propagation contract. This lane did not automate the user's
  browser/desktop or claim those entire helpers live-qualified.
- No new media, MTP, 16 GB stress, long-context, or sustained-throughput claim.
  Previously merged related work is retained, not reimplemented.

PR: https://github.com/osaurus-ai/osaurus/pull/2822 . Baseline receipt comment:
https://github.com/osaurus-ai/osaurus/pull/2822#issuecomment-5737050067 .
At this update, lint, CLI, packages, evals and statspack CI passed; core CI
remained in progress. No tags, release publishing, or workflow dispatch.
