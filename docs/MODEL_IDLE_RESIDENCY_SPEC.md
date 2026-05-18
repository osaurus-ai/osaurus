# Model Idle Residency Specification

Status: proposal for PR #1057 follow-up implementation. This document is intentionally docs-only; it does not change runtime behavior.

## Goal

Let users choose how long a local model stays resident after API or chat activity before Osaurus unloads the model from memory.

This is an Osaurus runtime policy, not a vmlx-swift engine feature. vmlx-swift should continue to own model execution, `BatchEngine`, tokenizer/cache primitives, and shutdown mechanics. Osaurus owns user settings, API semantics, window/session state, memory policy, and the future server control panel.

## Current State

The current runtime already has the primitives needed for a keep-awake policy:

- `Packages/OsaurusCore/Models/Configuration/ServerConfiguration.swift`
  - `modelEvictionPolicy` controls strict single-model eviction versus manual multi-model retention.
- `Packages/OsaurusCore/Services/ModelRuntime.swift`
  - `unload(name:)` shuts down the cached `BatchEngine`, waits on `ModelLease`, disables container caching, removes the holder, synchronizes GPU work, and clears MLX memory.
  - `unloadModelsNotIn(_:)` unloads cached models not referenced by active chat windows or active leases.
  - `clearAll()` shuts down all engines and containers.
  - `cachedModelSummaries()` exposes resident model names for status surfaces.
- `Packages/OsaurusCore/Services/ModelRuntime/ModelLease.swift`
  - active generations hold a per-model lease so unload paths wait before freeing buffers.
- `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift`
  - window close currently calls `ModelRuntime.shared.unloadModelsNotIn(active)` as an immediate GC pass.
- `Packages/OsaurusCore/Networking/HTTPHandler.swift`
  - health/status output already includes loaded model names and in-flight lease counts.
- `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
  - Settings already has a Local Inference / Model Management section for model eviction policy.

The missing piece is a residency timer that treats "no active lease" as the start of an idle countdown instead of unloading immediately or retaining indefinitely.

## User-Facing Behavior

Add a "Keep model loaded after use" setting in Local Inference / Model Management.

Recommended options:

| UI label | Runtime value | Behavior |
| --- | ---: | --- |
| Immediately | `0` seconds | Unload as soon as no active generation lease and no explicit active-window keep hint remains. |
| 5 minutes | `300` seconds | Keep the model resident for 5 minutes after the last completed generation. |
| 15 minutes | `900` seconds | Keep the model resident for 15 minutes after the last completed generation. Recommended default if product chooses a new user-friendly default. |
| 30 minutes | `1800` seconds | Useful for repeated short local API calls. |
| 1 hour | `3600` seconds | Useful for workstation/server use. |
| Never | `nil` | Do not unload from idle timers; manual unload, strict model switch, app quit, and memory-pressure cleanup still apply. |

Open default decision:

- Conservative compatibility default: preserve current effective behavior by using `nil` for manual multi-model retention and immediate unload for existing strict GC call sites.
- Product default: use `900` seconds so API users do not pay a cold-load penalty after every short pause.

The implementation should make the default explicit in `ServerConfiguration.default` and cover missing legacy config keys in decode tests.

## Runtime Contract

### Idle is measured after stream lifetime

The timer starts only after the generation stream releases its `ModelLease`. It must not start at request admission, first token, last token, or HTTP connection creation.

### Any new use resets the timer

Starting a new generation for the same model cancels that model's pending idle-unload task and updates the model's last-used marker.

### Unload re-checks state before freeing buffers

When a timer fires, it must re-check:

- the last-used marker still matches the marker captured when the timer was scheduled;
- `ModelLease.shared.count(for:) == 0`;
- the model is still resident;
- strict/manual policy has not already unloaded or replaced the model.

If any check fails, the timer exits without unloading.

### Strict single-model eviction still wins

`ModelEvictionPolicy.strictSingleModel` should continue to unload other models when loading a different model. The idle timer only governs the current model after it becomes idle.

### Manual multi-model retention can still use timers

`ModelEvictionPolicy.manualMultiModel` means Osaurus does not evict other models just because a different model is used. If the idle setting is a positive timeout, each resident model gets its own independent idle countdown.

### Sleep means memory residency, not cache deletion

Idle unload should unload weights and runtime buffers. It should not delete disk cache entries by default. Clearing disk cache is a separate destructive action and should remain explicit.

## Proposed Types

Use a dedicated config type instead of overloading `ModelEvictionPolicy`.

```swift
public enum ModelIdleResidencyPolicy: Codable, Equatable, Sendable {
    case immediately
    case afterSeconds(Int)
    case never
}
```

The Codable representation should be stable and friendly to JSON config migrations:

```json
{ "mode": "after_seconds", "seconds": 900 }
```

Valid modes:

- `immediately`
- `after_seconds`
- `never`

Validation:

- `after_seconds` must clamp to `[30, 86_400]` when loaded from persisted config.
- UI presets may include `0`, but the decoded representation for immediate should be `.immediately`, not `.afterSeconds(0)`.
- Unknown or malformed values should fall back to `ServerConfiguration.default.modelIdleResidencyPolicy`.

## Proposed New Runtime Unit

Create `Packages/OsaurusCore/Services/ModelRuntime/ModelResidencyManager.swift`.

Responsibilities:

- Store per-model last-used generations.
- Cancel pending timers on model use, manual unload, strict eviction, and `clearAll`.
- Schedule idle unload after stream completion.
- Re-check `ModelLease` before calling `ModelRuntime.unload(name:)`.
- Provide a diagnostics snapshot for `/health` and the future server panel.

Suggested interface:

```swift
public actor ModelResidencyManager {
    public struct Snapshot: Equatable, Sendable {
        public var modelName: String
        public var lastUsedAt: Date
        public var unloadAt: Date?
        public var policy: ModelIdleResidencyPolicy
    }

    public static let shared = ModelResidencyManager()

    public func markActive(modelName: String, now: Date = Date())
    public func scheduleIdleUnload(
        modelName: String,
        policy: ModelIdleResidencyPolicy,
        now: Date = Date(),
        unload: @Sendable @escaping (String) async -> Void,
        leaseCount: @Sendable @escaping (String) async -> Int,
        isResident: @Sendable @escaping (String) async -> Bool
    )
    public func cancel(modelName: String)
    public func cancelAll()
    public func snapshots(now: Date = Date()) -> [Snapshot]
}
```

The injectable closures keep the actor unit-testable without requiring real MLX model loads.

## Integration Plan

### Task 1: Configuration

Files:

- Modify `Packages/OsaurusCore/Models/Configuration/ServerConfiguration.swift`.
- Modify `Packages/OsaurusCore/Tests/Networking/ServerConfigurationStoreTests.swift`.

Steps:

1. Add `ModelIdleResidencyPolicy`.
2. Add `public var modelIdleResidencyPolicy: ModelIdleResidencyPolicy` to `ServerConfiguration`.
3. Add `modelIdleResidencyPolicy` to `CodingKeys`.
4. Decode with default fallback.
5. Add the new property to the initializer and `default`.
6. Add tests for missing key, valid `after_seconds`, `immediately`, `never`, malformed fallback, and clamp boundaries.

Expected tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore \
  --filter ServerConfigurationStoreTests
```

### Task 2: Residency Manager

Files:

- Create `Packages/OsaurusCore/Services/ModelRuntime/ModelResidencyManager.swift`.
- Create `Packages/OsaurusCore/Tests/Service/ModelResidencyManagerTests.swift`.

Steps:

1. Write tests for active marker reset, timer scheduling, new-use cancellation, `never`, `immediately`, active lease protection, not-resident no-op, and `cancelAll`.
2. Implement the actor with one `Task<Void, Never>` per model.
3. Ensure timers use the captured last-used marker and re-check before unload.

Expected tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore \
  --filter ModelResidencyManagerTests
```

### Task 3: ModelRuntime Wiring

Files:

- Modify `Packages/OsaurusCore/Services/ModelRuntime.swift`.
- Modify `Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift`.

Steps:

1. Call `ModelResidencyManager.shared.markActive(modelName:)` immediately before or after `ModelLease.shared.acquire(modelName)`.
2. After `ModelLease.shared.release(modelName)` in the producer wrapper, load the current `ServerConfiguration` and schedule idle unload.
3. Cancel pending timers inside `unload(name:)` and `clearAll()`.
4. Keep strict single-model eviction behavior in `loadContainer` unchanged; when strict eviction unloads another model, cancel that model's timer first.
5. Add source-policy tests that assert the runtime wires `markActive`, `scheduleIdleUnload`, and `cancelAll` in the expected lifecycle paths.

Expected tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore \
  --filter 'RuntimePolicySourceTests|ModelLeaseTests|MLXBatchAdapterTests'
```

### Task 4: Window GC Policy

Files:

- Modify `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift`.
- Extend `Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift` or add a focused ChatWindowManager source-policy test.

Steps:

1. Replace immediate window-close GC with policy-aware behavior.
2. If the idle policy is `.immediately`, preserve current `unloadModelsNotIn(active)` behavior.
3. If the policy is `.afterSeconds` or `.never`, do not immediately unload the just-closed model solely because its window closed; let the residency manager decide after stream completion or user idle.
4. Keep `ModelLease` as the crash-safety authority.

Expected tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore \
  --filter RuntimePolicySourceTests
```

### Task 5: Status and Future Server Panel Data

Files:

- Modify `Packages/OsaurusCore/Networking/HTTPHandler.swift`.
- Modify `Packages/OsaurusCore/Tests/Networking/HTTPHandlerChatStreamingTests.swift` or add a focused health/status test if the project already has one.

Steps:

1. Add residency diagnostics to the health/status JSON:
   - `resident_models[].name`
   - `resident_models[].is_current`
   - `resident_models[].inflight`
   - `resident_models[].idle_unload_at`
   - `resident_models[].idle_seconds_remaining`
2. Keep the existing `loaded`, `current_model`, and `inflight` fields for compatibility.
3. Use `ModelRuntime.cachedModelSummaries()`, `ModelLease.snapshot()`, and `ModelResidencyManager.snapshots()` as the data sources.

Expected tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore \
  --filter HTTPHandlerChatStreamingTests
```

### Task 6: Settings UI

Files:

- Modify `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`.
- Add focused source-policy coverage to `Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift` if no SwiftUI settings test harness exists.

Steps:

1. Add a picker below the existing eviction policy segmented control.
2. Label it "Keep model loaded after use".
3. Provide presets: Immediately, 5 minutes, 15 minutes, 30 minutes, 1 hour, Never.
4. Save/load through `ServerConfigurationStore`.
5. Keep copy explicit that this unloads memory residency, not disk cache.

Expected tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/OsaurusCore \
  --filter RuntimePolicySourceTests
```

### Task 7: Documentation

Files:

- Modify `docs/INFERENCE_RUNTIME.md`.
- Modify `docs/OpenAI_API_GUIDE.md` if status JSON changes.
- Modify `docs/FEATURES.md`.

Steps:

1. Document the distinction between eviction policy and idle residency policy.
2. Document that idle unload preserves disk cache.
3. Document that vmlx-swift remains the execution/cache primitive provider while Osaurus owns user residency policy.
4. Document status fields if Task 5 lands.

Expected checks:

```bash
rg -n "modelIdleResidencyPolicy|ModelIdleResidencyPolicy|idle_unload|Keep model loaded" \
  Packages/OsaurusCore docs
git diff --check
```

## Acceptance Matrix

| Case | Expected result |
| --- | --- |
| API request completes with 15-minute policy | Model stays resident; idle unload is scheduled for 15 minutes after stream release. |
| Same model receives another API request before timeout | Existing timer cancels; new timeout starts after the second stream releases. |
| Stream is cancelled by Stop button | Lease releases; idle timer starts after cancellation cleanup completes. |
| Timer fires while another stream holds a lease | Timer exits without unloading; the later stream schedules a fresh timer on release. |
| Strict mode loads a different model | Other model unloads immediately through existing strict eviction path. |
| Manual multi-model plus 30-minute policy | Each resident model unloads independently after its own idle timeout. |
| Never policy | Idle timers do not unload; manual unload and clear-all still work. |
| Immediately policy | Behavior matches immediate GC once no active lease remains. |
| Disk cache exists for model | Idle unload does not delete disk cache entries. |
| App quits or user clears cache | Existing explicit clear/unload behavior wins over timers. |

## Non-Goals

- Do not add sleep/wake `NSWorkspace` observers in this feature.
- Do not change vmlx-swift APIs.
- Do not change JIT, batching, reasoning, tokenizer, tool-call, or cache-scope behavior.
- Do not delete disk cache on idle unload.
- Do not add model preloading or scheduled warmup.

## Implementation Notes

- Keep all runtime changes in Osaurus. Do not add app-policy timers to vmlx-swift.
- Keep timer code actor-isolated and injectable for unit tests.
- Avoid using `Task.detached`; use regular tasks created from the actor and cancel them explicitly.
- Avoid sleeping on the main actor.
- Never free a model before `ModelLease.shared.waitForZero(name)` is satisfied.
- Preserve current `BatchEngine` shutdown-before-unload ordering in `ModelRuntime.unload(name:)`.
- Treat health/status field additions as additive API changes.
