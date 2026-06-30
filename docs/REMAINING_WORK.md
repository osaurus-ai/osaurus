# Image / Spawn / Delegation — Remaining Work (canonical backlog)

Single source of truth for open work on the native image gen/edit + spawn/delegation
feature. Created 2026-06-23 because open items were scattered across 6+ docs with
contradictions. Supersedes the "open work / TODO / not implemented" sections of the
other docs where they disagree. Each item: severity, where it lives, documented-before?
(most were **undocumented** until this audit), and what to build.

> **Unified-architecture rename (2026-06-25).** The backlog below predates the
> subagent unification and references old names/paths. Map: `local_delegate` /
> `LocalTextDelegateTool` are **removed** (the text path is `spawn` →
> `AgentSubagentRunner` only); `image_generate` + `image_edit` are merged into one
> **`image`** tool (`ImageTool` in `NativeImageTools.swift`, `source_paths` ⇒ edit);
> `AgentDelegationConfiguration` → `SubagentConfiguration`,
> `AgentDelegationSettingsSection` → `SubagentSettingsSection`. Items referencing
> `LocalTextDelegateTool` (e.g. #3, #12, the test-coverage list) now apply to `spawn`
> only. The two "Doc rot" bullets about `SUBAGENT_TEAM_SPEC.md "(being built)"` and the
> `Agent.spawnable` naming are **fixed** (TEAM_SPEC now documents the dual gate
> `agentDelegationEnabled` + `Agent.spawnDelegationEnabled` + `spawnableAgentNames`).
> The P0/P1 **correctness** items (HTTP clamps, localization, restore-on-success,
> stale spawnable names, etc.) were NOT touched by the refactor — re-verify each
> against the renamed code before actioning.

Verification key: **[verified]** = confirmed in real source this audit · **[reported]** =
surfaced by audit, not yet hand-confirmed · **[refuted]** = checked and found false.

## P0 — block production / a release-quality merge

1. **`localTextDelegateToolUse` ("Delegate Tool Use") is a live UI no-op.** **[verified]**
   `AgentDelegationConfiguration.swift:74` defines it; `AgentDelegationSettingsSection.swift:196`
   renders a 3-way picker for it; **no runtime path reads it** (grep: only config + UI).
   Subagents are text-only so it can never gate anything. A visible permission control that
   silently does nothing. **Build:** hide the picker (mirror how `maxToolCalls` was hidden)
   until nested-tool subagents exist, OR build the tool-use permission flow.

2. **Spawned personas / delegates are text-only — contradicts the design docs.** **[verified]**
   `AgentSubagentRunner.swift:8` ("no nested tool execution in v1"), `:98-109` rejects every
   tool. But `SUBAGENT_PORTABLE_DESIGN.md:61,80,227` describe a tool-capable persona spawn.
   Silently breaks "spawn a coder/file/DB/computer-use agent." **Build:** either a nested-tool
   subagent runner, or document the text-only limitation in the design/spec/readiness docs and
   gate the UI/system-prompt so users aren't told spawn can use tools.

3. **Orchestrator can be left permanently unloaded on the success path.** **[verified]**
   `SpawnTool.swift:168` and `LocalTextDelegateTool.swift:292` use bare `try? …restore(lease)`
   on every non-throw exit; `restoreBestEffort` (which logs) is only on throw paths. If the
   chat-model reload throws (OOM after the job), the orchestrator stays unloaded with **no log,
   no error, a success envelope** — directly contradicting `ChatResidencyHandoff.swift:34-48`'s
   stated invariant. **Build:** use `restoreBestEffort` (or surface the error) on the success
   path too; add a test forcing a restore failure.

4. **Public `/v1/images/{generations,edits}` do not clamp `width`/`height`/`steps`/`n`.** **[verified]**
   `HTTPHandler.swift:6243/6315` pass size through unvalidated; `:6253` `numImages: max(1, req.n ?? 1)`
   (lower bound only). The agent-tool path *does* clamp (`NativeImageTools.swift:259-263` +
   `1...4`), and `/images/models` advertises `max_pixels`/`max_steps`/`supported_sizes` that are
   **never enforced**. On an exclusive Metal GPU lane, `n:100` or `4096x4096` can OOM / trip the
   GPU watchdog / wedge the lane. **Build:** port the clamps + advertised-limit rejection into the
   HTTP handlers.

5. **Localization gate failing (test-core).** **[verified]** 30 image/spawn UI strings (incl. the
   new "Spawnable Agents" copy, FloatingInputCard image controls, AgentDelegation display names)
   are not in `Localizable.xcstrings` for de/zh-Hans/ko. The feature branch never ran CI so this
   was never caught. **Build:** add the English keys + de/zh-Hans/ko translations (scripts/i18n/).
   *This blocks #1682 merge today.*

## P1 — correctness / security, surfaces before GA

6. **Stale `spawnableAgentNames` on agent rename/delete.** **[reported]** Stored as case-insensitive
   NAMES (`AgentDelegationConfiguration.swift:234`), never reconciled with AgentManager. Rename →
   spawn silently fails; delete → dead name lingers; **delete+recreate same name → new persona
   silently inherits spawnable=ON** (privilege re-grant). **Build:** reconcile on rename/delete
   (key by agent id, or prune on persona mutation).

7. **`/v1/images/upscale` is reachable but backed by a `notImplemented` stub.** **[reported]**
   Route + DTO + `ImageGenerationService.upscale` are wired, model field is required, no upscale
   model ships, vMLXFlux SeedVR2 throws `notImplemented`. Docs imply it works. **Build:** hide the
   endpoint until an upscaler ships, or return a clear 501 + document it.

8. **jpeg/webp `output_format` accepted but only PNG is written.** **[reported]** Engine writer is
   PNG-only (`ImageGenerationTypes.swift:15-16`), `stageInput` hardcodes `.png`; docs claim
   "valid PNG/JPEG." **Build:** wire the jpeg/webp writer or reject non-PNG with a clear error.

9. **Image error status by string-matching `error.description`** (`HTTPHandler.swift:6140-6148`).
   **[reported]** `ImageGenerationError` is a real enum; the status mapping re-parses the rendered
   string, so e.g. `unknownModel` → 500 instead of 404. **Build:** map from the enum cases.

10. **Zero-image "success."** **[reported]** A clean stream that yields no image returns a
    success envelope with `images:[]` (`NativeImageJobCoordinator.swift:421`) / HTTP `{"data":[]}`
    200. **Build:** treat zero images as an explicit error.

11. **Scan failure masquerades as "no model installed."** **[reported]**
    `(try? availableModels()) ?? []` (`NativeImageJobCoordinator.swift:353/470`,
    `HTTPHandler.swift:6165`) turns an I/O error into an empty catalog → "no ready model."
    **Build:** distinguish scan-error from empty-catalog.

## P2 — robustness / dead code / cleanup

12. **`.emptyResponseExhausted` arms in SpawnTool/LocalTextDelegateTool are unreachable.** **[reported]**
    Text-only subagents hit `.toolRejected` first (`stopOnToolRejection`), so `completedToolWork`
    never sets. The arms I added for the merge are correct defensively but dead for this caller.
    **Build:** document as HTTP/plugin-only, or make one successful tool set the flag if/when
    subagents get tools.
13. **`isImageOnlyContent` untested + edge cases.** **[reported]** Purely textual markdown-image
    regex (`ContentBlock.swift:871`); doesn't distinguish edit vs generate; a pure-image text turn
    with no prose loses its overflow/Inspect menu. **Build:** a unit test over the edge cases.
14. **`multipleSourceImages` advertised per-model but never enforced** (`ImageGenerationService.swift:172`)
    — non-qwen edit models still get handed multiple sources. **[reported]**
15. **`estimatedChatModelBytes == 0` silently skips the RAM preflight** for unknown-size bundles
    (`ChatResidencyHandoff.swift:120-127`). **[reported]**
16. **`maxToolCalls` reserved field** — already documented (PRODUCTION_READINESS), kept for forward
    compat. *Not a gap; listed for completeness.* **[verified]**

## Test coverage gaps (UNTESTED before production)

`SpawnTool` execute path, `AgentSubagentRunner`, `LocalTextDelegateTool` success/digest mapping,
the `/v1/images/*` HTTP handlers (only a source-grep contract test exists), `image_edit` execution,
`isImageOnlyContent`, the MetalGate **image** exclusive lane (MetalGateTests covers
embedding/gen/load only), `ChatResidencyHandoff` (preflight/unload/restore — zero tests), the
detached image job soft-cancel. **Biggest single untested risk:** `ChatResidencyHandoff`
unload→run→restore + memory preflight, interleaved with the untested MetalGate image lane — a
restore failure silently strands the chat model.

## Known residuals (already documented — see PRODUCTION_READINESS.md)

- One-turn chained gen→edit is non-deterministic (image→reload→generation handoff stall).
- Sustained back-to-back churn can crash in MLX `CommandEncoder`. Both are vmlx/residency-level,
  not osaurus-drain-fixable. Reliable paths: direct `/images` API + separate-turn editing.

## Doc rot to fix (claims that no longer match code)

- `CACHE_WINDOW_INVESTIGATION.md` calls chained one-turn gen→edit "FIXED + PROVEN" and also
  "model limitation" and also "not a model limitation" — self-contradictory; PRODUCTION_READINESS
  (newest) is the truth. Mark CACHE_WINDOW stale.
- `SUBAGENT_TEAM_SPEC.md:58-63` annotates SpawnTool/AgentSubagentRunner "(being built)" — shipped.
- Design docs name `Agent.spawnable`; the real field is `Agent.spawnDelegationEnabled` + the global
  `spawnableAgentNames` list. Reconcile naming + document the dual gate + its precedence.
- `NATIVE_SWIFT_IMAGE_GENERATION_INTEGRATION.md` references a `BatchEngine/MLXBatchAdapter` image
  path (actual: `ImageGenerationService → FluxEngine`), a combined `image_job` tool (actual: two
  separate tools), and a stale vmlx pin `d725c63f` (actual resolved pin `6b77b1ee`).

## Refuted this audit (do NOT action)

- **vmlx `finishSlot` GPU drain "missing from the pinned engine."** **[refuted]** The authoritative
  build checkout (`build/DerivedData/SourcePackages/checkouts/vmlx-swift`) is at `6b77b1ee` and
  `finishSlot` (BatchEngine.swift:2458) DOES call `Stream().synchronize()` at :2690 before
  `continuation.finish()`. The audit read the stale `.build/checkouts` (the `swift test` path,
  d35c0744). The drain is present; 0-crash live stress is consistent. Lesson: read deps from
  `DerivedData/SourcePackages`, not `.build/checkouts`.
