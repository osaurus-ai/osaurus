# VMLX Cache Integration — Second-Pass Considerations & Nuances

> Follow-up to `VMLX-CACHE-INTEGRATION-GAPS.md`. The first doc catalogued the
> obvious gaps. This second pass digs into subtle correctness issues, cross-function
> interactions, edge cases, and pre-existing bugs that the migration didn't create
> but now has to live alongside.

---

## A. Settings propagation — the biggest silent gap

### A.1 🔴 **Settings changes do not propagate to loaded models**

This is the single most important finding of the second pass.

**The flow today:**
1. User opens Settings, toggles Disk Cache off, saves.
2. `ConfigurationView.saveConfiguration()` writes the new `ServerConfiguration.json`
   via `ServerConfigurationStore.save()` (line 985).
3. If `serverRestartNeeded == true`, `ServerController.restartServer()` is called.
4. `restartServer()` tears down NIO and brings it back (lines 136-144 of `ServerController.swift`).
5. **`ModelRuntime.shared` is never touched.**
6. The user's loaded model still has its original `CacheCoordinator` with the
   old `CacheCoordinatorConfig` wired in at load time.
7. The `ModelRuntime.cachedConfig` still holds the stale `RuntimeConfig` snapshot.
8. Next request runs with stale config. The user sees no effect until they
   unload + reload the model.

**What's broken, concretely:**

| User action | Expected behavior | Actual behavior |
|-------------|-------------------|------------------|
| Toggle Disk Cache off, save | Disk cache stops being used | Disk cache keeps being used until model reload |
| Change Max Context Length | New `maxKVSize` takes effect | Old value used until model reload |
| Toggle TurboQuant | KV cache switches to compressed or uncompressed | Old mode used until model reload |
| Change Memory Cache Blocks | Paged cache resizes | No effect until model reload |
| Change KV Cache Bits | Quantization engages/disengages | No effect until model reload |

**Three compounding pre-existing bugs that make this worse:**

1. **`ModelRuntime.invalidateConfig()` is dead code.** Defined at line 140, called nowhere.
   ```
   $ grep -rn "invalidateConfig" --include="*.swift" /Users/eric/osaurus
   Packages/OsaurusCore/Services/ModelRuntime.swift:140:    func invalidateConfig() {
   ```
   This method was supposed to be called on settings save but nobody wired it up.

2. **`serverRestartNeeded` flag doesn't include `genTurboQuant`.**
   `ConfigurationView.swift:973-983` — the list of fields that trigger a server
   restart after save. It includes `genKVBits`, `genKVGroupSize`, `genMaxKVSize`,
   `genPrefillStepSize`, but **not** `genTurboQuant` or any of the new cache
   tier fields (`cacheDiskEnabled`, `cacheDiskMaxGB`, `cacheMaxBlocks`).

3. **Even if `serverRestartNeeded` triggered, `restartServer()` only restarts
   NIO.** It doesn't call into `ModelRuntime` at all. So the "restart" doesn't
   actually refresh the cached config or rebuild the coordinator.

**Fixes required (P0):**

1. Make `ConfigurationView.saveConfiguration()` call
   `await ModelRuntime.shared.invalidateConfig()` whenever any gen* or cache*
   field changes.
2. Add a new method `ModelRuntime.refreshCacheConfig()` that:
   ```swift
   func refreshCacheConfig() async {
       cachedConfig = nil
       // Rebuild coordinators on all loaded containers with new settings
       for (_, holder) in modelCache {
           holder.container.disableCaching()
           // Re-run the enableCaching() block from loadContainer()
           // (factor it into a private helper)
       }
   }
   ```
3. Extract the `CacheCoordinatorConfig` build block from `loadContainer()` into
   a private `buildCacheCoordinatorConfig(modelName: String) async -> CacheCoordinatorConfig`
   helper so both the load path and the refresh path use the same logic.
4. Call `refreshCacheConfig()` from `ConfigurationView` save handler on any
   cache-relevant field change.

**Alternative (simpler but worse UX):** show a banner in the settings view
"Changes take effect on next model reload" and don't attempt hot-reload. This
is a fair MVP but the user explicitly asked about "proper inference all of
that is configurable by user and that it takes effect properly" — so we should
aim for hot-reload.

---

### A.2 🟠 `resetToDefaults()` doesn't reset the new cache fields

**Where**: `Views/Settings/ConfigurationView.swift:847-884`

**Problem**: The Reset button resets `tempTopP`, `tempKVBits`, `tempKVGroup`,
`tempQuantStart`, `tempMaxKV`, `tempPrefillStep`, `tempTurboQuant`,
`tempEvictionPolicy`, but **does not** reset the three new cache fields I
added to our branch:
- `tempDiskCacheEnabled`
- `tempDiskCacheMaxGB`
- `tempCacheMaxBlocks`

**Fix** (one-line addition to `resetToDefaults()`):
```swift
tempDiskCacheEnabled = true
tempDiskCacheMaxGB = ""
tempCacheMaxBlocks = ""
```

---

### A.3 🟠 `serverRestartNeeded` flag is incomplete

**Where**: `Views/Settings/ConfigurationView.swift:973-983`

**Problem**: Even after we fix A.1 by routing cache-relevant changes through
`ModelRuntime.invalidateConfig()`, the existing `serverRestartNeeded` flag
still has bugs:
- Missing: `genTurboQuant` (pre-existing bug — was always missing)
- Missing: `cacheDiskEnabled`, `cacheDiskMaxGB`, `cacheMaxBlocks` (new fields)

**Note**: A server restart is **not** the right trigger for these — model
reload is. But we should still flag them for consistency with existing field
tracking.

**Better fix**: Introduce a separate `modelReloadNeeded` flag:
```swift
let modelReloadNeeded =
    previousServerCfg.genKVBits != configuration.genKVBits
    || previousServerCfg.genKVGroupSize != configuration.genKVGroupSize
    || previousServerCfg.genQuantizedKVStart != configuration.genQuantizedKVStart
    || previousServerCfg.genMaxKVSize != configuration.genMaxKVSize
    || previousServerCfg.genPrefillStepSize != configuration.genPrefillStepSize
    || previousServerCfg.genTurboQuant != configuration.genTurboQuant
    || previousServerCfg.cacheDiskEnabled != configuration.cacheDiskEnabled
    || previousServerCfg.cacheDiskMaxGB != configuration.cacheDiskMaxGB
    || previousServerCfg.cacheMaxBlocks != configuration.cacheMaxBlocks

// ... in the save Task:
if modelReloadNeeded {
    await ModelRuntime.shared.invalidateConfig()
    await ModelRuntime.shared.refreshCacheConfig()  // new method from A.1
}
```

Then `serverRestartNeeded` can stop including the gen* fields at all — none
of them actually require a NIO restart.

**Fix required**: Rewrite the change-detection logic to separate
`serverRestartNeeded` (port, CORS, exposeToNetwork) from `modelReloadNeeded`
(all gen* and cache*).

---

## B. Path correction — earlier doc had a wrong cache directory

### B.1 🟡 Disk cache is under `<root>/cache/kv_v2`, not `~/Library/Caches/`

The earlier doc (`VMLX-CACHE-INTEGRATION-GAPS.md`) referred to the disk cache
as `~/Library/Caches/ai.osaurus/kv_v2/`. **That's wrong.**

`OsaurusPaths.cache()` returns `root()/cache/` (verified in `Utils/OsaurusPaths.swift:100`).
The actual `root()` depends on osaurus's path resolution, which is typically
`~/.osaurus/` or a user-configured location.

So the real path is:
- Default: `~/.osaurus/cache/kv_v2/`
- Or whatever `OsaurusPaths.root()` resolves to + `/cache/kv_v2/`

**Action**:
- [ ] Fix the earlier doc's paths
- [ ] Use `OsaurusPaths.cache().appendingPathComponent("kv_v2", isDirectory: true)`
      in any helper code — no hard-coded paths.

---

## C. Cross-function interaction nuances

### C.1 🟢 VLM (image/video) path correctly bypasses cache

**Verified**: `vmlx-swift-lm` `TokenIterator.init` at `Evaluate.swift:682-684`:
```swift
if let coordinator = cacheCoordinator, !promptTokenIds.isEmpty,
   input.image == nil, input.video == nil,
   !hasRotatingCache {
    // attempt prefix fetch
}
```

The coordinator is only consulted for text-only inputs. VLM requests with
images/videos skip caching entirely, which is correct — caching cross-modal
inputs is non-trivial and not supported.

**Action**: None. Flag for awareness.

---

### C.2 🟢 RotatingKVCache (sliding window) models correctly bypass cache

**Verified**: same `TokenIterator.init` check — if any cache layer is
`RotatingKVCache`, the coordinator is skipped. This is because partial
restoration of a sliding-window cache has offset semantics that don't match
paged-cache assumptions.

**Affected models**: anything using sliding-window attention (e.g., Mistral,
some Gemma variants).

**Action**: None. These models will always full-prefill, losing the cache
benefit. That's acceptable — the alternative is silent correctness bugs.

---

### C.3 🟡 Model reload during active generation — race condition analysis

**Scenario**: User in window A is generating. User opens settings in window
B and changes cache bits. Save handler eventually calls
`ModelRuntime.shared.refreshCacheConfig()` (once we implement A.1).

**Race**:
1. Window A generation is mid-way through `TokenIterator.next()` on the
   CacheCoordinator.
2. `refreshCacheConfig()` calls `holder.container.disableCaching()`.
3. `disableCaching()` on the container sets `_cacheCoordinator = nil` under
   a `OSAllocatedUnfairLock`.
4. But the in-flight `TokenIterator` holds its own reference
   (`self.cacheCoordinator`) captured at init time, so the lock race doesn't
   affect it.
5. After generation, the iterator tries to call `coordinator.storeAfterGeneration()`.
   Its reference is still valid (the old coordinator is kept alive by ARC
   because of the iterator's strong reference). So the store goes to the
   **old** coordinator, which is no longer attached to the container.

**Consequence**: The generated cache is stored in a coordinator that nobody
reads from. Effectively, the cache write is lost. Not a correctness bug —
just wasted work.

**Mitigation**: `refreshCacheConfig()` should `cancelActiveGeneration()` first,
wait for the task to finish, THEN disable/re-enable caching. Since
`ModelRuntime` is an actor, if we await the cancel inside the actor-isolated
method, no new generation can start until we return.

**Action**:
- [ ] In `refreshCacheConfig()`, call `await cancelActiveGeneration()` before
      touching any container's `disableCaching()`.

---

### C.4 🟡 Concurrent generations on different sessions

**Scenario**: User has two chat windows open, both talking to the same model,
both generating concurrently.

**Pre-existing behavior**: `ModelContainer.perform` serializes access to the
underlying `ModelContext`. Only one generation can run at a time per container.
`activeGenerationTask` tracks only the most recently started task — earlier
tasks are still running but untracked.

**Impact of migration**: Unchanged. The CacheCoordinator handles concurrent
`fetch`/`storeAfterGeneration` via `OSAllocatedUnfairLock` internally. Both
sessions benefit from the shared paged cache (content-addressed — they share
cached tokens if prompts overlap).

**Subtle issue**: `cancelActiveGeneration()` only cancels the most recent task.
If two sessions are running and one closes, `invalidateSession()` is a no-op
anyway — so this isn't worse than before. Just documenting the pre-existing
shape.

**Action**: None, flag for awareness.

---

### C.5 🟡 Hybrid detection happens *after* `enableCaching` — brief window

**Where**: `ModelRuntime.loadContainer()` lines 247-254 on our branch:

```swift
holder.container.enableCaching(config: cacheConfig)

let isHybrid = await holder.container.perform { ctx -> Bool in
    let testCache = ctx.model.newCache(parameters: nil)
    return testCache.contains { $0 is MambaCache || $0 is ArraysCache }
}
holder.container.cacheCoordinator?.setHybrid(isHybrid)
```

**The window**: Between `enableCaching` and `setHybrid`, the `CacheCoordinator`
exists but with `_isHybrid == false` (default). If a generation is submitted
in that window, it won't fetch SSM companion states for hybrid models.

**Why it doesn't matter**:
- `loadContainer` is inside the `ModelRuntime` actor. No other actor-isolated
  call can run until `loadContainer` returns.
- The only way a generation could happen in this window is via direct
  container.perform from outside the actor, which nothing in the codebase does.
- `await holder.container.perform { ... }` is called inside the actor, but
  the `container.perform` is its own serial queue — not the actor. Still, the
  actor is awaiting this result, so no concurrent `generateEventStream` call
  can start.

**Action**: None, but add a comment explaining the ordering is intentional:

```swift
// Order matters: enableCaching first (coordinator exists but isHybrid=false),
// then detect hybrid layers, then set the flag. Safe because the actor's
// `loadContainer` hasn't returned yet — no generation can run.
```

---

### C.6 🟡 `enableCaching` → `setHybrid` on first *use*, not load

**Concern**: If a user saves a config with `cacheDiskEnabled = false`, then
later re-enables it via settings change, the `refreshCacheConfig()` flow (once
implemented per A.1) must re-run hybrid detection too.

**Why**: `disableCaching()` nils out the coordinator. `enableCaching()` creates
a new one with `_isHybrid = false`. If we don't re-run detection, hybrid
models lose their SSM companion cache silently.

**Action**:
- [ ] `refreshCacheConfig()` must re-run the full `enableCaching` + `setHybrid`
      sequence. Factor both into a single helper called from both `loadContainer`
      and `refreshCacheConfig`.

---

## D. API surface & request routing

### D.1 🟡 Non-MLX providers still receive `cacheHint` / `sessionId` / `staticPrefix`

**Flow**: `ChatEngine.streamChat()` at lines 50-59 builds `GenerationParameters`
with all three fields regardless of target service. Remote providers (Ollama,
OpenAI, etc.) and FoundationModelService receive them and ignore them.

**Impact**: None — they're optional fields, ignored silently. Pre-existing.

**Action**: None.

---

### D.2 🟡 `HTTPHandler` `computePrefixHash` is still called per request

**Where**: `Networking/HTTPHandler.swift:2478, 2631`

**Behavior**: Every chat completion (streaming and non-streaming) computes a
SHA-256 hash of system content + sorted tool names to populate `prefix_hash`
in the response. This runs regardless of whether the model is local or remote.

**Performance**: SHA-256 of a few KB of system prompt takes microseconds.
Not a concern.

**Semantic concern**: For **remote** providers, the returned `prefix_hash`
doesn't correspond to any actual cache. It's just a deterministic hash. If a
client resends it as `cache_hint`, we forward it to the remote provider which
ignores it. Harmless.

**Action**: None. Could add a warning in the API docs that `prefix_hash` only
has cache-control meaning for local MLX models, but this is trivia.

---

### D.3 🟡 `GenerationParameters.staticPrefix` field is dead weight

**Where**: `Services/Inference/ModelService.swift` line 28, set by
`HTTPHandler.swift:1328` and `PluginHostAPI.swift`.

**Original purpose**: Used by the old `buildPrefixCache()` background task to
know which static content to precompute a cache for. That task is gone.

**Current state**: Field is set, field is never read.

**Options**:
- **A**: Remove the field entirely (touches several files).
- **B**: Leave it alone for API stability.

**Recommendation**: **Leave it.** Removing is a separate cleanup PR. It has
zero runtime cost since it's just a String property.

---

## E. Error handling & lifecycle edges

### E.1 🟡 What if `CacheCoordinatorConfig` build fails silently?

**Current code** (loadContainer lines 228-247):
```swift
let serverCfg = await ServerConfigurationStore.load()
let diskCacheDir = OsaurusPaths.cache().appendingPathComponent("kv_v2", ...)
OsaurusPaths.ensureExistsSilent(diskCacheDir)   // silently ignores errors

var cacheConfig = CacheCoordinatorConfig()
cacheConfig.enableDiskCache = diskEnabled
cacheConfig.diskCacheDir = diskCacheDir
// ...
holder.container.enableCaching(config: cacheConfig)
```

**Risk**: If `ensureExistsSilent` fails (permissions, out-of-disk, symlinked
to nonexistent location), `diskCacheDir` won't exist but we still pass it to
`enableCaching`. `CacheCoordinator` → `DiskCache` will attempt to open
SQLite at that path and may throw, or silently operate on a bad state.

**What vmlx-swift-lm does**: Per the package audit, `DiskCache` is initialized
lazily — it opens SQLite on first use, not at init. If the dir doesn't exist,
the first `.store()` or `.fetch()` call fails. The coordinator continues
running with paged-cache-only.

**Impact**: Silent degradation — user thinks disk cache is working, it isn't.

**Fix**:
1. Log a warning if `ensureExistsSilent` returns failure (need to check if
   the helper even returns a bool).
2. Verify the directory is writable before passing to `enableCaching`.
3. If not writable, pass `enableDiskCache: false` and log.

**Action**:
- [ ] Update `loadContainer` to check directory writability, fall back to
      memory-only cache if unwritable, and log a warning.

---

### E.2 🟡 What if user externally deletes `kv_v2/` mid-session?

**Scenario**: User runs `rm -rf ~/.osaurus/cache/kv_v2/` while osaurus has a
model loaded with disk caching active.

**What happens**: CacheCoordinator's `DiskCache` has an open SQLite handle
pointing at the deleted file. Next `store` call fails with "disk I/O error"
or similar. The paged cache still works.

**Impact**: Disk cache silently becomes a no-op until next model reload.

**Mitigation**: Beyond our scope. This is file-system edge-case handling that
belongs in vmlx-swift-lm's `DiskCache`.

**Action**: None. Flag for awareness.

---

### E.3 🟡 `MetalGate` release on exception paths

**Where**: `ModelRuntime.generateEventStream()` lines ~310-328 on our branch

**Behavior**:
- `MetalGate.shared.enterGeneration()` is called before `prepareAndGenerate`.
- If `prepareAndGenerate` throws:
  - `InferenceProgressManager.shared.prefillDidFinishAsync()` is called.
  - `MetalGate.shared.exitGeneration()` is called.
  - Error is rethrown.
- If no throw: `gatedGenTask` ensures exit happens when `innerGenTask` completes.

**Gap**: What if `Task.isCancelled` is true between enter and await? The code
handles this at line ~295:
```swift
await MetalGate.shared.enterGeneration()
if Task.isCancelled {
    await MetalGate.shared.exitGeneration()
    throw CancellationError()
}
```

Good. But what if cancellation happens during `prepareAndGenerate`?
`prepareAndGenerate` itself runs inside `container.perform` which doesn't
respect cancellation cooperatively — it runs to completion. So the catch block
catches any error (including cancellation), releases the gate. Safe.

**Action**: None. Pattern is correct.

---

### E.4 🟡 `activeGenerationTask` only tracks one task

**Where**: `ModelRuntime.swift:61`

**Pre-existing behavior**: Only the most recently started generation is
tracked in `activeGenerationTask`. If two windows run generations concurrently,
the earlier task is unreferenced (but still held alive by the async stream
machinery).

**Impact**: `cancelActiveGeneration()` only cancels the most recent. Older
tasks continue until they complete naturally.

**Why it doesn't matter for the migration**: Container-level serialization
(via `container.perform`) ensures only one generation runs at a time per model
anyway. So "concurrent" generations are actually queued. The stale
`activeGenerationTask` reference just means cancellation might miss a queued
one.

**Action**: None. Pre-existing pattern.

---

## F. Defaults & UX tuning

### F.1 🟠 Default `maxCacheBlocks` ladder needs real-world validation

See §6.1 of the first gaps doc. Still needs benchmarking.

**Additional nuance**: The paged cache block size is `pagedBlockSize = 64`
tokens by default. For a Qwen2-7B model with 32 layers, 32 heads, head_dim 128,
fp16: each block stores `2 * 64 * 32 * 128 * 2 bytes = 1 MB per layer = 32 MB`
per block. So 1000 blocks = 32 GB. **Way too much** for a 16 GB Mac.

Wait, actually — paged cache typically shares layer data across blocks? Let me
not trust this back-of-envelope. Needs actual measurement on real hardware.

**Action**: Benchmark before shipping defaults.

---

### F.2 🟠 `pagedBlockSize` is not user-configurable

`CacheCoordinatorConfig.pagedBlockSize` has a default of 64 tokens. We don't
expose it in `ServerConfiguration` or the UI. Should we?

**Tradeoffs**:
- Smaller blocks: finer-grained prefix matching → better hit rate on similar
  prompts, higher overhead per block.
- Larger blocks: worse prefix matching, lower overhead.

**Recommendation**: Leave at 64 for now. Expose in "Advanced" only if benchmarks
show meaningful variation. Not P0/P1.

---

### F.3 🟠 TurboQuant default-on tradeoff

User asked for TurboQuant on by default for all users, motivated by benchmarking
experience.

**Caveats** (from vmlx-swift-lm README and our understanding):
- TurboQuant uses 3-bit encoding (Hadamard + Lloyd-Max + QJL). 4.7-5× memory
  compression for KV cache.
- Quality impact: vmlx documents "no meaningful regression" on standard
  benchmarks. But this is model-dependent.
- Runtime cost: encoding/decoding adds ~5-10% per-token latency (our estimate
  — not measured).
- Not supported on all models: some architectures (RotatingKVCache,
  RotatingQuantizedKVCache) may fall back.

**Decision needed**: Are we confident enough to ship TurboQuant as the default
for all users, or should the default remain "auto-enable on low RAM"?

**Options**:
- **A**: Keep `autoTurboQuant` returning `true` only when `headroom < 16 GB`
  (conservative, current behavior). Users with 32+ GB get uncompressed,
  hot-path-optimized KV cache.
- **B**: Default `true` always. Advanced users can disable.
- **C**: Default `true` for everything except specific model families known to
  not benefit (we'd need to maintain a blocklist).

**User explicitly asked for B.** Flag C as a future refinement if field reports
show quality regressions.

**Action**: Still P1 — change `autoTurboQuant` unconditionally to `true` and
update the UI badge logic accordingly.

---

### F.4 🟠 First-time user experience

**Scenario**: User installs osaurus, launches, loads a model, sends first message.

**What they get**:
1. Model loads → `enableCaching` runs with default config.
2. Disk cache enabled (default true), 4 GB cap.
3. Paged cache: 1000 blocks (or 2000 on ≥48 GB RAM).
4. TurboQuant: auto-enabled if headroom <16 GB (unless we change F.3).
5. First message: cache miss, full prefill, store to coordinator.
6. Second turn: cache hit on shared prefix, partial prefill.

**Gotchas**:
- On a 16 GB Mac with a 7 GB model → TurboQuant kicks in on turn 1.
- On a 64 GB Mac → no TurboQuant by default, 2000 blocks (potential RAM hog).
- First time `kv_v2/` is created — needs directory-write permission. Not an
  issue on standard macOS but sandboxed apps could hit this.

**Action**: Benchmark and validate the out-of-box experience on:
- 16 GB M1 with Qwen2-7B
- 32 GB M2 with Gemma-9B
- 64 GB M3 with Gemma-26B

---

## G. Persistence & cross-session behavior

### G.1 🟡 Disk cache survives app restart — is that what we want?

**Yes.** That's the whole point of L2. But edge cases:

- **Model was uninstalled between restarts**: The `modelKey` in the disk cache
  includes the model name. When the user reinstalls the same model, the cached
  KV state is reused automatically. Good.
- **Model was replaced with a different version under the same name**: Cache
  may have been computed against different tokenization or architecture.
  `modelKey` is just the name, not a content hash. **Silent correctness risk.**
- **User switches between quantized and unquantized variants of the same model**:
  They share a name but have different weights. Same risk.

**Mitigation options**:
- **A**: Use a hash of the model weights file(s) instead of just the name.
  Expensive to compute on every load.
- **B**: Include the model's config hash (tokenizer + architecture) in `modelKey`.
  Cheap, catches most cases.
- **C**: Store a sentinel file in the cache dir with the model metadata; verify
  on first load and invalidate if mismatched.
- **D**: Accept the risk and document it. If users report issues, add mitigation.

**Recommendation**: Start with **D** (accept the risk), monitor. Upgrade to **B**
if we hit problems.

**Action**: Add a release note: "The disk KV cache is keyed by model name. If
you swap a model file under the same name, clear the cache via Settings →
Local Inference → Cache Storage to prevent incorrect results."

---

### G.2 🟡 What happens if two osaurus instances share the disk cache?

**Scenario**: User has osaurus installed twice (e.g., dev build + prod), both
pointing to the same `~/.osaurus/cache/kv_v2/`.

**Risk**: SQLite handles concurrent access via file locking, but if both
instances open the same DB, writes from one can confuse the other. Rare but
possible.

**Mitigation**: Use a per-instance subdirectory (e.g., include `Bundle.main.bundleIdentifier`
in the path). Or use `OsaurusPaths.root()` which should already vary per
instance if configured correctly.

**Action**: Check what `OsaurusPaths.root()` returns — if it's shared between
dev/prod builds, fix it. Otherwise, ignore.

---

## H. Test coverage gaps found during second pass

### H.1 🟠 No integration test for model reload with changed cache config

Once we implement A.1 (`refreshCacheConfig()`), we need:
1. Load a model.
2. Change `cacheDiskEnabled = false` in settings.
3. Save.
4. Verify `holder.container.cacheCoordinator?.config.enableDiskCache == false`.
5. Submit a generation.
6. Verify no new entries written to the disk cache dir.

**Action**: Add integration test (needs model fixtures — hard).

---

### H.2 🟠 No test for the actor isolation of `refreshCacheConfig`

**When implementing A.1**, verify:
1. A generation is running.
2. `refreshCacheConfig()` is called.
3. The generation completes before any container touches happen.
4. The new coordinator is in place before the next generation starts.

**Action**: Add unit test that uses a mock `ModelContainer` and verifies the
sequence.

---

### H.3 🟡 The `ModelRuntime.self is any Actor.Type` test is a minimal tautology

**Where**: `Tests/Model/ModelRuntimePrefixTests.swift:23`

**Verified**: compiles with a warning (`'is' test is always true`) but correctly
returns `false` if `ModelRuntime` stops being declared `actor`. Valid but weak.

**Alternative test**: Verify actor isolation by calling two methods that would
race if not isolated. Hard to write without real work.

**Action**: Keep as-is.

---

## I. Documentation nuances

### I.1 🟠 Earlier "Clear All" button proposal needs to be atomic

See first-pass doc §4.1. The second-pass nuance: if we expand "Clear All" to
wipe everything, it must:
1. Cancel all active generations first.
2. Unload all models.
3. Delete disk cache files.
4. Invalidate preflight, memory, and UI caches.
5. All under an `isClearing` flag so the user can't trigger it twice.

Otherwise, cancelling a generation mid-clear leaves partial state.

**Action**: Already covered in first-pass doc §4.1. Flag here for atomicity.

---

### I.2 🟡 API docs currently describe `session_id` as meaningful

**Where**: `docs/OpenAI_API_GUIDE.md` lines 244-266

**First-pass doc §9.1** already flags this for rewrite. Second-pass addition:
be careful to distinguish between "osaurus still accepts `session_id`" and
"osaurus uses `session_id` for cache lookup". The API field still has
semantic meaning for the user's frontend (session tracking), just not for the
KV cache.

---

## J. Pre-existing bugs the migration exposes but didn't create

These aren't introduced by our work, but they now matter more.

### J.1 `invalidateConfig()` is dead code

See A.1. Pre-existing since at least the introduction of `ServerConfiguration`
gen* fields.

### J.2 `serverRestartNeeded` missing `genTurboQuant`

See A.3. Pre-existing since TurboQuant was added.

### J.3 `restartServer()` doesn't touch `ModelRuntime`

See A.1. Pre-existing — the coupling was never wired.

### J.4 `resetToDefaults()` isn't in sync with `ServerConfiguration.default`

Pre-existing. We added fields; reset didn't. Every time a new gen* field is
added, reset must be updated manually. Consider driving reset from the
default struct automatically (reflection-based or a shared init).

**Action**: Create a follow-up ticket to refactor `resetToDefaults()` to
consume `ServerConfiguration.default` directly.

---

## K. Summary of second-pass findings

| ID | Severity | Summary |
|----|----------|---------|
| A.1 | 🔴 P0 | Settings changes don't propagate to loaded models. Three compounding bugs: dead `invalidateConfig()`, incomplete `serverRestartNeeded`, restart doesn't touch ModelRuntime |
| A.2 | 🟠 P1 | `resetToDefaults()` doesn't reset new cache fields |
| A.3 | 🟠 P1 | `serverRestartNeeded` flag needs a sibling `modelReloadNeeded` flag |
| B.1 | 🟡 P2 | Disk cache path is `<root>/cache/kv_v2`, not `~/Library/Caches/` (doc correction) |
| C.1 | 🟢 | VLM path correctly bypasses cache (no action) |
| C.2 | 🟢 | RotatingKVCache models correctly bypass cache (no action) |
| C.3 | 🟡 P2 | Race: reload during active gen could orphan a cache write |
| C.4 | 🟡 | Pre-existing: `activeGenerationTask` tracks only one task |
| C.5 | 🟡 P2 | Hybrid detection after `enableCaching` has a brief safe window (add comment) |
| C.6 | 🟠 P1 | `refreshCacheConfig()` must re-run hybrid detection (factor helper) |
| D.1 | 🟡 | Non-MLX services ignore `cacheHint`/`sessionId` (pre-existing, fine) |
| D.2 | 🟡 | `prefix_hash` returned for remote models is meaningless (fine, doc it) |
| D.3 | 🟡 | `GenerationParameters.staticPrefix` is dead weight (leave it) |
| E.1 | 🟠 P1 | Disk cache silent degradation if dir creation fails |
| E.2 | 🟡 | External dir deletion mid-session breaks disk cache (not our scope) |
| E.3 | 🟢 | MetalGate error paths are correct |
| E.4 | 🟡 | Pre-existing: `activeGenerationTask` single-task tracking |
| F.1 | 🟠 P1 | Default `maxCacheBlocks` needs real benchmarking |
| F.2 | 🟡 | `pagedBlockSize` not user-configurable (acceptable) |
| F.3 | 🟠 P1 | Confirm TurboQuant default-on is the right call |
| F.4 | 🟠 P1 | First-time UX needs validation on 16/32/64 GB Macs |
| G.1 | 🟡 P2 | Disk cache keyed by model name — swapping files under the same name can corrupt results |
| G.2 | 🟡 P2 | Two osaurus instances can contend on the same disk cache path |
| H.1 | 🟠 P1 | Need integration test for `refreshCacheConfig()` |
| H.2 | 🟠 P1 | Need actor-isolation test for `refreshCacheConfig()` |
| H.3 | 🟡 | Existing actor test is a tautology, but acceptable |
| I.1 | 🟠 P1 | "Clear All" button must be atomic (see first-pass §4.1) |
| I.2 | 🟡 | API docs need careful wording about `session_id` |
| J.1 | 🟡 | Pre-existing: `invalidateConfig()` dead code |
| J.2 | 🟡 | Pre-existing: `serverRestartNeeded` missing `genTurboQuant` |
| J.3 | 🟡 | Pre-existing: restart doesn't touch runtime |
| J.4 | 🟡 | Pre-existing: `resetToDefaults()` out of sync with defaults struct |

---

## L. Updated priority execution order

Merging the first-pass and second-pass priorities:

### Phase 1 — Unblock building & minimal hot-reload (P0)
1. Commit the `swift-transformers 0.1.21` version fix (first-pass §1.1)
2. Verify branch builds in Xcode
3. Implement `ModelRuntime.refreshCacheConfig()` with `cancelActiveGeneration` first (second-pass A.1, C.3, C.6)
4. Factor `buildCacheCoordinatorConfig()` helper used by both load and refresh
5. Wire `ConfigurationView.saveConfiguration()` → `ModelRuntime.refreshCacheConfig()` on any gen*/cache* field change

### Phase 2 — Correctness & UX of defaults (P1)
6. Benchmark `maxCacheBlocks` defaults on 16/32/64 GB Macs (second-pass F.1, F.4)
7. Flip `autoTurboQuant` to unconditional `true` (first-pass §6.2, second-pass F.3)
8. Fix `resetToDefaults()` to include new cache fields (second-pass A.2)
9. Fix `serverRestartNeeded` → split into `serverRestartNeeded` + `modelReloadNeeded` (second-pass A.3)
10. Add error handling for disk cache dir write failure (second-pass E.1)

### Phase 3 — UI affordances (P1)
11. Expand/rewrite "Clear All" button (first-pass §4.1, second-pass I.1)
12. Add disk cache size visibility (first-pass §4.2)
13. Add "Reset to defaults" for Cache Storage (first-pass §7.2)
14. Add "Changes take effect on next model load" footer (first-pass §7.3) —
    OR remove this if Phase 1 lands (hot-reload works)

### Phase 4 — Docs & tests (P1)
15. Rewrite `docs/OpenAI_API_GUIDE.md` session/prefix sections (first-pass §9.1, second-pass I.2)
16. Add integration test for `refreshCacheConfig()` (second-pass H.1)
17. Add round-trip test for new `ServerConfiguration` cache fields (first-pass §10.2)
18. CHANGELOG entry (first-pass §9.2)

### Phase 5 — P2 cleanup (non-blocking)
19. Invalidate `MemoryContextAssembler` on session close (first-pass §2.2)
20. Add session close cleanup for `ChatWindowManager` (first-pass §2.2)
21. Document race caveat for disk cache externally deleted (second-pass E.2)
22. Add comment to `loadContainer` explaining enableCaching → setHybrid ordering (second-pass C.5)
23. Fix doc paths in first-pass doc (second-pass B.1)
24. Regenerate `Package.resolved` post-Xcode-open (first-pass §1.2)

### Phase 6 — Optional / future
25. Consider model-content-hash in `modelKey` (second-pass G.1)
26. Expose `pagedBlockSize` setting (second-pass F.2)
27. Cache hit rate metric UI (first-pass §8.2)
28. Refactor `resetToDefaults()` to consume `ServerConfiguration.default` automatically (second-pass J.4)

---

## N. Cache surfaces inherited from pre-migration osaurus

The user asked: are there pre-existing prefix / paged / window / cache implementations
in osaurus beyond `KVCacheStore` that we haven't addressed? This section catalogs
every surface I found that carries cache semantics and what should happen to each.

### N.1 Prefix cache hashing — two parallel implementations

There are **two different `prefixHash` functions** computing different things:

**Implementation 1**: `ModelRuntime.computePrefixHash(systemContent:, toolNames:)`
- Hashes the raw system message content + sorted tool names
- Called by `HTTPHandler.swift:2475-2478` and `2631` to populate API response `prefix_hash` field
- Called by `Models/Chat/ResponseWriters.swift:20, 65, 300` to thread the hash into streaming chunks
- Kept for API compatibility (so clients that store the hash and resend as `cache_hint` don't break)

**Implementation 2**: `PromptManifest.staticPrefixHash(toolNames:)` (at `PromptManifest.swift:102-107`)
- Hashes `staticPrefixContent` — which is the concatenation of sections marked
  `cacheability == .static`, not the raw system message
- Used by `SystemPromptComposer.swift:133` to populate `ComposedContext.cacheHint`
- Flows into `GenerationParameters.cacheHint` via the dispatch pipeline

**The two hashes are different!** A client that takes the `prefix_hash` from a
response (implementation 1) and resends it as `cache_hint` will NOT match the
`cacheHint` that `SystemPromptComposer` would compute (implementation 2). Even
when the old KVCacheStore was alive, these wouldn't collide.

**Severity**: 🟡 P2. Pre-existing confusion. Not introduced by migration.

**Options**:
- **A**: Unify both into one hash function. Requires API changes.
- **B**: Deprecate both and stop populating them. API-breaking.
- **C**: Leave alone. Neither actually affects cache behavior anymore — both are
  just metadata that flows through the pipeline.

**Recommendation**: **C** for now. Document the oddity. Flag for deprecation in a
future major version.

---

### N.2 `PromptSection.Cacheability` enum is now decorative

**Where**: `Services/Chat/PromptManifest.swift:23-28`

```swift
public enum Cacheability: String, Sendable {
    /// Stable across requests — safe for prefix cache reuse.
    case `static`
    /// Changes per request (memory, RAG, skills).
    case dynamic
}
```

**Original purpose**: Drive the old prefix-cache build path. `buildPrefixCache()`
used `staticPrefixContent` (sections with `.static`) as the warm-up input.

**Current purpose**: Only used to compute `staticPrefixContent` and
`staticPrefixHash`, which feed into `cacheHint`/`staticPrefix` — which are ignored
by the new CacheCoordinator.

**Effect**: The classification logic still runs on every request (cheap but wasted).

**Severity**: 🟡 P2. Pre-existing infrastructure, harmless.

**Action**: Keep for debugging observability (the manifest is displayed in debug
UI somewhere — verify). Do not remove unless we're sure nothing renders it.

---

### N.3 `GenerationParameters.cacheHint` is dead weight

**Where**: `Services/Inference/ModelService.swift:21-23`

```swift
/// Explicit prefix cache key override (API callers can use this to share a
/// prefix cache across requests with varying system prompts).
let cacheHint: String?
```

**Set by**:
- `ChatEngine.streamChat()` from `request.cache_hint`
- `PluginHostAPI.swift` sets it on enriched plugin-dispatched requests
- `SystemPromptComposer.composeForOpenAI()` returns it for callers to set

**Read by**: Nothing in the MLX cache path. Also ignored by remote/foundation services.

**Severity**: 🟡 P2.

**Action**: Leave in place for API backwards compat. Remove in a future cleanup PR.

---

### N.4 `GenerationParameters.sessionId` — identifier lost its primary role

**Where**: `Services/Inference/ModelService.swift:20`

**Original purpose**: Key into `KVCacheStore` for per-session cache reuse.

**Current purpose**: Still flows through the whole pipeline. Used by:
- `ChatWindowManager` for window-to-session mapping
- `PluginHostContext` for preflight cache invalidation on window close
- HTTP API for client-side session tracking
- Possibly logged/observed for debugging

**What's gone**: The KV cache lookup by `sessionId`. CacheCoordinator is
content-addressed.

**Effect**: `sessionId` is now a pure identifier, not a cache key. Semantically
clean, just historically loaded with cache meaning.

**Severity**: 🟡. Keep as-is.

---

### N.5 `ContextBudgetManager` — message-level "windowing" (NOT a KV cache)

**Where**: `Services/Chat/ContextBudgetManager.swift`

**What it does**: Trims old messages from the conversation history to keep the
prompt within the model's context window. This is content-level windowing, not
KV-level sliding window.

**Relationship to cache**: Orthogonal. The trimmed prompt still goes through
CacheCoordinator, and partial prefix matching will still work for stable parts
(system prompt, recent turns). Aggressive trimming at the start of the history
may cause cache misses if the "floor" of the context moves across requests.

**Severity**: 🟢 none.

**Action**: None. This layer is correct and should stay.

**Nuance**: A user tuning context length may unintentionally evict cache hits.
Worth documenting in the settings UI ("lowering context length may reduce KV
cache reuse").

---

### N.6 `vmlx` sliding-window (`RotatingKVCache`) — handled at package level

**Where**: `vmlx-swift-lm/Libraries/MLXLMCommon/Evaluate.swift:681-684`

**What it does**: When a model has any `RotatingKVCache` layer, `TokenIterator.init`
explicitly skips `CacheCoordinator.fetch()`. The model falls back to full prefill
on every request.

**Why**: Partial restoration of a sliding-window cache has offset-vs-window-size
semantics that don't match paged-cache assumptions. Would silently corrupt results.

**Affected models**: Mistral 7B with sliding window, some older Gemma variants.

**Severity**: 🟡 P2. Known limitation of the package.

**Action**:
- Verify this doesn't silently degrade perceived performance for Mistral users.
- Consider a Settings footer "Sliding-window models (Mistral 7B, etc.) don't
  benefit from prefix caching."

---

### N.7 Preflight cache in `PluginHostContext` — still session-keyed

**Where**: `Services/Plugin/PluginHostContext.swift` (referenced by `PluginHostAPI.swift`)

**What it caches**: `PreflightResult` (matched tools + context snippets) per
`sessionId`.

**Why session-keyed**: The preflight process determines which tools and
skill-retrieval snippets go into the prompt. Stable per session so the KV cache
(prefix) sees a stable tool list across turns, preserving prefix cache hit rate.

**Interaction with new CacheCoordinator**:
- The preflight result shapes the prompt's tool-list section.
- Stable tools → stable prompt prefix → CacheCoordinator's content-addressed
  match works naturally.
- If tools changed between turns → prefix diverges → cache miss on the tool
  section, but the earlier (system) tokens still hit.

**Severity**: 🟢 none.

**Action**: None. The preflight cache is still correct and beneficial.

---

### N.8 `SystemPromptComposer.ComposedContext` — per-view cache of prompt assembly

**Where**: `Views/Chat/ChatView.swift:52` holds `ComposedContext?`

**What it caches**: The rendered prompt string + manifest + tools + budget +
`cacheHint` + `staticPrefix`. One per chat window.

**Invalidation triggers** (from earlier audit): tool changes, agent changes,
memory updates, budget reset.

**Why it matters**: Avoids re-running `SystemPromptComposer` (which does tool
resolution, skill retrieval, memory assembly) on every keystroke in the
composer UI.

**Not a KV cache**: Purely prompt assembly memoization.

**Severity**: 🟢 none.

**Action**: None.

---

### N.9 `ChatCompletionRequest.staticPrefix` — "not serialized to JSON"

**Where**: `Models/API/OpenAIAPI.swift:360-361`

```swift
/// Static system prompt content for prefix cache building (not serialized to JSON).
var staticPrefix: String? = nil
```

**What it is**: An internal field used to pass the static-prefix content from
`SystemPromptComposer` → `ChatEngine` → `GenerationParameters` without routing
it through HTTP JSON. The HTTP client can't set it.

**Who sets it**: `HTTPHandler.swift:1328` (from enriched request), `PluginHostAPI.swift`
(from plugin context).

**Who reads it**: Nothing in the active code path. `MLXGenerationEngine`
doesn't consult it.

**Severity**: 🟡 P2.

**Action**: Leave alone. Remove in a future cleanup.

---

### N.10 `SystemPromptComposer.composeForOpenAI()` — still returns cache tuple

**Where**: `Services/Chat/SystemPromptComposer.swift:247-263`

```swift
/// Returns `(cacheHint, staticPrefix)` for the caller to set on the request.
static func composeForOpenAI(...) async -> (cacheHint: String, staticPrefix: String) {
    ...
    return (manifest.staticPrefixHash(toolNames: []), manifest.staticPrefixContent)
}
```

**Who calls it**: `PluginHostAPI.swift` when dispatching plugin inference.

**Effect**: The returned values flow to `ChatCompletionRequest.cache_hint` /
`.staticPrefix`, which nothing reads in the MLX cache path.

**Severity**: 🟡 P2.

**Action**: Leave alone.

---

### N.11 Sliding message history in memory — cache-relevant for hit rate tuning

**Where**: `ContextBudgetManager` trims messages to fit context window; older
messages may fall off the end.

**Effect on cache**: When a trimmed message drops out, the prompt's token sequence
at that position changes. CacheCoordinator will cache-miss on subsequent blocks.

**Nuance**: This can cause a **thrashing pattern** where:
- Turn N: history fits, cache hits on system + history.
- Turn N+1: history overflows, earliest user turn trimmed.
- Now the "middle" of the token sequence changes → cache miss on everything
  after the trim point.
- Each subsequent turn re-trims → each turn loses cache reuse.

**Mitigation options**:
- **Token-budget-aware trimming**: Trim in chunks that align with block boundaries
  (64 tokens). Would need CacheCoordinator's `pagedBlockSize` to match.
- **Summarization**: Replace trimmed turns with a summary (this might already
  happen — check `ContextBudgetManager` for summarization logic).
- **Accept the tradeoff**: Users with ultra-long conversations pay a re-prefill
  cost on each new turn beyond the window. Document it.

**Severity**: 🟠 P1. Real perf impact on long conversations.

**Action**:
- [ ] Check if `ContextBudgetManager` already summarizes or just trims.
- [ ] If it just trims, consider whether block-aligned trimming is worth
      implementing.
- [ ] Document the tradeoff in release notes.

---

### N.12 `BlockMemoizer` — name collision with CacheCoordinator's "blocks"

**Where**: `Managers/BlockMemoizer.swift`

**What it is**: A UI memoization layer for rendered `[ContentBlock]` arrays (chat
messages). Nothing to do with KV cache blocks.

**Why flag it**: The name "Block" is overloaded. In our new architecture:
- `BlockMemoizer` = UI rendering blocks
- `CacheBlock` / `PagedCacheManager.block` = KV cache blocks (64 tokens)

**Severity**: 🟡 P2. Potential confusion for future developers reading both.

**Action**: None. Document in code comments if we touch either file.

---

### N.13 Potential cache surfaces we haven't verified

A grep for `cache` in osaurus source returned 17 files. Most are:
- UI rendering caches (ThreadCache, BlockMemoizer, ChatImageCache) — orthogonal
- `SelectableTextView` font cache — orthogonal
- `LaTeXRenderer` math cache — orthogonal
- `ModelPickerItemCache` — orthogonal
- `RemoteProviderManager` model-list cache — orthogonal
- `MemoryContextAssembler` 10s TTL — orthogonal

**Two I haven't specifically verified**:
- `Views/Chat/SelectableTextView.swift` mentions cache in some context
- `Views/Work/WorkSession.swift` and `WorkExecutionEngine.swift` — do they
  have their own cache layer?

**Action**:
- [ ] Quick grep of those files to confirm they're not KV-adjacent.

---

## O. The "enabled by default" mandate — what to enable

User instruction: "we will make it all enabled or not but just by default enabled".

Mapping current defaults after migration:

| Cache feature | Default | Where controlled | Notes |
|--------------|---------|------------------|-------|
| L1 paged cache | ✅ ON | `CacheCoordinatorConfig.usePagedCache = true` | Not currently exposed as a user setting |
| L2 disk cache | ✅ ON | `cacheDiskEnabled ?? true` in ServerConfig | Exposed in Settings → Cache Storage |
| SSM companion cache | ✅ AUTO | `setHybrid(isHybrid)` via detection | Auto-detected at load; cannot be manually forced off |
| TurboQuant compression | ⚠️ CONDITIONAL | `autoTurboQuant()` checks headroom | **User wants unconditional ON** (see first-pass §6.2) |
| KV quantization (int8) | ⚠️ CONDITIONAL | `autoKVBits()` checks headroom | Kept conditional — don't want to double-compress with TurboQuant |
| Prefix matching | ✅ ON (implicit) | CacheCoordinator always hashes | No separate toggle |
| Preflight cache (tools) | ✅ ON | `PluginHostAPI` always uses it | Per-session, auto |
| `ComposedContext` memoization | ✅ ON | Per-ChatView | Auto |
| UI caches (Thread/Block/Image/LaTeX) | ✅ ON | Global NSCaches | Auto |
| Model weights caching | ✅ ON | `ModelRuntime.modelCache` dict | Kept via `modelEvictionPolicy` |

### O.1 🟠 P1 — Decision: one master toggle or separate toggles?

**Option A — Single "Enable KV Caching" master toggle**
- One setting: on/off
- When off: disable L1 + L2 + SSM + TurboQuant + prefix matching all at once
- Simpler for users
- Requires exposing `usePagedCache` in `ServerConfiguration`

**Option B — Separate toggles for each tier**
- L2 Disk toggle (we have this)
- L1 Memory blocks limit (we have this)
- TurboQuant toggle (we have this)
- KV Quantization (we have this)
- More power, more confusion

**Option C — Hybrid**
- Master toggle: "KV Caching" (on by default)
- Advanced subsection: the individual toggles
- Disabling the master disables everything regardless of sub-toggles

**User request**: "all enabled or not but just by default enabled"

**Interpretation**: Either A or C — some notion of a blanket on/off.

**Recommendation**: **Option C**. Add a top-level `cacheEnabled: Bool? = nil`
(default true) to `ServerConfiguration`. In `loadContainer`, if `cacheEnabled`
is `false`, skip `enableCaching()` entirely. Sub-settings remain for power users.

**Action**:
- [ ] Add `cacheEnabled` field to `ServerConfiguration`
- [ ] Gate the `enableCaching` call in `loadContainer` on this flag
- [ ] Add a master toggle above the Cache Storage subsection in the Settings UI
- [ ] When master is off, visually gray out the sub-settings (or collapse them)
- [ ] Update `resetToDefaults()` to set it back to `nil`/true

---

### O.2 🟠 P1 — TurboQuant default must become unconditional

Confirmed redundant with first-pass §6.2, second-pass F.3.

**Action**:
- [ ] Change `RuntimeConfig.autoTurboQuant()` to return `true` unconditionally
- [ ] Update the badge in `ConfigurationView` to reflect always-auto-enabled

---

### O.3 🟡 P2 — `usePagedCache` not currently user-configurable

**Where**: `CacheCoordinatorConfig.usePagedCache` defaults to `true` in the
package. We never set it explicitly in osaurus's `loadContainer`.

**Impact**: There's no osaurus-level way to turn off the paged cache while
keeping the disk cache, or vice versa. For debugging, you'd have to disable
both via `cacheEnabled = false`.

**Decision**: Don't expose. Users don't need to pick between L1/L2.

**Action**: None.

---

### O.4 🟡 P2 — Validate the "enable all" invariant

Once the master toggle is implemented, verify:

1. `cacheEnabled = true` (default):
   - L1 + L2 + SSM + prefix + TurboQuant all on
   - Hit rate: measurable via `prepareAndGenerate` log output
2. `cacheEnabled = false`:
   - `container.cacheCoordinator == nil`
   - `TokenIterator` falls back to full prefill every request
   - Existing disk cache files are NOT deleted (just not consulted)
3. Toggle on → off → on round trip:
   - No state leak between runs
   - Disk cache files from the previous "on" period are still valid and
     reusable when re-enabled

**Action**:
- [ ] Write integration tests for these three scenarios

---

## M. What this doc doesn't cover

To be clear about the scope of these two passes:

- **Performance benchmarking**: We've flagged needs, but haven't measured anything.
- **Quality regression testing for TurboQuant**: Flagged but not done.
- **Stress testing**: Concurrent sessions, long conversations, OOM behavior.
- **Real-world edge cases**: Only discovered by beta users.
- **vmlx-swift-lm internal details**: We trust the package — haven't audited its
  CacheCoordinator implementation for lock correctness, atomic SQLite writes,
  signal safety, etc.

These are all legitimate concerns for a production release. They belong in a
separate QA plan, not this integration document.
