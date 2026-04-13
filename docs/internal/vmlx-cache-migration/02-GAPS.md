# VMLX Cache Integration — Gaps, Fixes & Required Work

> Companion to the initial VMLX migration. This document catalogs every loose end
> after the first pass: things that work but are suboptimal, session-lifecycle
> hooks that became stale, UI affordances that no longer match reality, and API
> fields that lost their meaning. Each item is tagged with severity, effort,
> and exactly what to change.

**Status**: Initial migration complete and committed on `feat/vmlx-cache-migration` (`9d66eb12`).
**Scope**: Everything below is follow-up work — nothing here blocks the branch from building.

---

## Severity legend

| Tag | Meaning |
|-----|---------|
| 🔴 **P0** | Breaks a user-visible invariant or causes correctness regressions. Must fix before merge. |
| 🟠 **P1** | UX mismatch or minor stale state. Should fix before wide release. |
| 🟡 **P2** | Cosmetic / dead code / internal cleanup. Safe to defer. |
| 🟢 **P3** | Optional improvements, not required. |

---

## Table of Contents

1. [Dependency & build](#1-dependency--build)
2. [Session-lifecycle hooks that became no-ops](#2-session-lifecycle-hooks-that-became-no-ops)
3. [API fields that lost meaning](#3-api-fields-that-lost-meaning)
4. [UI affordances that no longer match reality](#4-ui-affordances-that-no-longer-match-reality)
5. [Orphaned / dead helper code](#5-orphaned--dead-helper-code)
6. [Default tuning / auto-detection improvements](#6-default-tuning--auto-detection-improvements)
7. [Settings UI gaps](#7-settings-ui-gaps)
8. [New cache-management UI](#8-new-cache-management-ui)
9. [Docs / API guide updates](#9-docs--api-guide-updates)
10. [Test updates](#10-test-updates)
11. [Full file-by-file action list](#11-full-file-by-file-action-list)

---

## 1. Dependency & build

### 1.1 🔴 **P0** — `swift-transformers` version conflict

**Where**: `Packages/OsaurusCore/Package.swift` line 18

**Problem**: `vmlx-swift-lm` introduced a `swift-transformers` dependency at
`from: "0.1.21"` (version range `[0.1.21, 1.0.0)`) for its unused macro string
literals. osaurus uses `from: "1.1.6"` (range `[1.1.6, 2.0.0)`). These ranges
**do not overlap** — SPM resolution will fail.

**Status**: Already patched on branch (uncommitted). osaurus downgraded to
`from: "0.1.21"`.

**What must happen**:
- [x] Edit `Package.swift` line 18 to `from: "0.1.21"` (done)
- [ ] Commit the change
- [ ] Verify osaurus's usage of `Tokenizers.Tokenizer`, `AutoTokenizer.from(modelFolder:)`,
      `applyChatTemplate(messages:tools:additionalContext:)` is compatible with 0.1.21
      API surface. These are core APIs that predate 1.0, so this should work — but
      `applyChatTemplate` with the `tools` parameter may need the newer signature.
      **Verify by checking `SwiftTransformersTokenizerLoader.swift` compiles** against 0.1.21.

**Alternative (cleaner)**: Have `vmlx-swift-lm` drop its unused `swift-transformers`
dependency entirely (no target in vmlx-swift-lm actually imports `Tokenizers` — it
only emits string literals referencing it via macros). This would restore osaurus
to `1.1.6`. **But the user said "osaurus agent only", so don't touch vmlx-swift-lm.**

---

### 1.2 🟡 **P2** — Package.resolved files were deleted

**Where**: `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
and `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Problem**: Both files were removed to force SPM to re-resolve with the new
`vmlx-swift-lm` dependency. On the next Xcode open, SPM will regenerate them.

**Verify**:
- [ ] Open the workspace in Xcode, let SPM resolve, verify both files are regenerated
      and reference `vmlx-swift-lm` (not `mlx-swift-lm`).
- [ ] Commit the regenerated files so CI doesn't re-resolve on every build.

---

## 2. Session-lifecycle hooks that became no-ops

### 2.1 🟠 **P1** — `ModelRuntime.invalidateSession()` is silently a no-op

**Where**: `Packages/OsaurusCore/Services/ModelRuntime.swift` lines 143-146

```swift
func invalidateSession(_ sessionId: String) {
    // No-op: CacheCoordinator handles eviction via LRU on PagedCacheManager.
}
```

**Callers**:
- `ChatWindowManager.closeWindow()` at `Managers/Chat/ChatWindowManager.swift:578`

**Why it's a no-op**: The old `KVCacheStore` was keyed by `sessionId`, so closing
a window could free that session's RAM immediately. The new `CacheCoordinator`
uses **content-addressed** paged caching (SHA-256 chain hash over token blocks),
so there's no per-session key to invalidate. The paged cache bounds itself via
`maxCacheBlocks` and evicts via LRU.

**Consequence**:
1. Memory that was tied to a closed session stays resident until LRU pressure
   evicts it — a user closing a huge-context window won't see immediate RAM
   reclamation.
2. A user with several big conversations may blow past `maxCacheBlocks` faster
   than expected because blocks from dead sessions still count.

**Options**:

**Option A — Accept the no-op (do nothing)**
- CacheCoordinator's LRU will evict eventually. Default `maxCacheBlocks` is
  1000–2000 (64 tokens each = 64k–128k tokens total). For typical usage this
  is fine.
- **Pro**: Zero code change.
- **Con**: User-visible "Close window" no longer frees RAM promptly.

**Option B — Add a cache-wipe hook to the coordinator (recommended)**
- Ask vmlx-swift-lm to expose `CacheCoordinator.invalidate(tokens: [Int])`
  so we can purge a specific token prefix. **But we can't touch vmlx-swift-lm.**
- Alternative: call `container.disableCaching()` + `enableCaching(config:)`
  to rebuild the coordinator fresh. Heavy-handed — wipes ALL cached state for
  the model, not just that session.

**Option C — Track session → token prefix mapping in osaurus and call coordinator
invalidate on close**
- Requires coordinator to support targeted eviction. It doesn't (as of current
  vmlx-swift-lm), so this isn't possible without touching the package.

**Recommendation**: **Option A for now**. Add a comment documenting the behavior
change. If users report stale RAM issues, add a "Clear KV Cache" button to the
UI that calls `disableCaching()` + `enableCaching()` on all loaded containers.

**Action items**:
- [ ] Update the `invalidateSession` doc comment to explicitly mention this is
      a no-op and why.
- [ ] Add a release-note entry: "Closing a chat window no longer instantly
      frees KV cache memory. The new content-addressed cache evicts via LRU
      as new conversations fill the cache."

---

### 2.2 🟡 **P2** — `MemoryContextAssembler` cache not cleared on session close

**Where**: `Services/Memory/MemoryContextAssembler.swift:16-22`

**Problem**: `MemoryContextAssembler` caches assembled memory contexts keyed by
`agentId` with a 10-second TTL. Session close does NOT invalidate this cache.

**Impact**: Very low. A user who closes a window and immediately opens a new one
with the same agent could see the stale memory context for up to 10 seconds.

**Fix**:
```swift
// In ChatWindowManager.closeWindow(), after invalidateSession:
if let sid = closedSessionId, let agentId = windows[id]?.agentId {
    await MemoryContextAssembler.shared.invalidateCache(agentId: agentId.uuidString)
}
```

**Action items**:
- [ ] Add the invalidate call to `ChatWindowManager.closeWindow()` at line ~578
- [ ] Verify `MemoryContextAssembler.shared.invalidateCache(agentId:)` is a
      public/internal method (it is, line 79-85 per audit)

---

### 2.3 🟡 **P2** — UI caches not session-scoped

**Where**:
- `Managers/ThreadCache.swift` (global NSCache)
- `Managers/BlockMemoizer.swift` (per-view in-memory dict)
- `Views/Chat/LaTeXRenderer.swift:21` (global NSCache, 500 items)

**Problem**: These caches survive session close. Since they're all content-keyed
(SHA-256 of markdown content, block ID + width, "latex-fontSize-color"), stale
entries can't leak across sessions — they'd need identical content to collide.

**Impact**: None in practice. NSCache auto-evicts under memory pressure, and
content-keyed hits are correct by definition.

**Action items**: **No action needed.** Flag for awareness only.

---

## 3. API fields that lost meaning

### 3.1 🟠 **P1** — `ChatCompletionRequest.cache_hint` is ignored by the cache layer

**Where**: `Models/API/OpenAIAPI.swift` lines 355-361

**Problem**: The API still accepts `cache_hint` and `session_id` fields, and
`GenerationParameters.cacheHint` / `sessionId` still flow through the request
pipeline. But the new `CacheCoordinator` uses token-content hashing internally,
so these fields are **ignored at the cache layer**.

**Why it's not P0**: The API still works — the cache just does its own thing
internally. A client passing `cache_hint` gets the same behavior as a client not
passing it (token-content lookup always happens).

**Decision needed**: Keep the fields for API backwards compat, or remove them?

**Recommendation**: **Keep them** for backwards compat. API consumers may pass
them; we'll just ignore them silently. The `prefix_hash` response field should
continue to be computed (via `ModelRuntime.computePrefixHash`) so clients that
store and re-send it still get valid request acceptance.

**Action items**:
- [ ] Update `docs/OpenAI_API_GUIDE.md` sections on "Session Reuse" (lines 244-266)
      and "Prefix Caching" (lines 268-293) to explain that these fields are
      preserved for compatibility but cache behavior is now automatic.
- [ ] Add a note: "As of vmlx cache migration, the server uses content-addressed
      paged caching internally. `session_id` and `cache_hint` are accepted but
      no longer affect cache lookup — prefix matching is automatic. `prefix_hash`
      is still returned in responses for clients that rely on it, but is no
      longer required to achieve cache reuse."

---

### 3.2 🟡 **P2** — `GenerationParameters.staticPrefix` is unused

**Where**: `Services/Inference/ModelService.swift` lines 28, 38, 47

**Problem**: `staticPrefix` used to feed `buildPrefixCache()` so the background
warm-up task knew which static content to precompute. With the new
`CacheCoordinator`, prefix caching is automatic on first use — no warm-up task
runs.

**Action items**:
- [ ] Leave the field in `GenerationParameters` for now (harmless, may find use).
- [ ] Remove `enriched.staticPrefix = prefix` write at `Networking/HTTPHandler.swift:1328`
      if we want to be thorough. (P3)

---

## 4. UI affordances that no longer match reality

### 4.1 🟠 **P1** — "Clear All" button has misleading scope

**Where**: `Views/Model/ModelCacheInspectorView.swift` (Clear All button calls
`MLXService.shared.clearRuntimeCache()`)

**Problem**: The button is labeled "Clear All" and lives in a view called
"Loaded Models". It currently:
- ✅ Unloads model containers (GPU memory)
- ✅ Disables cache coordinators on each container
- ❌ Does **NOT** clear the L2 disk cache (`~/Library/Caches/ai.osaurus/kv_v2/`)
- ❌ Does **NOT** clear MemoryContextAssembler
- ❌ Does **NOT** clear preflight cache
- ❌ Does **NOT** clear UI caches (ThreadCache, BlockMemoizer)

**User expectation**: Pressing "Clear All" in a "cache inspector" probably should
wipe everything related to caching.

**Decision**: Two sub-options:

**Option A — Rename the button to "Unload All Models"** (minimum change)
- Makes the scope honest.
- Clear All stays model-weight-only.

**Option B — Expand the button to truly clear everything** (better UX)
- Call `disableCaching()` on all containers (already happens via unload).
- Walk `~/Library/Caches/ai.osaurus/kv_v2/` and remove files.
- Call `MemoryContextAssembler.shared.invalidateAll()` (new method needed).
- Call `PluginHostContext.invalidateAllPreflightCaches()` (new method needed).
- Call `ThreadCache.shared.clear()`.
- Add a confirmation dialog ("This will unload all models and clear all caches.
  Continue?").

**Recommendation**: **Option B**. Also add a separate "Unload Models" button for
the narrower action.

**Action items**:
- [ ] Add `MemoryContextAssembler.invalidateAll()` method
- [ ] Add `PluginHostContext.invalidateAllPreflightCaches()` method (or iterate
      the existing per-session one)
- [ ] Add `OsaurusPaths.clearDiskKVCache()` helper that removes everything under
      the `kv_v2/` subdirectory
- [ ] Rewrite `ModelCacheInspectorView` Clear All handler to call all of the above
- [ ] Add confirmation dialog
- [ ] Rename the current button to reflect full scope or add a second button

---

### 4.2 🟠 **P1** — No visibility into L2 disk cache size

**Where**: `Views/Model/ModelCacheInspectorView.swift`

**Problem**: Users can configure a 4 GB disk cache cap but have no way to see
how much is currently used. For a feature we're turning on by default, this is
a UX gap.

**Fix**: Add a "Disk Cache" section to the inspector showing:
- Current size (summed file sizes under `~/Library/Caches/ai.osaurus/kv_v2/`)
- Configured limit (from `ServerConfiguration.cacheDiskMaxGB`)
- Percentage bar
- "Clear Disk Cache" button (separate from "Clear All" above)

**Action items**:
- [ ] Add `OsaurusPaths.diskKVCacheUsageBytes()` helper
- [ ] Add a disk cache info row to `ModelCacheInspectorView`
- [ ] Wire the "Clear Disk Cache" button to `OsaurusPaths.clearDiskKVCache()`

---

### 4.3 🟡 **P2** — Settings UI doesn't reflect "TurboQuant (Auto-Enabled)" state clearly

**Where**: `Views/Settings/ConfigurationView.swift` lines 465-473

**Problem**: The TurboQuant toggle has a badge that says "(Auto-Enabled)" or
"(Auto-Disabled)" when the user hasn't set it explicitly. But the auto-detection
logic lives in TWO places and may drift:
1. `RuntimeConfig.autoTurboQuant()` — actual runtime decision
2. `ConfigurationView.turboQuantAutoEnabled` — UI estimate

**Fix**: Centralize the auto-detection check. Make `RuntimeConfig.autoTurboQuant()`
accept a `modelWeightsBytes` parameter that defaults to `0` (for UI preview) or
a real value (for runtime), and have the UI call the same function.

**Action items**:
- [ ] Refactor `ConfigurationView.turboQuantAutoEnabled` to call the same helper
      as `RuntimeConfig`
- [ ] Verify the UI matches runtime behavior with the actual loaded model weights

---

## 5. Orphaned / dead helper code

### 5.1 🟡 **P2** — `computePrefixHash` is kept but caches nothing

**Where**: `Services/ModelRuntime.swift` lines 460-470 (migrated to `feat/vmlx-cache-migration`)

**Current state**: The function still computes SHA-256 of system content + sorted
tool names. It's called from:
- `Networking/HTTPHandler.swift:2478` — to populate `prefix_hash` in streaming response
- `Networking/HTTPHandler.swift:2631` — to populate `prefix_hash` in non-streaming response
- Tests in `Tests/Memory/PrefixHashTests.swift`

**Why it's kept**: API contract — clients may store and resend `prefix_hash` as
`cache_hint`. The new CacheCoordinator ignores `cache_hint` internally, but the
API response field is still returned so clients that depend on it don't break.

**Action items**: **No action needed.** Flag for awareness. Consider removing in
a future major version bump once API consumers migrate.

---

### 5.2 🟡 **P2** — Import of `CryptoKit` in `ModelRuntime.swift`

**Where**: `Services/ModelRuntime.swift` line 10 (on our branch)

**Reason**: Still needed for `computePrefixHash`. Keep.

**Action items**: None.

---

### 5.3 🟡 **P2** — `GenerationParameters.staticPrefix` and `cacheHint` fields

**Where**: `Services/Inference/ModelService.swift` lines 23-28

**Current state**: These fields are still set by callers:
- `HTTPHandler.swift:1326-1328` — sets `cacheHint` and `staticPrefix` from preflight
- `PluginHostAPI.swift:498, 550` — sets `cacheHint` on enriched requests
- `ChatEngine.swift:56-57, 269-270` — forwards these fields

But `MLXGenerationEngine.prepareAndGenerate()` no longer reads them. The
CacheCoordinator inside `TokenIterator` does its own token-content hashing.

**Decision**: Keep the plumbing for API backwards compat. Remove the dead reads
in a future cleanup pass once confirmed nothing external relies on them being
observable.

**Action items**:
- [ ] Leave as-is.
- [ ] Optional (P3): Remove the `staticPrefix` field in a follow-up cleanup PR.

---

## 6. Default tuning / auto-detection improvements

The user explicitly requested that caching be turned on by default with sensible
tuning so a benchmark user gets good behavior out of the box.

### 6.1 🟠 **P1** — Verify defaults are correct for low-RAM machines

**Where**: `Services/ModelRuntime.swift` `loadContainer()` cache config block
(lines ~228-252 on our branch)

**Current defaults**:
```swift
cacheConfig.enableDiskCache = serverCfg?.cacheDiskEnabled ?? true  // on
cacheConfig.diskCacheMaxGB = serverCfg?.cacheDiskMaxGB ?? 4.0       // 4 GB
cacheConfig.maxCacheBlocks = ramGB >= 48 ? 2000 : 1000              // 64-128k tokens
```

**Concern**: On a 16 GB Mac with a 7 GB model:
- L1 paged cache @ 1000 blocks × 64 tokens × ~40 MB/block (Gemma-level) ≈ 40 GB
  → **way** too much for in-memory
- Actually, block bytes depends on model layer count, heads, dim, dtype.
  A Qwen2-7B fp16 cache block is more like 2-5 MB, so 1000 blocks = 2-5 GB.
- TurboQuant is auto-enabled at <16 GB headroom, which cuts this by ~5x.

**Verify**:
- [ ] Actually measure cache block size for a few representative models
- [ ] Ensure `maxCacheBlocks = 1000` on a 16 GB machine doesn't OOM
- [ ] Consider scaling `maxCacheBlocks` by a tighter RAM tier:
  ```swift
  let maxBlocks: Int
  switch ramGB {
  case 0..<16:  maxBlocks = 400    // ~25k tokens
  case 16..<32: maxBlocks = 800    // ~50k tokens
  case 32..<48: maxBlocks = 1500   // ~96k tokens
  case 48..<96: maxBlocks = 2500   // ~160k tokens
  default:      maxBlocks = 4000   // ~256k tokens
  }
  ```
- [ ] Benchmark: load a 7B model on a 16 GB machine, run 5 turns, verify no OOM

**Action items**:
- [ ] Measure block sizes
- [ ] Adjust `maxCacheBlocks` default ladder in `loadContainer()`
- [ ] Add a release note: "KV cache auto-tunes to your Mac. On 16 GB Macs we
      cap L1 at 400 blocks (~25k tokens) + 4 GB disk."

---

### 6.2 🟠 **P1** — Confirm TurboQuant default behavior

**Where**: `Services/ModelRuntime/RuntimeConfig.swift` lines 32-37, 60-66

**Current**:
```swift
// Auto-enable TurboQuant when headroom < 16 GB
private static func autoTurboQuant(modelWeightsBytes: Int64) -> Bool {
    guard modelWeightsBytes > 0 else { return false }
    let headroom = systemRAM - modelWeightsBytes
    return headroom < 16 * 1024 * 1024 * 1024
}
```

**User request**: TurboQuant should be default-on for all users as part of the
optimized default experience.

**Current gap**: It only activates when headroom is tight. A 64 GB user gets
no TurboQuant benefit by default even though the compression is essentially free
(4.7–5× KV memory savings → bigger context windows).

**Decision**:
- **Option A** — keep the headroom trigger (conservative)
- **Option B** — default TurboQuant ON for all users, let advanced users disable

**User explicitly asked for Option B**. Change:

```swift
private static func autoTurboQuant(modelWeightsBytes: Int64) -> Bool {
    // Default ON for all users — TurboQuant compression is essentially free
    // and enables longer context windows. Advanced users can disable via settings.
    return true
}
```

**Action items**:
- [ ] Change `autoTurboQuant()` to return `true` unconditionally
- [ ] Update the doc comment
- [ ] Update the UI badge to say "(Auto-Enabled)" always when nil (simplifies UI logic)
- [ ] Verify TurboQuant on a non-hybrid model at 2k+ tokens doesn't degrade quality
      meaningfully (vmlx docs claim no regression but verify)

---

### 6.3 🟠 **P1** — Disk cache default enabled

**Status**: Already true — `cacheDiskEnabled ?? true` in `loadContainer()`.

**Verify**:
- [ ] First-launch behavior: with no `ServerConfiguration.json`, default is `nil`,
      which evaluates to `true`. ✅
- [ ] The `~/Library/Caches/ai.osaurus/kv_v2/` directory is created if missing.
      `OsaurusPaths.ensureExistsSilent(diskCacheDir)` is called. ✅

**Action items**: None.

---

### 6.4 🟡 **P2** — `defaultMaxKV` and `defaultPrefillStep` tiers haven't been re-validated

**Where**: `Services/ModelRuntime/RuntimeConfig.swift` lines 70-90

**Current**:
```swift
// maxKV
case 0 ..< 24: return 8192
case 24 ..< 48: return 16384
case 48 ..< 96: return 32768
default: return 65536

// prefillStep
case 0 ..< 24: return 1024
case 24 ..< 64: return 2048
default: return 4096
```

**Concern**: These were tuned for the old single-layer KV cache. With TurboQuant
default-on and the paged cache's own bounds, larger `maxKV` is now safer.

**Action items**:
- [ ] Benchmark: check whether `maxKV = 16384` on a 16 GB Mac is stable with
      TurboQuant + disk cache enabled
- [ ] Consider raising the lowest tier to 16k tokens (2× current)

---

## 7. Settings UI gaps

### 7.1 🟠 **P1** — Wire the 3 new cache settings to actual config loading

**Where**: `Views/Settings/ConfigurationView.swift`

**Current state on our branch**:
- `tempDiskCacheEnabled`, `tempDiskCacheMaxGB`, `tempCacheMaxBlocks` state vars exist
- UI controls exist in `SettingsSubsection(label: "Cache Storage")`
- `loadConfiguration()` reads them from `ServerConfiguration`
- Save writes them back

**Verify**:
- [ ] Open Settings → Local Inference → Cache Storage subsection appears
- [ ] Toggling "Disk Cache" off and saving persists `cacheDiskEnabled = false` to JSON
- [ ] Setting "Disk Cache Limit (GB)" to `8` persists `cacheDiskMaxGB = 8.0`
- [ ] Setting "Memory Cache Blocks" to `500` persists `cacheMaxBlocks = 500`
- [ ] Restarting the app applies the new values to loaded models

**Action items**:
- [ ] Manual QA once the branch builds
- [ ] Consider adding an "Apply without restart" button that calls
      `disableCaching()` + `enableCaching()` on currently-loaded containers

---

### 7.2 🟡 **P2** — Missing "Reset to defaults" button

**Where**: `Views/Settings/ConfigurationView.swift` Cache Storage subsection

**Problem**: Power users may set custom values, can't remember how to get back
to auto-detect defaults.

**Fix**: Add a small "Reset" button that clears all 3 fields (setting them to
empty strings for stepper fields and `true` for the toggle).

**Action items**:
- [ ] Add a Reset button next to the Cache Storage advanced section

---

### 7.3 🟡 **P2** — No indicator that cache settings require model reload

**Where**: `Views/Settings/ConfigurationView.swift` Cache Storage subsection

**Problem**: The Cache Storage settings only take effect on the **next**
`enableCaching()` call, which happens on model load. If a user changes settings
while a model is loaded, they need to unload/reload for the change to apply.

**Fix**:
- [ ] Add an info tooltip or footer text: "Changes take effect on next model load."
- [ ] Or: detect that the current model is loaded and show a "Reload Model"
      button when settings change.

---

## 8. New cache-management UI

### 8.1 🟠 **P1** — Add disk cache size + clear UI (see §4.2)

Duplicate of 4.2 above. Consolidate action items here.

---

### 8.2 🟢 **P3** — Show cache hit rate metric

**Idea**: Expose a counter from `CacheCoordinator` (if it tracks hits/misses) and
display "Cache hits: 73%" in the Model Cache Inspector.

**Status**: Requires vmlx-swift-lm to expose stats. Skip unless the package adds it.

---

## 9. Docs / API guide updates

### 9.1 🟠 **P1** — Update `docs/OpenAI_API_GUIDE.md`

**Sections needing updates**:
- Lines 244-266 ("Session Reuse"): Explain `session_id` is preserved for
  compatibility but no longer affects cache lookup.
- Lines 268-293 ("Prefix Caching"): Explain `cache_hint` / `prefix_hash` are
  preserved for compatibility but prefix matching is now automatic and
  content-addressed.
- Add a new section: "Automatic KV cache (new)" explaining that the server now
  does paged prefix caching + disk persistence automatically.

**Action items**:
- [ ] Rewrite the two sections
- [ ] Add the new automatic cache explanation
- [ ] Note the directories users can inspect (`~/Library/Caches/ai.osaurus/kv_v2/`)

---

### 9.2 🟡 **P2** — Add a release note / changelog entry

**Where**: CHANGELOG or release notes (need to find where osaurus tracks these)

**Content**:
```
### KV Cache Migration

- Replaced osaurus's custom KV cache layer with vmlx-swift-lm's
  multi-tier CacheCoordinator:
  - L1: In-memory paged cache (64-token blocks, SHA-256 chain hashing)
  - L2: SQLite-indexed disk cache (default 4 GB, persists across restarts)
  - Hybrid model support: SSM companion cache for Qwen3.5, Nemotron-H, etc.
  - TurboQuant: 4.7-5× KV memory compression (now enabled by default)
- Fixes crash on M1/M2 Macs running macOS 26 when loading JANG models
  (compile(shapeless: true) Metal JIT crash — fixed upstream in vmlx-swift-lm)
- Fixes Gemma 4 JANG parameter shape mismatch errors
- New Settings → Local Inference → Cache Storage section with toggle
  for disk cache and advanced controls for block count / size limit
- `session_id` and `cache_hint` API fields preserved for compatibility
  but cache behavior is now automatic
```

**Action items**:
- [ ] Find the CHANGELOG location
- [ ] Add the release note

---

## 10. Test updates

### 10.1 🟡 **P2** — Existing `PrefixHashTests.swift` tests are still valid

**Where**: `Tests/Memory/PrefixHashTests.swift`

**Status**: Tests the API-level `computePrefixHash` helper, which we kept. Tests
should still pass.

**Action items**:
- [ ] Run `swift test` once the branch builds
- [ ] Verify 10 prefix hash tests pass

---

### 10.2 🟠 **P1** — Missing tests for cache-settings-to-coordinator wiring

**New tests needed**:

1. **`ServerConfiguration` round-trip with new fields**
   - Encode a `ServerConfiguration` with `cacheDiskEnabled = false`,
     `cacheDiskMaxGB = 8.0`, `cacheMaxBlocks = 500`
   - Decode it back, verify all three fields match

2. **`loadConfiguration()` / `saveConfiguration()` in ConfigurationView**
   - Hard to unit-test a SwiftUI view; skip unless there's a testable model class

3. **`ModelRuntime.loadContainer()` enables caching with config**
   - Mock ServerConfiguration with `cacheDiskEnabled = false`
   - Load a model
   - Assert `holder.container.cacheCoordinator?.config.enableDiskCache == false`

**Action items**:
- [ ] Add a test file `Tests/Configuration/ServerConfigurationCacheFieldsTests.swift`
- [ ] Write the round-trip test (easy)
- [ ] Skip the loadContainer test unless there's an existing mock infrastructure

---

### 10.3 🟡 **P2** — Manual build verification

**Action items**:
- [ ] `cd /Users/eric/osaurus && swift build 2>&1 | tee build.log`
  — may fail due to Tokenizers 0.1.21 API differences
- [ ] If it fails: note which symbols broke, decide between:
      (a) Adapting osaurus's `SwiftTransformersTokenizerLoader.swift` to the
          0.1.21 API
      (b) Asking for vmlx-swift-lm to drop its unused swift-transformers dep
- [ ] Open the Xcode workspace, let it resolve packages, build the osaurus target

---

## 11. Full file-by-file action list

### Files to EDIT

| Priority | File | Change |
|----------|------|--------|
| 🔴 P0 | `Packages/OsaurusCore/Package.swift` | (Done, uncommitted) swift-transformers `0.1.21` |
| 🟠 P1 | `Packages/OsaurusCore/Services/ModelRuntime.swift` | Add doc comment to `invalidateSession` no-op; optionally adjust `maxCacheBlocks` tiers |
| 🟠 P1 | `Packages/OsaurusCore/Services/ModelRuntime/RuntimeConfig.swift` | `autoTurboQuant` → unconditional `true`; update `defaultMaxKV` and `defaultPrefillStep` tiers if benchmarks show headroom |
| 🟠 P1 | `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift` | Add `MemoryContextAssembler.shared.invalidateCache(agentId:)` call in `closeWindow()` |
| 🟠 P1 | `Packages/OsaurusCore/Views/Model/ModelCacheInspectorView.swift` | Rewrite "Clear All" button: expand scope, add confirmation dialog, add "Disk Cache" info row |
| 🟠 P1 | `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift` | Verify Cache Storage subsection works end-to-end; optional Reset button |
| 🟠 P1 | `docs/OpenAI_API_GUIDE.md` | Rewrite Session Reuse + Prefix Caching sections |
| 🟡 P2 | `Packages/OsaurusCore/Services/Memory/MemoryContextAssembler.swift` | Add `invalidateAll()` public method |
| 🟡 P2 | `Packages/OsaurusCore/Services/Plugin/PluginHostContext.swift` | Add `invalidateAllPreflightCaches()` public method |
| 🟡 P2 | `Packages/OsaurusCore/Utilities/OsaurusPaths.swift` | Add `clearDiskKVCache()` and `diskKVCacheUsageBytes()` helpers |
| 🟡 P2 | `Packages/OsaurusCore/Networking/HTTPHandler.swift:1328` | Optional: remove dead `enriched.staticPrefix = prefix` write |
| 🟡 P2 | CHANGELOG | Add release note |

### Files to CREATE

| File | Purpose |
|------|---------|
| `Tests/Configuration/ServerConfigurationCacheFieldsTests.swift` | Round-trip test for new cache fields |

### Files to LEAVE ALONE (flagged in audit, no action needed)

| File | Why |
|------|-----|
| `Services/Inference/ModelService.swift` | `cacheHint`/`staticPrefix` kept for API compat |
| `Services/Plugin/PluginHostAPI.swift` (preflight cache) | Orthogonal prompt cache, still valid |
| `Services/Chat/SystemPromptComposer.swift` / `PromptManifest.swift` | Prompt assembly, orthogonal |
| `Services/Chat/ContextBudgetManager.swift` | Token budget management, orthogonal |
| `Managers/ThreadCache.swift` / `BlockMemoizer.swift` / `Views/Chat/ChatImageCache.swift` | Pure UI caches, correctly scoped |
| `Managers/Model/ModelPickerItemCache.swift` | UI state |
| `Services/ModelRuntime/MetalGate.swift` | GPU serialization, not a cache |
| `Tests/Memory/PrefixHashTests.swift` | Still valid |
| `Tests/Model/ModelRuntimePrefixTests.swift` | Still valid (was simplified in initial migration) |

### Files ALREADY REMOVED on `feat/vmlx-cache-migration`

| File | Size | Why |
|------|------|-----|
| `Services/ModelRuntime/KVCacheStore.swift` | 495 lines | Replaced by CacheCoordinator |
| `Tests/Service/KVCacheStoreTests.swift` | ~570 lines | Tested deleted code |
| `Tests/Model/MLXGenerationEngineTests.swift` | ~80 lines | `effectiveCacheOffset()` tests for deleted function |
| `App/osaurus.xcodeproj/.../Package.resolved` | 411 lines | Stale dependency resolution |
| `osaurus.xcworkspace/.../Package.resolved` | 420 lines | Stale dependency resolution |

---

## Summary by severity

### 🔴 P0 (must-fix before merge)
1. **§1.1** `swift-transformers 0.1.21` — done, needs commit + compile verification

### 🟠 P1 (should-fix before wide release)
1. **§2.1** Document `invalidateSession` no-op behavior
2. **§3.1** Update API docs to explain `session_id`/`cache_hint` are compat-only
3. **§4.1** Expand "Clear All" button scope OR rename it
4. **§4.2** Add disk cache size visibility + clear button
5. **§6.1** Verify default `maxCacheBlocks` tiers don't OOM on 16 GB Macs
6. **§6.2** Change `autoTurboQuant()` to default-on for all users
7. **§7.1** Manual QA of Cache Storage settings round-trip
8. **§9.1** Update `docs/OpenAI_API_GUIDE.md`
9. **§10.2** Add round-trip test for new cache fields

### 🟡 P2 (nice-to-have cleanup)
- §1.2 Regenerate Package.resolved
- §2.2 Invalidate MemoryContextAssembler on session close
- §2.3 (No action, flagged for awareness)
- §3.2 Remove dead `staticPrefix` writes
- §4.3 Centralize TurboQuant auto-detection helper
- §5.1/5.2/5.3 (No action, flagged for awareness)
- §6.4 Re-validate `defaultMaxKV`/`defaultPrefillStep` tiers
- §7.2 Add "Reset to defaults" button
- §7.3 Add "Changes take effect on next model load" tooltip
- §9.2 Add CHANGELOG entry
- §10.1 Run existing tests
- §10.3 Manual Xcode build verification

### 🟢 P3 (optional)
- §8.2 Cache hit rate metric

---

## Recommended execution order

1. **Verify the branch builds** against Tokenizers 0.1.21. If it doesn't, decide
   the remediation path before any other work.
2. **Commit the swift-transformers fix** (§1.1).
3. **Apply §6.2** (`autoTurboQuant = true`) — single-line change, big UX win.
4. **Apply §2.1** doc comment and §2.2 `MemoryContextAssembler` invalidation —
   both small, low-risk.
5. **Rewrite §4.1/4.2** ModelCacheInspectorView — biggest UI change, requires
   new helper methods.
6. **Manual QA** — walk through Settings, load a model, run turns, close windows,
   verify RAM behavior matches expectations.
7. **Update §9.1** OpenAI_API_GUIDE.md.
8. **Add tests** (§10.2).
9. **Benchmark** on a 16 GB Mac (§6.1) and adjust defaults if needed.
10. **Add CHANGELOG entry** (§9.2).
11. **Push branch** and open PR.
