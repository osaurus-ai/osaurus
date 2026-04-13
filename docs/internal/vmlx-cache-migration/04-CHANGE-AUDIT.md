# VMLX Cache Integration — Change Audit Log

> Running log of every change made in the second-pass integration work.
> Each entry has: what changed, why, before/after, and blast radius.
> Use this to review granularly and approve one change at a time.
>
> **Format**: Entries are appended top-to-bottom as changes land.
> **Branch**: `feat/vmlx-cache-migration`

---

## Format key

- **Change ID**: Incrementing number `C-001`, `C-002`, ...
- **File**: Absolute path (relative to repo root) of the file touched
- **Kind**: `add` (new symbol/block) / `edit` (modify existing) / `remove` (delete)
- **Severity**: P0 (must-fix), P1 (should-fix), P2 (nice-to-have)
- **Depends on**: Previous change IDs this builds on
- **Doc ref**: Section in GAPS or CONSIDERATIONS doc
- **Audit focus**: What the reviewer should verify

---

## Entries

<!-- Changes will be appended below this line -->

> ## ⚠️ Scope change — round 3 (2026-04-13)
>
> After C-001…C-013 landed, the direction shifted: osaurus should have
> **zero** user-visible cache configuration. Caching is the
> vmlx-swift-lm package's concern. osaurus uses hardcoded internal
> defaults and doesn't expose cache knobs in Settings or the model
> inspector.
>
> The user also asked for memory and tools to be **off by default**,
> with in-chat and in-Settings toggles to enable them.
>
> Read the C-R## revert entries and C-014..C-018 net-new entries
> **below** the C-013 entry in this file (they were appended last).
> The C-001..C-013 entries are kept unchanged for history but most
> of their user-facing surface is reverted by C-R01..C-R06.

---

### C-001 — Add `cacheEnabled` master toggle to `ServerConfiguration`

- **File**: `Packages/OsaurusCore/Models/Configuration/ServerConfiguration.swift`
- **Kind**: `add` (new `Bool?` field + CodingKey + decoder + init)
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `VMLX-CACHE-INTEGRATION-CONSIDERATIONS.md` §O.1
- **Why**: User asked for "enabled by default" but a way for power users / debuggers
  to disable the whole KV cache system with one switch. This is the top-level
  on/off that gates the entire `CacheCoordinator` path.

**Before** (lines 64-70):
```swift
// MARK: - Cache Tier Settings
/// Enable L2 disk cache for KV state persistence across app restarts; nil = true (default on)
public var cacheDiskEnabled: Bool?
/// Maximum disk cache size in GB; nil = 4.0
public var cacheDiskMaxGB: Float?
/// Maximum number of paged cache blocks in L1 memory; nil = auto-detect based on RAM
public var cacheMaxBlocks: Int?
```

**After** (lines 64-74):
```swift
// MARK: - Cache Tier Settings
/// Master toggle for KV caching (paged L1 + disk L2 + SSM companion + TurboQuant).
/// nil = true (default on). When false, models load without any cache coordinator
/// and every request runs a full prefill.
public var cacheEnabled: Bool?
/// Enable L2 disk cache for KV state persistence across app restarts; nil = true (default on)
public var cacheDiskEnabled: Bool?
/// Maximum disk cache size in GB; nil = 4.0
public var cacheDiskMaxGB: Float?
/// Maximum number of paged cache blocks in L1 memory; nil = auto-detect based on RAM
public var cacheMaxBlocks: Int?
```

Also added to `CodingKeys`, `init(from decoder:)`, and primary `init(...)`.

**Default behavior**: `nil` is treated as `true` by `loadContainer` (see C-006).
This means existing users without the field in their JSON get full caching
automatically. No migration needed.

**Blast radius**:
- Decode path: unchanged behavior for existing JSON (field missing → `nil`).
- Encode path: `nil` fields are omitted by default `JSONEncoder`, so round-trip
  is clean.
- `ServerConfiguration.default` still works (all-nil fields).
- Any consumer that iterates `CodingKeys` (rare) picks up the new case.

**Audit focus**:
- Verify the new field is optional (`Bool?`) so existing `ServerConfiguration.json`
  files deserialize without error.
- Verify nothing checks `cacheEnabled ?? false` (all reads should default to `true`).
- Verify the public memberwise `init(...)` new argument has a default value (`nil`)
  so existing call sites don't break.

---

### C-002 — Make `autoTurboQuant()` unconditionally return `true`

- **File**: `Packages/OsaurusCore/Services/ModelRuntime/RuntimeConfig.swift`
- **Kind**: `edit` (change body of existing private static)
- **Severity**: P1
- **Depends on**: None
- **Doc ref**: `VMLX-CACHE-INTEGRATION-GAPS.md` §6.2, `VMLX-CACHE-INTEGRATION-CONSIDERATIONS.md` F.3/O.2
- **Why**: User asked for TurboQuant to be default-on for all users. Previously
  auto-enabled only when headroom < 16 GB. TurboQuant compression (4.7–5×) is
  essentially free per vmlx-swift-lm docs and enables longer context windows.
  Explicit `genTurboQuant = false` from the user still wins.

**Before** (lines 59-66):
```swift
/// Auto-enable TurboQuant when the headroom after model weights is less
/// than 16 GB. Uses the same threshold as autoKVBits.
private static func autoTurboQuant(modelWeightsBytes: Int64) -> Bool {
    guard modelWeightsBytes > 0 else { return false }
    let systemRAM = Int64(ProcessInfo.processInfo.physicalMemory)
    let headroom = systemRAM - modelWeightsBytes
    return headroom < 16 * 1024 * 1024 * 1024
}
```

**After** (lines 59-68):
```swift
/// TurboQuant is enabled by default for all users as of the vmlx-swift-lm
/// migration. Compression is essentially free (no meaningful quality regression
/// on standard benchmarks) and enables longer context windows on all hardware.
/// Users can disable it explicitly via `genTurboQuant = false` in
/// ServerConfiguration / Settings → Local Inference → TurboQuant.
///
/// `modelWeightsBytes` is accepted for signature compatibility with
/// `autoKVBits` and for future heuristics (e.g., blocklist per model size).
private static func autoTurboQuant(modelWeightsBytes: Int64) -> Bool {
    return true
}
```

**Preserved**:
- The parameter is kept (not removed) so call sites don't break and we have a
  future extension point if certain model sizes need opt-out.
- The explicit-user-override path in `snapshot(...)` (lines 32-37) is untouched:
  ```swift
  if let explicit = cfg?.genTurboQuant {
      effectiveTurboQuant = explicit           // user wins
  } else {
      effectiveTurboQuant = Self.autoTurboQuant(modelWeightsBytes: ...)  // now always true
  }
  ```

**Interaction with `autoKVBits`** (NOT CHANGED, but worth flagging):
- `autoKVBits()` still auto-enables 8-bit KV quantization when headroom < 16 GB.
- With TurboQuant default-on, a user on low-headroom hardware could end up with
  BOTH `kvBits = 8` and `kvMode = .turboQuant(keyBits: 3, valueBits: 3)` set.
- `makeGenerateParameters` in `ModelRuntime` passes both fields to
  `MLXLMCommon.GenerateParameters`. The vmlx package decides precedence.
- **This is unchanged from the previous auto-behavior** — when headroom was <16GB
  both auto-paths already fired together. Migration preserves this.
- **Audit note**: If the vmlx package can't handle both set simultaneously,
  we'll need to add an explicit "TurboQuant wins over kvBits" rule in
  `snapshot(...)`. Flag for integration testing.

**Blast radius**:
- Every new `RuntimeConfig.snapshot()` call returns `turboQuant: true` unless
  the user explicitly set `genTurboQuant = false`.
- Users who previously had `genTurboQuant = nil` in their JSON (the default)
  will now get TurboQuant on their next generation.
- Users with `genTurboQuant = true` saved explicitly: no change.
- Users with `genTurboQuant = false` saved explicitly: no change (override wins).

**Audit focus**:
- Confirm no regressions in text quality on standard models (manual smoke test
  at minimum: Gemma, Qwen, Llama variants).
- Confirm the UI's "Auto-Enabled" / "Auto-Disabled" badge no longer shows
  "(Auto-Disabled)" — logic in `ConfigurationView.turboQuantAutoEnabled` must
  be updated to match (tracked as C-003).
- Verify the `modelWeightsBytes` parameter is truly unused and the unused-parameter
  warning doesn't flip to an error (Swift's `@_ignored` / `_` might be needed).

---

### C-003 — Update `ConfigurationView.turboQuantAutoEnabled` to mirror C-002

- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `edit` (simplify computed property + update TurboQuant SettingsToggle)
- **Severity**: P1
- **Depends on**: C-002
- **Doc ref**: `VMLX-CACHE-INTEGRATION-CONSIDERATIONS.md` F.3/O.2
- **Why**: The UI had its own copy of the headroom<16GB heuristic to estimate
  whether TurboQuant would be auto-enabled. After C-002 makes the runtime
  unconditionally `true`, the UI must reflect the same. The badge text and
  description strings are also updated so users understand the new default.

**Two edits** in one change:

**1. `SettingsToggle` badge and description** (lines ~470-477):

**Before**:
```swift
SettingsToggle(
    title: "TurboQuant",
    description:
        "KV cache compression for ~5x memory savings. Auto-detected based on available RAM.",
    badge: tempTurboQuant == nil
        ? (turboQuantAutoEnabled ? "(Auto-Enabled)" : "(Auto-Disabled)")
        : nil,
    isOn: turboQuantBinding
)
```

**After**:
```swift
SettingsToggle(
    title: "TurboQuant",
    description:
        "KV cache compression for ~5x memory savings. Enabled by default on all hardware.",
    badge: tempTurboQuant == nil ? "(Default)" : nil,
    isOn: turboQuantBinding
)
```

**2. `turboQuantAutoEnabled` computed property** (lines ~764-773):

**Before**:
```swift
// MARK: - TurboQuant Helpers

/// Rough estimate of whether auto-detection would enable TurboQuant.
/// Uses the same headroom < 16 GB heuristic as RuntimeConfig but without
/// model weights (assumes ~8 GB model as a conservative estimate).
private var turboQuantAutoEnabled: Bool {
    let systemRAM = Int64(ProcessInfo.processInfo.physicalMemory)
    let estimatedHeadroom = systemRAM - 8 * 1024 * 1024 * 1024
    return estimatedHeadroom < 16 * 1024 * 1024 * 1024
}
```

**After**:
```swift
// MARK: - TurboQuant Helpers

/// TurboQuant is enabled by default for all users (mirrors
/// `RuntimeConfig.autoTurboQuant()`). The UI binding reflects this so an
/// unset user preference shows the toggle as on.
private var turboQuantAutoEnabled: Bool { true }
```

**Preserved**:
- `turboQuantBinding` still uses `tempTurboQuant ?? turboQuantAutoEnabled`, so
  the toggle initially displays "on" when the user hasn't set a preference.
- Explicit user preference (`tempTurboQuant = true/false`) still wins.

**Blast radius**: UI only. The runtime already enforces default-on after C-002.
This change just ensures the UI display is consistent.

**Audit focus**:
- Open Settings → Local Inference → KV Cache — the TurboQuant toggle should
  show as "on" with "(Default)" badge on a fresh install.
- Toggle off, save, reopen: should show as "off" with no badge.
- Delete `ServerConfiguration.json`, relaunch, reopen Settings: toggle "on" + "(Default)".

---

### C-004 — Factor cache-coordinator install into reusable helpers

- **File**: `Packages/OsaurusCore/Services/ModelRuntime.swift`
- **Kind**: `add` (3 new private methods) + `edit` (simplify `loadContainer` block)
- **Severity**: P1
- **Depends on**: C-001 (uses `cacheEnabled` field), C-002 (TurboQuant default is unchanged here but audit notes the relationship)
- **Doc ref**: CONSIDERATIONS §A.1 / §C.5 / §C.6 / §E.1 / §O.1
- **Why**: Three concerns solved together because they touch the same block of
  `loadContainer`:
  1. The cache-config construction block was inlined in `loadContainer` (~30
     lines). It needs to be called from at least two places (`loadContainer`
     and the upcoming `refreshCacheConfig` method — C-005).
  2. The `cacheEnabled` master toggle (C-001) needs a gate somewhere.
  3. The disk cache dir was used without any writability check; if the dir
     can't be written the coordinator silently degrades on first use (E.1).

**New helpers added** (before the `// MARK: - Generation driver` section):

1. **`nonisolated static buildCacheCoordinatorConfig(modelName:serverCfg:)`**:
   returns a fully-populated `CacheCoordinatorConfig?`. Returns `nil` iff
   `cacheEnabled` master toggle is false. Reads writability probe result to
   force `enableDiskCache = false` when the disk path is broken.

2. **`nonisolated static isDirectoryWritable(_ url:)`**:
   write-probe helper. Writes an empty file with a random UUID suffix and
   deletes it. Catches symlinks, permissions, out-of-disk conditions that
   `FileManager.isWritableFile(atPath:)` would miss.

3. **`installCacheCoordinator(on:serverCfg:)`** (instance method, actor-isolated):
   - Calls `buildCacheCoordinatorConfig`.
   - If master toggle is off → `disableCaching()` on the container (cleans up
     any previous coordinator).
   - Else → `enableCaching(config:)` followed by `setHybrid(isHybrid)` via
     auto-detection.
   - Emits a single structured `genLog.info(...)` line summarizing the state
     for easier post-hoc debugging.

**`loadContainer` edit** (before → after):

**Before** (~35 lines inline):
```swift
// Enable multi-tier KV caching via vmlx-swift-lm's CacheCoordinator.
// Settings are read from ServerConfiguration with sensible defaults.
let serverCfg = await ServerConfigurationStore.load()

let diskCacheDir = OsaurusPaths.cache()
    .appendingPathComponent("kv_v2", isDirectory: true)
OsaurusPaths.ensureExistsSilent(diskCacheDir)

let diskEnabled = serverCfg?.cacheDiskEnabled ?? true
let diskMaxGB = serverCfg?.cacheDiskMaxGB ?? 4.0
let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
let defaultMaxBlocks = ramGB >= 48 ? 2000 : 1000
let maxBlocks = serverCfg?.cacheMaxBlocks ?? defaultMaxBlocks

var cacheConfig = CacheCoordinatorConfig()
cacheConfig.enableDiskCache = diskEnabled
cacheConfig.diskCacheDir = diskCacheDir
cacheConfig.diskCacheMaxGB = diskMaxGB
cacheConfig.modelKey = name
cacheConfig.maxCacheBlocks = maxBlocks

holder.container.enableCaching(config: cacheConfig)

// Auto-detect hybrid models (SSM layers) and set the flag.
let isHybrid = await holder.container.perform { ctx -> Bool in
    let testCache = ctx.model.newCache(parameters: nil)
    return testCache.contains { $0 is MambaCache || $0 is ArraysCache }
}
holder.container.cacheCoordinator?.setHybrid(isHybrid)

genLog.info(
    "loadContainer: loaded \(name, privacy: .public) isVLM=\(holder.isVLM, privacy: .public) isHybrid=\(isHybrid, privacy: .public) cacheEnabled=true"
)
```

**After** (3 lines):
```swift
let serverCfg = await ServerConfigurationStore.load()
await installCacheCoordinator(on: holder, serverCfg: serverCfg)

genLog.info(
    "loadContainer: loaded \(name, privacy: .public) isVLM=\(holder.isVLM, privacy: .public)"
)
```

**Preserved semantics** (verify during audit):
- L1 paged cache: still enabled via package default (`CacheCoordinatorConfig()`
  has `usePagedCache = true`).
- Disk cache: default on, disabled when master off OR user off OR dir unwritable.
- Disk cap: 4 GB default, user override honored.
- `maxCacheBlocks`: 2000 on ≥48 GB RAM, 1000 otherwise; user override honored.
- `modelKey`: set to the loaded model name.
- Hybrid detection: unchanged (runs after `enableCaching`, before any generation
  could race — still actor-isolated).

**Changed semantics**:
- **New**: `cacheEnabled = false` → no coordinator is installed. Every request
  does full prefill.
- **New**: disk dir unwritable → user's `cacheDiskEnabled = true` is overridden
  to `false` with a warning log. The user's setting is preserved in
  `ServerConfiguration.json` — only the in-memory `CacheCoordinatorConfig` is
  downgraded for this session.
- **New**: every log message gated on coordinator install is now a single
  line from `installCacheCoordinator` (easier to grep).

**Side-effects introduced**:
- Write-probe runs on every model load. A tempfile is created and deleted.
  Cost is microseconds. If the cache dir has weird permissions the probe
  throws and we log a warning.
- `installCacheCoordinator` calls `disableCaching()` on the container when
  master toggle is off. Safe: `disableCaching` is idempotent per vmlx-swift-lm.

**Blast radius**:
- `loadContainer` is the only caller right now — so behavior is unchanged when
  `cacheEnabled` is nil/true and the disk dir is healthy. That's the 99% case.
- The helpers are staged for C-005 (`refreshCacheConfig`) to reuse.

**Audit focus**:
- Verify `nonisolated static` is appropriate on both helper functions —
  they don't touch actor state.
- Verify `buildCacheCoordinatorConfig` returns `nil` when master is off,
  never a zero-valued config.
- Verify the writability probe's tempfile path is guaranteed unique
  (UUID suffix).
- Verify `installCacheCoordinator`'s `disableCaching` path on the master-off
  branch doesn't leak a stale coordinator from a previous `loadContainer`
  (shouldn't matter for fresh loads, critical for C-005 refresh).

---

### C-005 — Add `ModelRuntime.refreshCacheConfig()` for hot settings reload

- **File**: `Packages/OsaurusCore/Services/ModelRuntime.swift`
- **Kind**: `add` (new actor-isolated method)
- **Severity**: P0 (unblocks the biggest silent gap from CONSIDERATIONS §A.1)
- **Depends on**: C-001, C-004
- **Doc ref**: `VMLX-CACHE-INTEGRATION-CONSIDERATIONS.md` §A.1 / §C.3 / §C.6
- **Why**: Prior to this change, settings updates to gen* / cache* fields had
  no effect on loaded models. The `invalidateConfig()` method existed but was
  never called from anywhere (dead code). `restartServer()` only restarted NIO,
  not the MLX runtime. Users had to manually unload + reload models to see
  new settings take effect. This method closes that gap.

**New method** (inserted after `invalidateConfig()`):

```swift
func refreshCacheConfig() async {
    await cancelActiveGeneration()
    cachedConfig = nil

    let serverCfg = await ServerConfigurationStore.load()
    for (_, holder) in modelCache {
        holder.container.disableCaching()
        await installCacheCoordinator(on: holder, serverCfg: serverCfg)
    }
    genLog.info(
        "refreshCacheConfig: applied to \(self.modelCache.count, privacy: .public) loaded model(s)"
    )
}
```

**Key design points** (each flagged with reviewer-facing rationale):

1. **Cancel active generation first.**
   An in-flight `TokenIterator` holds a strong reference to the old
   `CacheCoordinator` (captured at init). If we called `disableCaching` while
   it was running, its post-gen `storeAfterGeneration` call would write to
   the dead coordinator — harmless but wasted work. By awaiting cancellation
   first, any orphan writes are avoided.

2. **Invalidate `cachedConfig` explicitly.**
   Separate from `invalidateConfig()` which still exists as a standalone API.
   We could call `invalidateConfig()` here but keeping it inline is clearer
   for reviewers tracing the flow.

3. **Fresh `ServerConfiguration` read per refresh.**
   Not cached. `ServerConfigurationStore.load()` hits the disk on every
   refresh — acceptable since this only runs on user settings changes, not
   per request.

4. **`disableCaching()` then `installCacheCoordinator()` per holder.**
   The install path internally decides whether to enable or not based on the
   master toggle. The explicit `disableCaching` call before `install` is
   defensive: if `install` goes the master-off path, `disableCaching` is
   redundant but idempotent; if `install` goes the master-on path,
   `disableCaching` ensures we don't leak the previous coordinator.

5. **Sequential iteration, not concurrent.**
   `for (_, holder) in modelCache { ... }` runs refresh per model one at a
   time. Each `installCacheCoordinator` awaits on `container.perform` for
   hybrid detection. Parallelism here would race on the actor's read of
   `modelCache`.

**Preserved**:
- `invalidateConfig()` API stays — callers that only want to reset the
  `cachedConfig` snapshot (e.g., tests) can still call it.
- `cancelActiveGeneration` already exists and is unchanged.

**Blast radius**:
- Added public (actor-internal) method. No existing call sites affected.
- Next change (C-007) will wire it to `ConfigurationView.saveConfiguration`.

**Audit focus**:
- Verify actor isolation — `refreshCacheConfig` is actor-isolated, all
  mutations happen inside the actor's suspension points.
- Verify `cancelActiveGeneration` actually waits for the task (line 86-88:
  `activeGenerationTask?.cancel(); _ = await activeGenerationTask?.value`).
- Confirm iterating `modelCache` while calling `disableCaching` / `install`
  doesn't mutate the dictionary concurrently. We don't mutate the dict
  inside the loop — safe.
- Confirm the log message uses the captured `self.modelCache.count` at the
  right time (after the loop).

---

### C-006 — Fix `ConfigurationView.resetToDefaults()` to include new cache fields

- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `add` (new state var) + `edit` (extend resetToDefaults body)
- **Severity**: P1
- **Depends on**: C-001
- **Doc ref**: CONSIDERATIONS §A.2
- **Why**: The Reset button didn't touch the four new cache fields
  (`cacheEnabled`, `cacheDiskEnabled`, `cacheDiskMaxGB`, `cacheMaxBlocks`) —
  a partial-reset UX bug. Also needed a new `tempCacheEnabled` state var for
  the upcoming master toggle UI.

**Edits**:

1. **Added state var** (line ~53):
```swift
@State private var tempTurboQuant: Bool? = nil
@State private var tempCacheEnabled: Bool = true        // NEW
@State private var tempDiskCacheEnabled: Bool = true
@State private var tempDiskCacheMaxGB: String = ""
@State private var tempCacheMaxBlocks: String = ""
```

2. **Extended `resetToDefaults()`** (lines ~874-884):
```swift
tempTurboQuant = nil
tempCacheEnabled = true          // NEW
tempDiskCacheEnabled = true      // (already there, confirmed)
tempDiskCacheMaxGB = ""          // NEW
tempCacheMaxBlocks = ""          // NEW
tempEvictionPolicy = serverDefaults.modelEvictionPolicy
```

3. **Extended `loadConfiguration()`** (line ~818):
```swift
tempCacheEnabled = configuration.cacheEnabled ?? true
tempDiskCacheEnabled = configuration.cacheDiskEnabled ?? true
```

4. **Extended `saveConfiguration()`** (line ~955):
```swift
configuration.cacheEnabled = tempCacheEnabled ? nil : false
configuration.cacheDiskEnabled = tempDiskCacheEnabled ? nil : false
```

**Persistence semantics** (critical):
- Toggle **on** → save as `nil` → load defaults to `true`. Config file stays
  clean (unset field not written).
- Toggle **off** → save as `false` → load respects `false`. Config file has
  explicit false.
- Fresh install / deleted config → nil → treated as true. Default-on works.

**Blast radius**:
- `ConfigurationView` state only. No runtime effect.
- `resetToDefaults()` was also missing `tempAllowedOrigins = ""` historically
  (pre-existing; not introduced here — flagged for later cleanup).

**Audit focus**:
- Verify every `Cache Storage` field appears in reset.
- Verify the nil/false round-trip doesn't cause flapping between sessions.

---

### C-007 — Add master "KV Caching" toggle UI + gray out sub-settings

- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `add` (new SettingsToggle block) + `edit` (existing Cache Storage subsection)
- **Severity**: P1
- **Depends on**: C-001, C-006
- **Doc ref**: CONSIDERATIONS §O.1
- **Why**: User asked for "all enabled by default, but one master off-switch".
  Adds a top-level toggle bound to `tempCacheEnabled`. Sub-settings
  (Disk Cache, advanced sliders) are `.disabled()` and `.opacity(0.5)` when
  master is off — visual cue that they have no effect.

**New UI** (lines ~521-562):
```swift
SettingsSubsection(label: "Cache Storage") {
    VStack(alignment: .leading, spacing: 12) {
        SettingsToggle(
            title: "KV Caching",
            description:
                "Master switch for all KV cache tiers (memory, disk, hybrid SSM). Enabled by default. Turn off for debugging or to force full prefill on every request.",
            isOn: $tempCacheEnabled
        )
        SettingsToggle(
            title: "Disk Cache",
            description: "...",
            isOn: $tempDiskCacheEnabled
        )
        .disabled(!tempCacheEnabled)
        .opacity(tempCacheEnabled ? 1.0 : 0.5)
        DisclosureGroup("Advanced") { ... }
        .disabled(!tempCacheEnabled)
        .opacity(tempCacheEnabled ? 1.0 : 0.5)
    }
}
```

**Why `.disabled` + `.opacity`**: SwiftUI's `.disabled` alone keeps the control
visually enabled but non-interactive — not a clear affordance. `.opacity(0.5)`
adds the visual dimming pattern osaurus uses elsewhere. (Potential follow-up:
extract into a view modifier if this pattern becomes common.)

**Blast radius**:
- UI-only change. Persistence + runtime wiring was done in C-001, C-006.
- The `SettingsSubsection` title stays "Cache Storage" (not renamed to
  "KV Cache" etc.) to avoid colliding with the sibling "KV Cache" subsection
  above it (which covers quantization / prefill / max tokens). **Possible
  future rename** — flag for review but don't touch now.

**Audit focus**:
- Verify the master toggle appears above Disk Cache in Settings → Local Inference.
- Verify toggling master off grays out the Disk Cache toggle and the Advanced
  disclosure group.
- Verify toggling master back on restores full interactivity.
- Verify saving with master off persists `cacheEnabled: false` in the JSON
  and saving with master on persists `cacheEnabled: nil` (absent from JSON).

---

### C-008 — Split `serverRestartNeeded` / `modelReloadNeeded` + wire refresh

- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `edit` (change detection logic + add `refreshCacheConfig` call)
- **Severity**: P0
- **Depends on**: C-001, C-005
- **Doc ref**: CONSIDERATIONS §A.1 / §A.3
- **Why**: The single `serverRestartNeeded` flag conflated two different
  propagation paths. Generation / cache settings changes were triggering a
  NIO restart (overkill — nothing NIO-related changed) without actually
  applying the changes to loaded models (pre-existing bug). We split into
  two flags:
  - `serverRestartNeeded` → restarts NIO HTTP server (port, CORS, eviction policy)
  - `modelReloadNeeded` → calls `ModelRuntime.refreshCacheConfig()` to rebuild
    coordinators on loaded models

**Before**:
```swift
let serverRestartNeeded =
    previousServerCfg.port != configuration.port
    || previousServerCfg.exposeToNetwork != configuration.exposeToNetwork
    || previousServerCfg.allowedOrigins != configuration.allowedOrigins
    || previousServerCfg.genTopP != configuration.genTopP
    || previousServerCfg.genKVBits != configuration.genKVBits
    || previousServerCfg.genKVGroupSize != configuration.genKVGroupSize
    || previousServerCfg.genQuantizedKVStart != configuration.genQuantizedKVStart
    || previousServerCfg.genMaxKVSize != configuration.genMaxKVSize
    || previousServerCfg.genPrefillStepSize != configuration.genPrefillStepSize
    || previousServerCfg.modelEvictionPolicy != configuration.modelEvictionPolicy

// ...
if serverRestartNeeded {
    await AppDelegate.shared?.serverController.restartServer()
}
```

**After**:
```swift
// serverRestartNeeded gates restarting the NIO HTTP server. Only the
// fields that affect how the socket is opened / CORS / eviction belong here.
let serverRestartNeeded =
    previousServerCfg.port != configuration.port
    || previousServerCfg.exposeToNetwork != configuration.exposeToNetwork
    || previousServerCfg.allowedOrigins != configuration.allowedOrigins
    || previousServerCfg.modelEvictionPolicy != configuration.modelEvictionPolicy

// modelReloadNeeded gates calling ModelRuntime.refreshCacheConfig().
// These fields flow into RuntimeConfig.snapshot() or CacheCoordinatorConfig.
let modelReloadNeeded =
    previousServerCfg.genTopP != configuration.genTopP
    || previousServerCfg.genKVBits != configuration.genKVBits
    || previousServerCfg.genKVGroupSize != configuration.genKVGroupSize
    || previousServerCfg.genQuantizedKVStart != configuration.genQuantizedKVStart
    || previousServerCfg.genMaxKVSize != configuration.genMaxKVSize
    || previousServerCfg.genPrefillStepSize != configuration.genPrefillStepSize
    || previousServerCfg.genTurboQuant != configuration.genTurboQuant    // NEW — was missing pre-migration
    || previousServerCfg.cacheEnabled != configuration.cacheEnabled      // NEW
    || previousServerCfg.cacheDiskEnabled != configuration.cacheDiskEnabled  // NEW
    || previousServerCfg.cacheDiskMaxGB != configuration.cacheDiskMaxGB  // NEW
    || previousServerCfg.cacheMaxBlocks != configuration.cacheMaxBlocks  // NEW

// ...
if serverRestartNeeded {
    await AppDelegate.shared?.serverController.restartServer()
}
if modelReloadNeeded {
    await ModelRuntime.shared.refreshCacheConfig()
}
```

**What was fixed beyond the migration**:
- `genTurboQuant` was NEVER in `serverRestartNeeded` — pre-existing bug. Now in
  `modelReloadNeeded` where it belongs.
- Saving a new TurboQuant setting without touching the model now takes effect
  immediately (assuming the model is already loaded).

**What was removed but not lost**:
- Gen* fields are no longer in `serverRestartNeeded`. Changing kv_bits used to
  restart NIO for no reason — that side-effect is gone. Users who had server
  monitoring alerts on restart events will see fewer of them.

**Blast radius**:
- `ConfigurationView.saveConfiguration()` is the only path that uses these
  flags. No external callers.
- The `Task { @MainActor in ... }` block now potentially awaits BOTH
  `restartServer` and `refreshCacheConfig`. These are independent — restart
  doesn't touch `ModelRuntime`, refresh doesn't touch NIO. Order is:
  restart first, then refresh. Refresh runs on the actor, restart runs on
  MainActor via `serverController`.

**Audit focus**:
- Verify the `modelReloadNeeded` flag triggers `refreshCacheConfig()` via the
  `Task { @MainActor in ... }` path (which bridges to the ModelRuntime actor
  via `await`).
- Verify changing only port/CORS now does NOT trigger `refreshCacheConfig`.
- Verify changing only KV bits does NOT trigger `restartServer`.
- Verify changing BOTH does trigger both.
- Check every new field in `modelReloadNeeded` matches a settings-save codepath
  that actually writes the field (C-001 / C-006).

---

### C-009 — Fix concurrency issues in `refreshCacheConfig`

- **File**: `Packages/OsaurusCore/Services/ModelRuntime.swift`
- **Kind**: `edit` (two changes to the same method)
- **Severity**: P0 (correctness — prevents two real races)
- **Depends on**: C-005
- **Doc ref**: Self-audit after C-005 landed
- **Why**: Two separate concurrency issues found during a deeper audit of C-005:

**Issue 1 — Unsafe dictionary iteration during actor suspension**:
`for (_, holder) in modelCache` iterates the live dictionary. Inside the loop,
`installCacheCoordinator` awaits on `container.perform`. During that suspension
the actor is free to service other calls — including `unload(name:)` which
mutates `modelCache`. Iterating a dictionary while another thread mutates it
is undefined behavior.

**Issue 2 — Nil-coordinator window**:
The previous code did `holder.container.disableCaching()` before
`installCacheCoordinator`. Between those two calls, `container.cacheCoordinator`
is nil. If a queued `generateEventStream` on the same container ran at that
instant (via the container's serial `perform` queue), its `TokenIterator` would
initialize with `cacheCoordinator: nil` — silently skipping caching for that
one generation.

Per vmlx `ModelContainer.enableCaching(config:)`:
```swift
let coordinator = CacheCoordinator(config: config)
_cacheCoordinator.withLock { $0 = coordinator }
```
The lock means `enableCaching` atomically **replaces** the coordinator —
there's never a moment where it's nil in between. So the explicit
`disableCaching()` is not just redundant, it creates the problem.

**Changes**:

1. **Snapshot `modelCache.values` before iterating**:
```swift
let holders = Array(modelCache.values)
for holder in holders {
    await installCacheCoordinator(on: holder, serverCfg: serverCfg)
}
```
- If `unload(name:)` runs during a `container.perform` suspend, `modelCache`
  can change safely — our loop operates on a separate `Array` of references.
- Holder references remain valid because they're strong references. If a
  holder is unloaded during the loop, we still refresh its coordinator
  (wasted work, but harmless).

2. **Remove `holder.container.disableCaching()` before the install call**:
   `installCacheCoordinator` already handles both the master-on and master-off
   paths internally:
   - master on → calls `enableCaching(config:)` which atomically replaces the
     coordinator (no nil window)
   - master off → calls `disableCaching()` to release the old coordinator
   The explicit pre-disable was redundant in both branches.

**Updated doc comment** explains the invariants explicitly so future readers
know why the pre-disable was removed (they might otherwise "add it back for
safety").

**Preserved**:
- `cancelActiveGeneration` is still the first step.
- `cachedConfig` still cleared.
- `serverCfg` still re-read.
- Log message updated to use the captured `holders.count` (not the live
  `self.modelCache.count`) so the count reflects what was actually refreshed.

**Blast radius**:
- Only `refreshCacheConfig` is affected. `loadContainer` (the other caller
  of `installCacheCoordinator`) is unchanged.
- No behavior change when no concurrent calls happen — this is a correctness
  fix for edge cases.

**Audit focus**:
- Verify `Array(modelCache.values)` produces a snapshot of strong references
  (it does — Dictionary's `values` property returns `Values` which is a view;
  wrapping in `Array(...)` materializes the elements).
- Verify removing the pre-disable doesn't leak an old coordinator. It can't:
  `enableCaching`'s atomic swap replaces the coordinator, old one is released
  by ARC when no iterator still references it.
- Verify the nil-coordinator window is gone by reading
  `installCacheCoordinator` + `enableCaching` together:
  1. If master on: `enableCaching(newConfig)` → coordinator atomically
     replaced → `setHybrid` on new coordinator. Old coordinator released.
  2. If master off: `disableCaching()` → coordinator nil → setHybrid is no-op
     because `holder.container.cacheCoordinator?` is nil.

---

### C-010 — Invalidate `MemoryContextAssembler` cache on window close

- **File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift`
- **Kind**: `edit` (extend closeWindow cleanup)
- **Severity**: P2
- **Depends on**: None
- **Doc ref**: GAPS §2.2 / CONSIDERATIONS §A.2
- **Why**: `MemoryContextAssembler` caches assembled memory contexts per agent
  with a 10-second TTL. When a user closes a window, the stale entry was not
  purged — so if the user edited memory in another window and reopened a
  chat with the same agent within 10 seconds, they could briefly see the
  old assembly. Minor, but the fix is trivial.

**Before** (lines 575-583):
```swift
let closedSessionId = windows[id]?.sessionId
Task {
    if let sid = closedSessionId {
        await ModelRuntime.shared.invalidateSession(sid.uuidString)
        PluginHostContext.invalidatePreflightCache(sessionId: sid.uuidString)
    }
    let active = self.activeLocalModelNames()
    await ModelRuntime.shared.unloadModelsNotIn(active)
}
```

**After**:
```swift
let closedSessionId = windows[id]?.sessionId
let closedAgentId = windows[id]?.agentId
Task {
    if let sid = closedSessionId {
        await ModelRuntime.shared.invalidateSession(sid.uuidString)
        PluginHostContext.invalidatePreflightCache(sessionId: sid.uuidString)
    }
    if let aid = closedAgentId {
        await MemoryContextAssembler.shared.invalidateCache(agentId: aid.uuidString)
    }
    let active = self.activeLocalModelNames()
    await ModelRuntime.shared.unloadModelsNotIn(active)
}
```

**Uses existing API**: `MemoryContextAssembler.invalidateCache(agentId:)` was
already public (it's an actor method). No new code on the assembler side.

**Blast radius**:
- Zero impact on the happy path (window close). Just clears one more dictionary
  entry via an actor method call.
- Race-free: if the user opens a new window on the same agent before the
  `Task` completes, the new window's first compose may or may not see the
  invalidation depending on ordering. Either way the result is correct because
  memory is always re-read from the database on rebuild — the cache is pure
  10s-TTL optimization.

**Audit focus**:
- Verify `closedAgentId` captures the pre-removal agent ID before
  `windows.removeValue(forKey: id)` on line ~589.
- Verify the new Task body doesn't introduce any main-actor hops (it's already
  a detached Task inside a MainActor method, so hops happen at each `await`).

---

### C-011 — Add disk KV cache helpers to `OsaurusPaths`

- **File**: `Packages/OsaurusCore/Utils/OsaurusPaths.swift`
- **Kind**: `add` (3 new static methods)
- **Severity**: P1
- **Depends on**: C-004 (uses the same `kv_v2` subdirectory convention)
- **Doc ref**: GAPS §4.2 / CONSIDERATIONS §B.1
- **Why**: Prior to this change, the `kv_v2` subdirectory was constructed
  inline in `ModelRuntime.buildCacheCoordinatorConfig`. Centralizing the path
  in `OsaurusPaths` means:
  1. The path isn't hard-coded in multiple places (avoids drift)
  2. UI code (inspector view) can read the size / clear the dir without
     reaching into `ModelRuntime` internals
  3. Future migrations (renaming the dir, moving it under a different root)
     touch one file

**New API surface** (3 static methods):

```swift
/// Disk KV cache directory used by vmlx-swift-lm's `DiskCache` (L2 tier).
public static func diskKVCache() -> URL {
    cache().appendingPathComponent("kv_v2", isDirectory: true)
}

/// Current size of the disk KV cache in bytes. Returns 0 when the
/// directory doesn't exist yet.
public static func diskKVCacheUsageBytes() -> Int {
    let url = diskKVCache()
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    return directorySize(at: url)
}

/// Deletes every file under the disk KV cache directory. The directory
/// itself is left in place. Returns the number of bytes freed.
@discardableResult
public static func clearDiskKVCache() -> Int {
    // ... enumerates and removes each entry, returns pre-clear size
}
```

**Design decisions**:
- `clearDiskKVCache` **does not** delete the directory itself — only its
  contents. This means subsequent model loads don't need to re-run
  `ensureExistsSilent` (the dir is still there).
- `diskKVCacheUsageBytes()` uses the existing `directorySize(at:)` helper,
  so walking semantics are consistent with other disk-usage reporting in
  the codebase.
- `@discardableResult` on `clearDiskKVCache` so callers can optionally show
  "freed X MB" without forcing everyone to.

**Caller updates** (in the same commit):
- `ModelRuntime.buildCacheCoordinatorConfig` switched from
  `OsaurusPaths.cache().appendingPathComponent("kv_v2", ...)` to
  `OsaurusPaths.diskKVCache()`.
- Other callers (C-012, C-013) added in this same pass.

**Blast radius**:
- Adds three public static methods. No breaking change to existing callers.
- The path constant moves from inline string to the helper — if we ever need
  to rename, only this file changes.

**Audit focus**:
- Verify `clearDiskKVCache` is safe when called while models are loaded.
  The vmlx `DiskCache` will observe deleted files on its next SQLite query
  and may log I/O errors — NOT crash. For a crash-free clean clear, callers
  should unload models first (the expanded "Clear All" button in C-012 does
  this via `MLXService.clearRuntimeCache()` before calling this helper).
- Verify `fileExists(atPath:)` check happens before `directorySize(at:)` so
  a first-run user without any cache dir doesn't get a noisy enumeration.

---

### C-012 — Expand `ModelCacheInspectorView` with disk cache row

- **File**: `Packages/OsaurusCore/Views/Model/ModelCacheInspectorView.swift`
- **Kind**: `add` (new UI row + state vars + formatter helper) + `edit` (refresh + Clear All)
- **Severity**: P1
- **Depends on**: C-011
- **Doc ref**: GAPS §4.1 / §4.2 / CONSIDERATIONS §I.1
- **Why**: Before this change the inspector showed only loaded models. The
  user had no way to see how much disk space the L2 cache was consuming or
  to clear it without also unloading models. The "Clear All" button scope
  was also misleading — it said "clear" but only unloaded model weights.

**Three changes in one commit**:

1. **New state vars** (added to view):
```swift
@State private var diskKVCacheBytes: Int = 0
@State private var isClearingDiskKV = false
```

2. **New UI row** above the existing divider. Shows:
   - Storage icon
   - "Disk KV Cache" label
   - Size display via `ByteCountFormatter` (MB/GB), "Empty" when 0
   - "Clear" button, disabled+dimmed when size is 0
   
   The row is styled like a sub-card (rounded rectangle, cardBackground
   opacity 0.5) to differentiate it visually from the model list above.

3. **`Clear All` button behavior expanded** — now:
   - Calls `MLXService.shared.clearRuntimeCache()` (existing — unloads models)
   - Calls `OsaurusPaths.clearDiskKVCache()` (new — wipes L2)
   - Refreshes both `items` and `diskKVCacheBytes`
   - Disabled only when BOTH models empty AND disk cache empty (previously
     only checked `items.isEmpty`)

4. **`refresh()` method** loads `diskKVCacheBytes` from `OsaurusPaths`.

5. **`formatBytes()` helper** using `ByteCountFormatter(.useMB, .useGB)`.

**UX notes** (for the audit):
- The disk cache row is always visible, even when empty (shows "Empty"). This
  teaches users that a disk cache exists. A possible alternative would be
  hiding the row when 0 bytes — decided against because it would make the
  feature invisible to first-time users.
- The "Clear" button on the row clears ONLY the disk cache, not models. This
  lets users reclaim disk space without losing their loaded models / GPU warmup.
- The "Clear All" button now has honest scope: "unload models + wipe disk cache".
- UI caches (ThreadCache, BlockMemoizer, font/LaTeX NSCache instances) are
  NOT cleared by either button — they're content-keyed and auto-evicted
  under memory pressure. Documented in a code comment.

**Order of operations for Clear All**:
```swift
await MLXService.shared.clearRuntimeCache()  // unload models, release coordinators
_ = OsaurusPaths.clearDiskKVCache()          // THEN wipe disk files
await refresh()                               // refresh both displays
```
Important: unload first so the package's `DiskCache` closes its SQLite
handles cleanly before we delete the backing files. Otherwise the SQLite
journal files may be recreated after our delete.

**Blast radius**:
- UI-only. No runtime behavior change outside explicit user button clicks.
- A user who opens the inspector for the first time will see the new disk
  cache row immediately. If they had pre-migration cache files in a
  different directory, they're invisible (we only track `kv_v2/`).

**Audit focus**:
- Verify the disk cache row uses `OsaurusPaths.diskKVCache()` (from C-011),
  not a hard-coded path.
- Verify the "Clear" button on the disk row is re-enabled after the clear
  completes (via `diskKVCacheBytes = OsaurusPaths.diskKVCacheUsageBytes()`
  in the async Task body).
- Verify the "Clear All" expanded order: models first, disk second, refresh
  last.
- Visually verify the row alignment and card styling matches osaurus's
  existing card patterns.

---

### C-013 — Round-trip tests for new `ServerConfiguration` cache fields

- **File**: `Packages/OsaurusCore/Tests/Networking/ServerConfigurationStoreTests.swift`
- **Kind**: `add` (5 new `@Test` functions)
- **Severity**: P1
- **Depends on**: C-001, C-006
- **Doc ref**: GAPS §10.2 / CONSIDERATIONS §H.1 (round-trip subset)
- **Why**: Covers the encoder/decoder round-trip for the four new cache
  fields (`cacheEnabled`, `cacheDiskEnabled`, `cacheDiskMaxGB`,
  `cacheMaxBlocks`). Five test cases chosen to catch the realistic bug
  patterns:

1. **`cacheFields_missingInJSON_decodeAsNil`** — parses an empty `{}` JSON
   and asserts all four fields are nil. Guards against accidentally adding
   a default-to-true path in the decoder that would override the user's
   explicit nil.

2. **`cacheFields_fullRoundTrip_preservesExplicitValues`** — encodes a
   config with all four fields set to non-default values (cacheEnabled=false,
   disk=false, 8.0GB, 500 blocks), decodes, verifies every value matches.
   Catches any encoder that omits optional fields with non-nil values.

3. **`cacheFields_explicitTrueRoundTrip`** — sets `cacheEnabled = true`
   explicitly (as opposed to nil), encodes, decodes, asserts still `true`.
   This guards against a common bug where `Bool?` fields are encoded as
   nil when their value matches the default-on semantics.

4. **`cacheFields_mixedNilAndExplicit`** — sets some fields explicit,
   others nil. Tests the common "user only touched disk cache" UX path.

5. **`cacheFields_partialJSON_onlyDecodedFields`** — feeds a partial JSON
   string with only two of the four fields and asserts the other two decode
   as nil. Simulates hand-edited config files or partial test fixtures.

**Test patterns match existing tests**:
- Uses `JSONEncoder()` / `JSONDecoder()` directly (no `ServerConfigurationStore`
  indirection) for the data-level tests, matching `codableRoundTrip_*`.
- Does not touch the filesystem — all data stays in memory. Fast, no cleanup.
- Uses `#expect(...)` Swift Testing assertions matching existing style.

**Blast radius**:
- Tests-only. No production code changes.
- Adds 5 test cases to the suite. Runtime cost is trivial.

**Audit focus**:
- Verify each test asserts on the correct field.
- Verify the "partial JSON" test uses a string that actually parses (trailing
  comma would break it).
- Verify `cacheFields_missingInJSON_decodeAsNil` uses `Data("{}".utf8)` —
  this produces a valid empty JSON object that the decoder will accept (vs.
  `Data()` which is empty and would throw).

---

## Round 3 — cache-surface strip + memory/tools defaults

The following entries supersede the user-facing portions of C-001..C-013.
Direction: osaurus should have **zero** cache knobs. Caching is the
package's concern. Memory and tools default **off**, with minimal toggles
for users to turn them on.

---

### C-R01 — Remove user-facing cache fields from `ServerConfiguration`

- **File**: `Packages/OsaurusCore/Models/Configuration/ServerConfiguration.swift`
- **Kind**: `remove` (fields, CodingKeys, decoder lines, init parameters, init body)
- **Supersedes**: C-001
- **Why**: These fields were exposed for user configuration, but we've
  decided caching should be entirely package-owned. Users don't see cache
  knobs — the package picks sensible defaults, and osaurus tweaks a few
  internal values in `ModelRuntime.buildCacheCoordinatorConfig`
  (`modelKey`, disk cache dir, max blocks by RAM).

**Removed**:
- `public var cacheEnabled: Bool?`
- `public var cacheDiskEnabled: Bool?`
- `public var cacheDiskMaxGB: Float?`
- `public var cacheMaxBlocks: Int?`
- Corresponding `CodingKeys` cases
- Decoder `decodeIfPresent` calls
- Memberwise init parameters + assignments

**Added**: A comment block explaining that cache config is package-owned
and pointing readers to `ModelRuntime.installCacheCoordinator` for the
internal-only config construction.

**Migration**: Existing `ServerConfiguration.json` files with these fields
decode without error — the decoder ignores unknown keys. A test in
`ServerConfigurationStoreTests` (C-R05) covers this path explicitly.

**Blast radius**:
- Every callsite that read these fields is removed by C-R02..C-R04.
- No network / API exposure of these fields existed, so no HTTP schema
  change.
- `ConfigurationView` state vars + UI elements removed in C-R02.

**Audit focus**:
- Verify no grep for `cacheEnabled`, `cacheDiskEnabled`, `cacheDiskMaxGB`,
  `cacheMaxBlocks` returns results in osaurus code after this change.
- Verify the comment explaining the new ownership is present.
- Verify existing user JSON files still deserialize (covered by C-R05 test).

---

### C-R02 — Remove Cache Storage Settings subsection

- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `remove` (state vars, UI block, load/save/reset wiring)
- **Supersedes**: C-006, C-007
- **Why**: Follows from C-R01 — the fields no longer exist, so the UI for
  them goes too. Settings is leaner.

**Removed**:
- `@State private var tempCacheEnabled: Bool = true`
- `@State private var tempDiskCacheEnabled: Bool = true`
- `@State private var tempDiskCacheMaxGB: String = ""`
- `@State private var tempCacheMaxBlocks: String = ""`
- Entire `SettingsSubsection(label: "Cache Storage") { ... }` block
  including master toggle, disk toggle, advanced stepper fields
- Search keyword entries for "Cache Storage" and "Disk Cache"
- Load wiring: `tempCacheEnabled = configuration.cacheEnabled ?? true` etc.
- Save wiring: `configuration.cacheEnabled = tempCacheEnabled ? nil : false` etc.
- Reset wiring: `tempCacheEnabled = true` etc.

**Preserved**:
- All other Local Inference section content (Sampling, KV Cache,
  Model Management) stays unchanged.

**Blast radius**:
- UI only. Backend changes already made by C-R01.

**Audit focus**:
- Open Settings → Local Inference: verify the Cache Storage subsection
  is gone but everything else renders.
- Verify Reset to Defaults doesn't crash (no stale references).
- Verify search for "cache" in Settings no longer matches a Cache Storage
  section.

---

### C-R03 — Split `serverRestartNeeded` / replace `modelReloadNeeded` with `runtimeConfigChanged`

- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `edit` (rewrite change-detection block)
- **Supersedes**: C-008
- **Why**: C-008 introduced `modelReloadNeeded` to gate calls to
  `ModelRuntime.refreshCacheConfig()`. With cache settings stripped
  (C-R01) and `refreshCacheConfig` removed (C-R06), there's no reason
  to rebuild coordinators on settings save. The gen* fields (top-p,
  kvBits, kvGroup, quantStart, maxKVSize, prefillStepSize, turboQuant)
  still flow into `RuntimeConfig.snapshot()` at request time — we just
  need to invalidate the cached snapshot so next request reads fresh
  values.

**Before** (C-008 state):
```swift
let modelReloadNeeded = ...  // tracked gen* + cache* fields
// ...
if modelReloadNeeded {
    await ModelRuntime.shared.refreshCacheConfig()
}
```

**After** (C-R03):
```swift
let runtimeConfigChanged = ...  // tracks only gen* fields; no cache* fields
// ...
if runtimeConfigChanged {
    await ModelRuntime.shared.invalidateConfig()
}
```

**Preserved**:
- `serverRestartNeeded` continues to gate NIO restart on port/CORS/eviction
  policy changes.
- `ModelRuntime.invalidateConfig()` is still a valid, callable method that
  was pre-existing in the actor.

**Blast radius**:
- Settings save path only. No model reload happens on settings change —
  just a cheap in-memory config snapshot drop.
- Users who change kvBits etc. see it take effect on the NEXT request,
  with no model reload.

**Audit focus**:
- Verify `modelReloadNeeded` name is gone from the file.
- Verify `refreshCacheConfig()` is not called from anywhere in osaurus
  (grep for it).
- Verify changing a gen* field in Settings causes
  `ModelRuntime.invalidateConfig()` to fire.

---

### C-R04 — Remove Disk KV Cache row from `ModelCacheInspectorView`

- **File**: `Packages/OsaurusCore/Views/Model/ModelCacheInspectorView.swift`
- **Kind**: `remove` (state vars, UI row, formatBytes helper)
- **Supersedes**: C-012
- **Why**: Same reasoning as C-R01/C-R02 — caching is invisible. Users
  don't see disk cache usage in the inspector. The "Clear All" button is
  restored to its original narrow scope (unload models only).

**Removed**:
- `@State private var diskKVCacheBytes: Int = 0`
- `@State private var isClearingDiskKV = false`
- The HStack rendering the Disk KV Cache row with icon, label, size,
  Clear button
- `private func formatBytes(_ bytes: Int) -> String` — the `Int`
  overload added for the row. (Pre-existing `formatBytes(_ bytes: Int64)`
  on `ModelCacheRow` is untouched — separate function.)
- `diskKVCacheBytes = OsaurusPaths.diskKVCacheUsageBytes()` call in
  `refresh()`
- `_ = OsaurusPaths.clearDiskKVCache()` call in the Clear All button
- `diskKVCacheBytes` check in the Clear All button's disabled condition

**Preserved**:
- `OsaurusPaths.diskKVCache()` / `diskKVCacheUsageBytes()` /
  `clearDiskKVCache()` helpers from C-011. Still used internally by
  `ModelRuntime.buildCacheCoordinatorConfig` and available for debug /
  future features.

**Blast radius**:
- UI only. Cache still works and persists to disk as before — users just
  don't see the usage row.

**Audit focus**:
- Open Model Cache Inspector: verify only the model list + Clear All
  button are visible, no disk cache row.
- Verify Clear All button still unloads models.

---

### C-R05 — Replace cache round-trip tests with migration-compat test

- **File**: `Packages/OsaurusCore/Tests/Networking/ServerConfigurationStoreTests.swift`
- **Kind**: `remove` (5 tests) + `add` (1 test)
- **Supersedes**: C-013
- **Why**: The 5 `cacheFields_*` tests from C-013 exercised fields that no
  longer exist. Replaced with one test that validates pre-migration JSON
  files (containing now-removed `cache*` keys) still decode successfully.

**Removed**:
- `cacheFields_missingInJSON_decodeAsNil`
- `cacheFields_fullRoundTrip_preservesExplicitValues`
- `cacheFields_explicitTrueRoundTrip`
- `cacheFields_mixedNilAndExplicit`
- `cacheFields_partialJSON_onlyDecodedFields`

**Added**:
- `decode_ignoresRemovedCacheFields` — feeds JSON with `cacheEnabled`,
  `cacheDiskEnabled`, `cacheDiskMaxGB`, `cacheMaxBlocks` keys and asserts
  the decoder ignores them without throwing. Verifies existing users'
  `ServerConfiguration.json` files migrate cleanly.

**Blast radius**:
- Tests only. No production code change.

**Audit focus**:
- Verify the new test actually compiles (uses the same Swift Testing
  `@Test` macro as the rest of the file).
- Verify the JSON blob is syntactically valid.

---

### C-R06 — Simplify `ModelRuntime` cache config + remove `refreshCacheConfig`

- **File**: `Packages/OsaurusCore/Services/ModelRuntime.swift`
- **Kind**: `edit` (simplify) + `remove` (two methods)
- **Supersedes**: C-004 partial, C-005, C-009
- **Why**: C-004 built a `CacheCoordinatorConfig` from `ServerConfiguration`
  user fields. Now those fields don't exist. The builder should use
  hardcoded osaurus-internal defaults only. `refreshCacheConfig` was there
  to propagate settings changes to loaded coordinators — with no settings
  to propagate, it's dead code.

**Changes to `buildCacheCoordinatorConfig`**:
- **Before**: `private nonisolated static func buildCacheCoordinatorConfig(modelName:, serverCfg:) -> CacheCoordinatorConfig?`
  — returned nil when `serverCfg.cacheEnabled == false`
- **After**: `private nonisolated static func buildCacheCoordinatorConfig(modelName:) -> CacheCoordinatorConfig`
  — non-optional return, no serverCfg param. Hardcoded defaults only:
  - `enableDiskCache = isDirectoryWritable(diskCacheDir)`
  - `diskCacheMaxGB = 4.0` (hardcoded)
  - `modelKey = modelName`
  - `maxCacheBlocks` tiered by RAM:
    - `< 16 GB` → 500 blocks (~32k tokens)
    - `16-48 GB` → 1000 blocks (~64k tokens)
    - `≥ 48 GB` → 2000 blocks (~128k tokens)

**Changes to `installCacheCoordinator`**:
- **Before**: `private func installCacheCoordinator(on holder:, serverCfg:) async`
  — master-off branch called `disableCaching()`
- **After**: `private func installCacheCoordinator(on holder:) async`
  — always enables caching. The guard-let against the master toggle is gone.

**Removed**:
- `func refreshCacheConfig() async` — unreachable after C-R03.

**Preserved**:
- `isDirectoryWritable(_:)` — still used by `buildCacheCoordinatorConfig`
- `invalidateSession(_:)` — still a documented no-op for API compat

**Blast radius**:
- `loadContainer` simplified: no longer awaits `ServerConfigurationStore.load()`
  before installing the coordinator.
- Users cannot disable caching. For debug purposes, developers can edit
  this file directly.

**Audit focus**:
- Verify `refreshCacheConfig` is completely gone.
- Verify `buildCacheCoordinatorConfig` takes only `modelName: String`.
- Verify the RAM tier logic picks sane defaults for 16/32/64 GB Macs.
- Verify no dangling references to `serverCfg` in the cache config path.

---

### C-014 — Flip `MemoryConfiguration.enabled` default to `false`

- **File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`
- **Kind**: `edit` (change default parameter value)
- **Severity**: P0 (behavior change for existing users)
- **Doc ref**: CONSIDERATIONS §A.1
- **Why**: Memory was silently enabled by default, injecting up to ~9,300
  tokens per request (working memory 3000 + summaries 3000 + chunks 3000
  + graph 300). Most users never opened the memory UI and didn't know
  about the bloat. Flipping to opt-in aligns with the "simple by default"
  direction and matches peer apps (Claude Projects, Cursor Memory).

**Before** (line 94):
```swift
enabled: Bool = true,
```

**After**:
```swift
enabled: Bool = false,
```

**Decoder** (line 170) is unchanged:
```swift
enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
```

Because `defaults.enabled` now reads `false`, existing JSON files without
the field decode as `false`. Users who explicitly set `"enabled": true` in
their `MemoryConfiguration.json` keep memory on — the decoder only
defaults when the field is absent.

**Migration**:
- **New installs**: memory off by default.
- **Existing users without an explicit override**: memory off on next launch.
  They lose the feature until they re-enable in Settings (C-015).
- **Existing users with explicit `enabled: true`**: no change, memory stays on.

**Blast radius**:
- All memory assembly calls skip via
  `MemoryContextAssembler.buildContext` line 46's `guard config.enabled`
  short-circuit. Zero tokens injected.
- `SystemPromptComposer.appendMemory` becomes a no-op for users who don't
  opt in. Large token savings per request.

**Audit focus**:
- Delete the osaurus config dir on a test machine, launch, check
  memory is off.
- With an existing config with `"enabled": true`, launch, check
  memory stays on.
- With a config with no enabled field, launch, check memory is off.

---

### C-015 — Add Memory toggle to Settings → Chat

- **File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- **Kind**: `add` (state var, UI subsection, load, save, reset, search keyword)
- **Severity**: P0 (required companion to C-014 — otherwise users have no
  way to re-enable memory)
- **Depends on**: C-014
- **Why**: After flipping the default, users need an in-UI path to turn
  memory back on. Prior to this change there was NO Memory toggle in the
  Settings view at all — users had to edit
  `~/.osaurus/config/MemoryConfiguration.json` manually. That's
  unacceptable for a feature users might want to opt into.

**Added**:
- `@State private var tempMemoryEnabled: Bool = false`
- New `SettingsSubsection(label: "Memory")` inside the Chat section,
  between Tools and Clipboard subsections
- Load in `loadConfiguration()`:
  ```swift
  tempMemoryEnabled = MemoryConfigurationStore.load().enabled
  ```
- Save in `saveConfiguration()`:
  ```swift
  var memoryCfg = MemoryConfigurationStore.load()
  if memoryCfg.enabled != tempMemoryEnabled {
      memoryCfg.enabled = tempMemoryEnabled
      MemoryConfigurationStore.save(memoryCfg)
  }
  ```
- Reset in `resetToDefaults()`:
  ```swift
  tempMemoryEnabled = false
  ```
- Search keyword "Memory" added to the Chat section's `matchesSearch()` args.

**UI copy**:
- Toggle label: "Enable memory"
- Description: "Inject persistent memory (profile, working memory,
  summaries, relationships) into the system prompt. Off by default —
  memory can add thousands of tokens per request. Enable for agents that
  need long-term context across conversations."

**Scope explicitly NOT in this change**:
- No per-agent override
- No budget editing UI (workingMemoryBudgetTokens etc.)
- No tri-state (user sets global, not per-agent)

Power users who need per-agent or budget control can still edit the JSON.

**Blast radius**:
- Settings UI only. Respects the same
  `MemoryConfigurationStore.save(_:)` code path used by
  `MemoryConfiguration.json` — nothing custom.

**Audit focus**:
- Toggle on → save → close settings → reopen → verify toggle is on
- Toggle on → save → close settings → relaunch app → verify toggle is on
- Toggle on → run a chat → verify memory section appears in debug logs
  (need to look at the prompt token count)
- Toggle off → same cycle, verify memory is absent

---

### C-016 — Flip `ChatConfiguration.disableTools` default to `true`

- **File**: `Packages/OsaurusCore/Models/Chat/ChatConfiguration.swift`
- **Kind**: `edit` (change default in two places: memberwise init + decoder)
- **Severity**: P0 (behavior change for existing users)
- **Depends on**: None
- **Why**: Tools were on by default, and preflight capability search
  loaded up to 8 tool specs into the system prompt per request
  (~320–640 tokens). For a user just chatting with a model, that's
  cognitive + token overhead they didn't ask for. Flipping to opt-in
  matches the memory default flip in C-014.

**Two changes in the same file**:

1. **Memberwise init default** (line 102):
```swift
// Before:
disableTools: Bool = false,
// After:
disableTools: Bool = true,
```

2. **Decoder default** (line 149):
```swift
// Before:
disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false
// After:
disableTools = try container.decodeIfPresent(Bool.self, forKey: .disableTools) ?? true
```

Both are needed because the decoder fallback and the init default are
independent in Swift — the decoder doesn't invoke the init when decoding.

**Companion change in `ConfigurationView.swift`**:
- `tempDisableTools` initial state flipped to `true`
- `resetToDefaults` sets `tempDisableTools = true`
- Description text updated to reflect the new default

**Migration**:
- **New installs**: tools disabled by default. Agents are plain chat.
- **Existing users without explicit override**: tools disabled on upgrade.
  They lose tool access until they re-enable in Settings OR flip the
  per-conversation Tools chip in the chat bar (C-018).
- **Existing users with `"disableTools": false`**: explicit override
  honored, tools stay on.
- **Existing users with `"disableTools": true`**: no change.

**Blast radius**:
- All tool-enabled flows: `SystemPromptComposer.finalizeContext` receives
  `toolsDisabled: true` from `ChatView.sendMessage` unless there's an
  override (C-017).
- `ToolRegistry.alwaysLoadedSpecs()` skipped.
- Preflight search skipped.
- Raw prompt shipped to model with ~320-640 token savings.
- Existing agents with explicit tool configs (Agent.manualToolNames)
  still flow through `Agent.toolSelectionMode`, but only when
  `toolsDisabled == false`. Need to verify this doesn't silently strip
  agent-level tool configs.

**Audit focus**:
- Flip the global, make a plain chat request, verify no tools in the
  final request payload (grep request logs for `tools:` key).
- Flip the global on, make a chat request, verify the preflight-selected
  tools are in the payload.
- Check an agent with explicit `manualToolNames: ["web_search"]` — when
  global is off, does the agent still get its tools? **Need to verify:**
  the code reads `toolsDisabled` before checking agent overrides, so
  agent-level tools may be stripped too. If that's wrong, we'll need a
  follow-up fix.

---

### C-017 — Add per-conversation tools override on `ChatWindowState`

- **File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowState.swift`
- **Kind**: `add` (new `@Published` property)
- **Severity**: P1
- **Depends on**: C-016
- **Why**: With the global default off (C-016), users need a way to
  enable tools for a specific conversation without flipping Settings.
  Adding per-window state keeps the override local and ephemeral —
  resets when the window closes.

**Added**:
```swift
/// Per-conversation override for the global `ChatConfiguration.disableTools`
/// setting. When nil, the global setting is used. When non-nil, it
/// overrides the global for this window only.
///
/// - `nil` → follow `ChatConfiguration.disableTools`
/// - `false` → tools enabled for this conversation
/// - `true`  → tools disabled for this conversation
@Published var toolsDisabledOverride: Bool?
```

**Consumed by C-018** (the chip) and `ChatView.sendMessage` where:
```swift
let effectiveToolsDisabled =
    windowState.toolsDisabledOverride ?? chatCfg.disableTools
```

**Scope**:
- Lives on `ChatWindowState` (ephemeral per-window). NOT persisted.
  Close the window, override is gone — matches the "simple on/off
  affordance" the user asked for.
- NOT a tool-by-tool list. The chip only flips the master on/off. If
  users need per-tool control, there's still the agent editor.
- NOT per-session in the sense of "saved to chat history". A user
  reopening a conversation starts fresh at `nil`.

**Blast radius**:
- `ChatView.sendMessage` reads it (wired in C-017 continuation)
- `FloatingInputCard` binds to it (C-018)
- Zero runtime cost when unset (nil coalesce).

**Audit focus**:
- Verify it's `@Published` so SwiftUI bindings work
- Verify it's declared `var` (not `let`) so the chip can mutate it

---

### C-018 — Add Tools chip to chat input bar

- **File**: `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift`
  (+ small wiring in `ChatView.swift` and `WorkView.swift`)
- **Kind**: `add` (new chip view + helper methods + selector row integration)
- **Severity**: P1
- **Depends on**: C-016, C-017
- **Why**: Give users an in-chat toggle for tools so they don't have to
  dive into Settings. Matches the user's explicit request: "simply within
  the chat bar there should be a button to open tools and then that opens
  submenu to enable disable tools".

**Design choice: simple on/off, no popover (for now)**:

The user asked for a "submenu to enable disable tools". We're shipping
V1 as a simple one-tap toggle (chip flips between enabled / disabled /
follow-global) rather than a full popover with per-tool checkboxes.
Rationale:
- 90% of users just want "tools on or off" — the chip handles this.
- Per-tool granularity already exists at the agent level
  (`Agent.manualToolNames`) — users who need it use the agent editor.
- A popover adds ~300 LoC and 4 extra reviewer checkpoints. Defer to a
  follow-up if users ask.

**Added in `FloatingInputCard.swift`**:
- `@Binding var toolsDisabledOverride: Bool?` — new required binding
- `private var effectiveToolsDisabled: Bool` — resolver helper
- `private var toolsChipActive: Bool` — style helper (inverse of disabled)
- `private var toolsChipBadge: String?` — shows "•" when override differs
  from the global default
- `private func cycleToolsOverride()` — tap handler: cycles
  nil → opposite-of-global → nil
- `private var toolsToggleChip: some View` — the chip view itself
- Selector row integration: chip shown in chat mode only
  (`workInputState == nil`), between Sandbox and Clipboard chips

**Cycle semantics**:
- Starting state: `nil` (follow global). Global default is now true
  (disabled), so tools chip appears off.
- First tap: `nil` → `false` (explicitly enabled). Chip lights up with
  `•` badge.
- Second tap: `false` → `nil` (back to global default). Chip dims, no badge.
- Visual states:
  - `toolsChipActive == true` → accent color, filled icon, "Tools" label
    bright
  - `toolsChipActive == false` → tertiary text color, outlined icon, dim label
- Help text reflects current state

**Wiring in `ChatView.swift`** (C-018 call site):
```swift
// In FloatingInputCard(...) call:
toolsDisabledOverride: $windowState.toolsDisabledOverride

// In sendMessage:
let effectiveToolsDisabled =
    windowState.toolsDisabledOverride ?? chatCfg.disableTools
```

**Wiring in `WorkView.swift`**:
- Same binding pass-through: `toolsDisabledOverride: $windowState.toolsDisabledOverride`
- Chip is hidden in work mode (`workInputState == nil` check in selector row)

**Wiring in preview (`FloatingInputCard.swift` PreviewWrapper)**:
- `toolsDisabledOverride: .constant(nil)` — preview doesn't have a real
  window state, uses a constant binding

**Blast radius**:
- Selector row gains one more chip in chat mode. No layout changes to
  existing chips (thinking / sandbox / clipboard stay in their spots).
- No persistence: override lives only in ChatWindowState and resets on
  window close.
- No HTTP API changes.

**Audit focus**:
- Open a chat, verify the Tools chip appears in the selector row
  (between Sandbox and Clipboard).
- Verify the chip defaults to "off" visual when global `disableTools`
  is `true` (new default).
- Tap the chip, verify it lights up and a "•" badge appears.
- Send a message, verify tools are in the request (via debug log).
- Tap the chip again, verify it returns to default state.
- Close the window, reopen, verify the override is gone (nil).
- Switch to work mode (WorkView), verify the chip is NOT visible.

---









