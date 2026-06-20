# Agent Delegation Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Agent Delegation settings, native image jobs, and cloud-to-local text delegation cohesive without recursive worker processes or prompt-forced behavior.

**Architecture:** Settings and downloaded-model picker filtering are already source-wired. Runtime delegation now uses two modular surfaces: `image_generate` / `image_edit` route through `NativeImageJobCoordinator`, while `local_delegate` is a bounded text-only child loop built on `AgentToolLoop`, modeled after `sandbox_reduce`.

**Tech Stack:** Swift 6.2, Swift Testing, OsaurusCore `AgentToolLoop`, local MLX model discovery through `ModelManager.findInstalledModel`, native image bundles through `ImageGenerationService`.

---

## Current Source Status

- [x] `AgentDelegationConfiguration` stores master enablement, cloud text delegation, image delegation, default local text/image models, load policies, sharing policy, permission defaults, and budgets.
- [x] `AgentDelegationConfigurationStore` persists settings under `~/.osaurus/config/agent-delegation.json`.
- [x] `AgentDelegationSettingsSection` exposes the settings UI and filters picker rows through downloaded-model candidate helpers.
- [x] `image_generate` and `image_edit` are built-in tools, gated by `agentDelegationEnabled && imageDelegationEnabled`.
- [x] `NativeImageJobCoordinator` resolves requested/configured/default image models only when the selected bundle is installed, ready, and compatible with the requested job kind; stale, incomplete, and wrong-kind selections fail before chat-model unload.
- [x] `image_generate`, `image_edit`, and `local_delegate` enrich approval prompt arguments with the resolved local model and load policy before the user sees an `ask` permission sheet.
- [x] `local_delegate` is registered as a built-in tool, gated by `agentDelegationEnabled && cloudTextDelegationEnabled`.
- [x] `local_delegate` resolves only installed local chat models via `ModelManager.findInstalledModel(named:)`, so the `~/.mlxstudio/models -> ~/models` symlink and moved `~/models/JANGQ-AI`, `~/models/OsaurusAI`, and `~/models/image` roots remain the source of truth.
- [x] `local_delegate` returns a compact result envelope only; it does not replay the child transcript back to the parent cloud model.
- [x] `local_delegate` unloads the delegate model after the job for `.unloadAfterJob` and `.strictSingleJobResidency`.
- [x] `local_delegate` is text-only in this slice. It refuses child tool calls instead of silently granting local file/shell/tool access. Tool-using local delegates require the separate `localTextDelegateToolUse` permission flow.

## Verification Status

- [x] `swift build --package-path Packages/OsaurusCore` passed locally on 2026-06-18 after the stricter image resolver and resolved-model permission prompt changes.
- [x] `git diff --check` passed locally on 2026-06-18 after the same changes.
- [x] Local model roots were inspected on 2026-06-18:
  - `~/.mlxstudio/models` is a symlink to `/Users/eric/models`.
  - `/Users/eric/models/JANGQ-AI` contains Laguna and MiniMax folders.
  - `/Users/eric/models/OsaurusAI` contains VibeThinker and Gemma folders.
  - `/Users/eric/models/image` contains 13 mflux image bundles.
- [ ] `swift test --package-path Packages/OsaurusCore --filter AgentDelegationToolAvailabilityTests` is blocked locally by the existing package-wide `no such module 'Testing'` toolchain failure before focused tests execute.
- [ ] `swift test --package-path Packages/OsaurusCore --filter NativeImageJobCoordinatorTests` is blocked locally by the same package-wide `no such module 'Testing'` failure before focused tests execute.
- [ ] Swift Testing proof on a compatible host has not yet been rerun for the new `local_delegate` and strict image resolver tests.
- [ ] Foreground app/UI proof has not yet shown cloud chat selecting and calling `local_delegate`.
- [ ] Foreground app/UI proof has not yet shown local image generation/edit delegation from real chat turns.

## Next Tasks

### Task 1: Focused Tests On A Swift Testing-Capable Host

**Files:**
- Test: `Packages/OsaurusCore/Tests/AgentDelegation/AgentDelegationToolAvailabilityTests.swift`
- Test: `Packages/OsaurusCore/Tests/AgentDelegation/NativeImageJobCoordinatorTests.swift`
- Source: `Packages/OsaurusCore/Tools/LocalTextDelegateTool.swift`
- Source: `Packages/OsaurusCore/Tools/NativeImageTools.swift`
- Source: `Packages/OsaurusCore/Services/AgentDelegation/NativeImageJobCoordinator.swift`
- Source: `Packages/OsaurusCore/Tools/ToolRegistry.swift`

- [ ] **Step 1: Sync or pull this branch on a Swift Testing-capable checkout**

Expected: the checkout is on `feat/image-generation-vmlxflux` at the commit being proven, and `swift --version` exposes the `Testing` module.

- [ ] **Step 2: Run focused Agent Delegation tests**

Run:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 swift test --package-path Packages/OsaurusCore --filter AgentDelegationToolAvailabilityTests
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 swift test --package-path Packages/OsaurusCore --filter NativeImageJobCoordinatorTests
```

Expected: tests compile and pass, including the `local_delegate` schema gating, stale direct execution, missing configured local text model, strict requested/configured image model resolution, and wrong-kind/incomplete image model refusal rows.

### Task 2: Live App Tool-Schema Proof

**Files:**
- Source: `Packages/OsaurusCore/Tools/ToolRegistry.swift`
- Source: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`
- Runtime docs: `docs/NATIVE_SWIFT_IMAGE_AGENT_JOB_FLOW.md`

- [ ] **Step 1: Build keychain-free app**

Run the branch's existing live-proof build script and save logs under a dated proof root.

- [ ] **Step 2: Toggle Agent Delegation off and inspect outgoing tools**

Expected: `local_delegate`, `image_generate`, and `image_edit` are absent from the outgoing schema.

- [ ] **Step 3: Toggle master + cloud text delegation on and inspect outgoing tools**

Expected: `local_delegate` is present without injecting a downloaded-model catalog into the prompt.

- [ ] **Step 4: Toggle image delegation on and inspect outgoing tools**

Expected: `image_generate` and `image_edit` are present only when image delegation is enabled.

### Task 3: Live Cloud-To-Local Text Delegate Proof

**Files:**
- Source: `Packages/OsaurusCore/Tools/LocalTextDelegateTool.swift`
- Source: `Packages/OsaurusCore/Services/Chat/AgentToolLoop.swift`

- [ ] **Step 1: Select a cloud/API chat model and a downloaded local delegate model**

Use one installed local chat model from the Settings picker, such as a VibeThinker or Laguna bundle that resolves through `ModelManager.findInstalledModel`.

- [ ] **Step 2: Ask the cloud model for a bounded helper task**

Expected: the cloud model calls `local_delegate` with a compact `task` and optional compact `context`.

- [ ] **Step 3: Verify the result envelope**

Expected: the tool result contains `kind=local_text_delegate_result`, selected local model, summary, iterations, elapsed time, residency status, and unload status.

- [ ] **Step 4: Verify no local transcript replay**

Expected: the parent cloud model receives only the compact result envelope, not the child message history.

### Task 4: Permission And RAM Proof

**Files:**
- Source: `Packages/OsaurusCore/Tools/LocalTextDelegateTool.swift`
- Source: `Packages/OsaurusCore/Tools/NativeImageTools.swift`
- Source: `Packages/OsaurusCore/Services/AgentDelegation/NativeImageJobCoordinator.swift`

- [ ] **Step 1: Prove `deny`, `ask`, and `always_allow` for `local_delegate`**

Expected: deny returns a rejected envelope with no local model load; ask prompts with the resolved local text model visible; always_allow runs without prompting.

- [ ] **Step 2: Prove delegate unload behavior**

Expected: `.unloadAfterJob` and `.strictSingleJobResidency` unload the delegate model after completion or failure; `.keepWarmWhenSafe` does not unload in this source slice.

- [ ] **Step 3: Prove image job unload/restore with real local chat residency**

Expected: local chat model unloads before image generation/edit and restores or warm-loads after image job under `agent_single_residency`.

- [ ] **Step 4: Prove stale and wrong-kind image model settings fail early**

Expected: missing, incomplete, and edit-vs-generate mismatched model selections return typed unavailable errors before local chat residency is changed.

### Task 5: Future Tool-Using Delegate Slice

**Files:**
- Source: `Packages/OsaurusCore/Tools/LocalTextDelegateTool.swift`
- Source: `Packages/OsaurusCore/Tools/SandboxReduceTool.swift`

- [ ] **Step 1: Add tests before enabling any child tools**

Tests must prove that child file/shell/tool access stays absent unless `localTextDelegateToolUse` policy allows it.

- [ ] **Step 2: Add a restricted allowlist**

The first safe allowlist should be read-only and explicit. Do not expose full `ToolRegistry` access to the child delegate.

- [ ] **Step 3: Add permission UI proof**

The permission prompt must name the child tool scope and selected local model before any child tool access is granted.

## Non-Negotiables

- Do not add prompt coercion, forced reasoning markers, parser masking, sampler overrides, or hidden RAM guards to make a row look successful.
- Do not spawn Python, shell, or recursive local LLM worker processes for this flow.
- Do not hardcode the moved model directories into runtime decisions. Resolve through the existing downloaded-model catalog and symlink-aware discovery.
- Do not mark app/UI behavior `GREEN` until the exact running app proof exists with logs, screenshots/transcripts, model ids, and resident-model state.
