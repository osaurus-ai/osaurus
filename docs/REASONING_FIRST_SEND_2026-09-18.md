# First-send reasoning controls

NOW: correction implemented from main `3d0a0a795bb238e345522f4539187930d9b8834b`; verification pending.
DO NOT: change templates, synthesize reasoning tags, hide generated reasoning,
alter sampling, disable memory protection, or publish a release.
BATCH OWNER: first-send reasoning presentation, explicit-choice persistence,
and the shared Chat/agent/delegation/batch request contract.
NEXT: canonical Debug baseline/fixed regressions and an isolated exact-pinned
optimized native development-app proof, then a normal PR.

## Current source findings (not yet runtime-qualified)

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
The canonical Debug baseline now runs from the separate unchanged production
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

Pending: executable results, actual UI/runtime proof, PR/CI.
The installed 0.25.8 app and its user settings remain untouched.
