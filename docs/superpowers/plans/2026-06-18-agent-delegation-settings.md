# Agent Delegation Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the persisted settings and model-candidate resolution needed before Osaurus can safely run cloud-to-local text delegation or agent-triggered native image jobs.

**Architecture:** Introduce a small `AgentDelegationConfiguration` model with explicit permission, load, sharing, and budget fields. Persist it under `~/.osaurus/config/agent-delegation.json` using the same snapshot/store pattern as the privacy filter, and add `ModelPickerItem` helpers that resolve downloaded local text, image generation, and image edit candidates without injecting catalogs into prompts.

**Tech Stack:** Swift 6.2, Swift Testing, OsaurusCore internal models, existing `ModelPickerItem` and `ImageModelCapabilities`.

---

### Task 1: Configuration Model

**Files:**
- Create: `Packages/OsaurusCore/Models/AgentDelegation/AgentDelegationConfiguration.swift`
- Test: `Packages/OsaurusCore/Tests/AgentDelegation/AgentDelegationConfigurationTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that assert defaults, clamping, and JSON round-trip:

```swift
import Foundation
import Testing
@testable import OsaurusCore

@Suite("Agent delegation configuration")
struct AgentDelegationConfigurationTests {
    @Test("defaults are low RAM and ask-first")
    func defaultsAreSafe() {
        let config = AgentDelegationConfiguration.default
        #expect(config.cloudTextDelegationEnabled == false)
        #expect(config.textDelegateLoadPolicy == .unloadAfterJob)
        #expect(config.imageJobLoadPolicy == .agentSingleResidency)
        #expect(config.permissionDefaults.localTextDelegate == .ask)
        #expect(config.permissionDefaults.imageGenerate == .ask)
        #expect(config.permissionDefaults.imageEdit == .ask)
        #expect(config.budgets.maxDelegateTokens == 2048)
        #expect(config.budgets.maxDelegateTurns == 1)
        #expect(config.budgets.maxToolCalls == 0)
        #expect(config.budgets.maxElapsedSeconds == 120)
    }

    @Test("budget normalization clamps invalid values")
    func budgetNormalizationClampsInvalidValues() {
        let raw = AgentDelegationBudgets(
            maxDelegateTokens: -10,
            maxDelegateTurns: 0,
            maxToolCalls: -1,
            maxElapsedSeconds: 0
        )
        #expect(raw.normalized.maxDelegateTokens == 256)
        #expect(raw.normalized.maxDelegateTurns == 1)
        #expect(raw.normalized.maxToolCalls == 0)
        #expect(raw.normalized.maxElapsedSeconds == 15)
    }

    @Test("configuration round trips stable raw values")
    func configurationRoundTrip() throws {
        let config = AgentDelegationConfiguration(
            cloudTextDelegationEnabled: true,
            defaultLocalTextDelegateModelId: "local-chat",
            defaultImageGenerationModelId: "flux-schnell",
            defaultImageEditModelId: "qwen-image-edit",
            textDelegateLoadPolicy: .keepWarmWhenSafe,
            imageJobLoadPolicy: .manualPanelKeepsImageLoaded,
            sharingPolicy: .askBeforeExpandedSharing,
            permissionDefaults: AgentDelegationPermissionDefaults(
                localTextDelegate: .alwaysAllow,
                localTextDelegateToolUse: .deny,
                imageGenerate: .ask,
                imageEdit: .alwaysAllow
            ),
            budgets: AgentDelegationBudgets(
                maxDelegateTokens: 4096,
                maxDelegateTurns: 2,
                maxToolCalls: 3,
                maxElapsedSeconds: 240
            )
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentDelegationConfiguration.self, from: data)

        #expect(decoded == config)
        #expect(decoded.permissionDefaults.localTextDelegate.rawValue == "always_allow")
        #expect(decoded.textDelegateLoadPolicy.rawValue == "keep_warm_when_safe")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --package-path Packages/OsaurusCore --filter AgentDelegationConfigurationTests
```

Expected: compile failure because the `AgentDelegationConfiguration` types do not exist.

- [ ] **Step 3: Add the configuration model**

Create `AgentDelegationConfiguration.swift` with the enums, defaults, and normalization used by the tests.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
swift test --package-path Packages/OsaurusCore --filter AgentDelegationConfigurationTests
```

Expected: all `AgentDelegationConfigurationTests` pass.

### Task 2: Persistent Store

**Files:**
- Create: `Packages/OsaurusCore/Models/AgentDelegation/AgentDelegationConfigurationStore.swift`
- Test: `Packages/OsaurusCore/Tests/AgentDelegation/AgentDelegationConfigurationStoreTests.swift`

- [ ] **Step 1: Write the failing store tests**

Add tests for missing-file defaults, save/load, snapshot cache, and test override cleanup.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --package-path Packages/OsaurusCore --filter AgentDelegationConfigurationStoreTests
```

Expected: compile failure because the store does not exist.

- [ ] **Step 3: Add `AgentDelegationConfigurationStore`**

Mirror the `PrivacyFilterStore` shape: `setOverrideDirectory(_:)`, `load()`, `save(_:)`, `snapshot()`, `invalidateSnapshot()`, and a main-thread `.agentDelegationConfigurationChanged` notification.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
swift test --package-path Packages/OsaurusCore --filter AgentDelegationConfigurationStoreTests
```

Expected: all store tests pass.

### Task 3: Model Candidate Resolution

**Files:**
- Modify: `Packages/OsaurusCore/Models/Configuration/ModelPickerItem.swift`
- Test: `Packages/OsaurusCore/Tests/Model/AgentDelegationModelPickerTests.swift`

- [ ] **Step 1: Write failing candidate tests**

Add tests that prove local text delegates come only from local chat-capable items, generation defaults come only from ready text-to-image models, edit defaults come only from ready image-edit models, and configured missing ids return `nil`.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --package-path Packages/OsaurusCore --filter AgentDelegationModelPickerTests
```

Expected: compile failure because the helper methods do not exist.

- [ ] **Step 3: Add `ModelPickerItem` candidate helpers**

Add internal helpers:

```swift
var isLocalTextDelegateCandidate: Bool
var isImageGenerationDelegateCandidate: Bool
var isImageEditDelegateCandidate: Bool
```

Add array helpers:

```swift
var localTextDelegateCandidates: [ModelPickerItem]
var imageGenerationDelegateCandidates: [ModelPickerItem]
var imageEditDelegateCandidates: [ModelPickerItem]
func agentDelegationCandidate(id: String?, kind: AgentDelegationModelKind) -> ModelPickerItem?
func defaultAgentDelegationCandidate(kind: AgentDelegationModelKind) -> ModelPickerItem?
```

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
swift test --package-path Packages/OsaurusCore --filter AgentDelegationModelPickerTests
```

Expected: all model picker candidate tests pass.

### Task 4: Settings UI Scaffolding

**Files:**
- Create: `Packages/OsaurusCore/Views/Settings/AgentDelegationSettingsSection.swift`
- Modify: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`

- [ ] **Step 1: Add a settings section view**

The view should bind to `AgentDelegationConfiguration`, show toggles/pickers for the new persisted fields, and filter picker options through the Task 3 helpers.

- [ ] **Step 2: Mount the section in `ConfigurationView`**

Load `AgentDelegationConfigurationStore.snapshot()` into state, pass `coreModelPickerItems`, and save on changes.

- [ ] **Step 3: Build OsaurusCore**

Run:

```bash
swift build --package-path Packages/OsaurusCore
```

Expected: build succeeds.

### Task 5: Verification And Docs

**Files:**
- Modify: `docs/NATIVE_SWIFT_IMAGE_AGENT_JOB_FLOW.md`

- [ ] **Step 1: Mark the settings slice as source-wired**

Update current status to say the persisted settings/model-resolution slice is implemented, while the runtime coordinators and live e2e flows remain blocked.

- [ ] **Step 2: Run focused tests and diff check**

Run:

```bash
swift test --package-path Packages/OsaurusCore --filter AgentDelegation
swift test --package-path Packages/OsaurusCore --filter AgentDelegationModelPickerTests
git diff --check
```

Expected: focused tests pass and `git diff --check` is silent.

- [ ] **Step 3: Commit**

Run:

```bash
git add docs/superpowers/plans/2026-06-18-agent-delegation-settings.md Packages/OsaurusCore/Models/AgentDelegation Packages/OsaurusCore/Tests/AgentDelegation Packages/OsaurusCore/Tests/Model/AgentDelegationModelPickerTests.swift Packages/OsaurusCore/Models/Configuration/ModelPickerItem.swift Packages/OsaurusCore/Views/Settings/AgentDelegationSettingsSection.swift Packages/OsaurusCore/Views/Settings/ConfigurationView.swift docs/NATIVE_SWIFT_IMAGE_AGENT_JOB_FLOW.md
git commit -m "Add agent delegation settings scaffolding"
```

Expected: one focused commit with settings, tests, and docs.

## Self-Review

- Spec coverage: covers persisted local text/image defaults, ask/deny/always-allow policy values, load policy, budgets, sharing policy, downloaded-model candidate filtering, and status documentation.
- Remaining gaps: no `local_delegate` tool, no `image_job` tool, no coordinator, no unload/restore, no permission sheet, and no live e2e proof. Those belong in the next implementation plan.
- Placeholder scan: no deferred implementation markers are used in this plan.
