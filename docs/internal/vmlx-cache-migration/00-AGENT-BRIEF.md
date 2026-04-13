# Agent Brief — vmlx Cache Migration Review

> This document is designed to be fed directly to a review agent (Claude,
> GPT, etc.) as context for an extensive audit. It structures the review
> into bounded tasks so no part of the migration is skipped.
>
> **If you are a human**: read `01-README.md` instead. This file is
> machine-oriented.
>
> **If you are an agent**: execute every task in every section below.
> Produce a single structured report at the end. Do not abbreviate.

---

## Package hosting context

The code references `https://github.com/osaurus-ai/vmlx-swift-lm` branch
`main`. This is the **development-time URL**. In production, the package
will be hosted at the public osaurus mlx-swift-lm repo URL (either the
current `osaurus-ai/mlx-swift-lm` rebased/replaced in place, or a renamed
successor).

When reviewing any `Package.swift` reference to `vmlx-swift-lm`, treat it
as a stand-in for the eventual production URL. Flag — but do not fix —
any hardcoded references to the dev URL that would need updating at
release time. Those live in:
- `Packages/OsaurusCore/Package.swift` (line 17)

Nothing else in osaurus should contain that URL string. Verify that claim
with a grep.

---

## Entry points — read these first in order

1. **`01-README.md`** — human orientation + decision register + open concerns
2. **`02-GAPS.md`** — first-pass gap analysis (sections §1 through §11)
3. **`03-CONSIDERATIONS.md`** — second-pass nuances (sections A–O)
4. **`04-CHANGE-AUDIT.md`** — C-001 through C-013, per-change audit

Each of the four docs is self-contained but there are cross-references
between them. Follow them. When an audit entry says "see CONSIDERATIONS
§C.3", go read that section.

---

## Review tasks — execute all of them

### Task group A: Per-change code audit

For each change in `04-CHANGE-AUDIT.md` (C-001 through C-013), produce:

1. **Change ID and title**
2. **Verification status**: `VERIFIED` / `FAILED` / `NEEDS_HUMAN`
3. **Did the diff actually land?** — check the file at the stated line range,
   confirm the before/after in the audit entry matches the current branch state.
4. **Are the "Audit focus" bullets satisfied?** — each bullet is a specific
   check. Mark each as pass/fail/skipped with one sentence of justification.
5. **Cross-reference check** — if the change says "Depends on C-XYZ", verify
   C-XYZ landed before it and the ordering makes sense.

### Task group B: Concurrency invariants

These are load-bearing for correctness. Check each one against the current
branch state:

1. **`refreshCacheConfig` must cancel active generation first**
   - Location: `ModelRuntime.swift` — `refreshCacheConfig()` method
   - Verify: first line is `await cancelActiveGeneration()`
   - Why it matters: in-flight `TokenIterator` holds a strong reference to
     the old coordinator. If we swap coordinators while it's running, its
     post-gen `storeAfterGeneration` call writes to an orphaned coordinator
     (harmless but wasted).

2. **`refreshCacheConfig` must snapshot `modelCache.values` before iterating**
   - Verify: `let holders = Array(modelCache.values)` before the loop
   - Why it matters: concurrent `unload(name:)` mutates `modelCache`. Live
     iteration while mutating is undefined behavior.

3. **`refreshCacheConfig` must NOT explicitly call `disableCaching` before
   `installCacheCoordinator`**
   - Verify: the loop body is a single `await installCacheCoordinator(...)`
     with no pre-disable.
   - Why it matters: `enableCaching(config:)` atomically swaps the coordinator
     under an unfair lock. An explicit pre-disable creates a nil-coordinator
     window during which a queued generation could silently skip caching.

4. **`installCacheCoordinator` ordering: `enableCaching` → `setHybrid`**
   - Verify: these calls are in this exact order, and both happen on the same
     holder within the same actor-isolated call.
   - Why it matters: `setHybrid` has to run on the new coordinator, not a
     stale reference.

5. **Hybrid detection happens inside `container.perform`**
   - Verify: `installCacheCoordinator` uses `await holder.container.perform { ctx -> Bool in ... }` to probe the model
   - Why it matters: `ctx.model.newCache()` must run on the container's
     serial queue or it races with active generations.

6. **`buildCacheCoordinatorConfig` is `nonisolated static`**
   - Verify: the method has both `nonisolated` and `static` modifiers.
   - Why it matters: it must be callable from the non-actor-isolated code
     path inside `installCacheCoordinator` without extra awaits.

7. **`isDirectoryWritable` uses a UUID-suffixed probe file**
   - Verify: the probe path is `url.appendingPathComponent(".osaurus_write_probe_\(UUID().uuidString)")`
   - Why it matters: two model loads running concurrently must not collide
     on probe files.

8. **`MetalGate` enter/exit balance**
   - Verify: every `await MetalGate.shared.enterGeneration()` in
     `generateEventStream` is matched by `await MetalGate.shared.exitGeneration()`
     on every error path.
   - Why it matters: a leaked gate deadlocks all future generations.

9. **`ChatWindowManager.closeWindow` Task ordering**
   - Verify: the inner Task captures `closedSessionId` AND `closedAgentId`
     before `windows.removeValue(forKey: id)` (if the removal happens).
   - Why it matters: if `windows` is mutated before the capture, the Task
     body reads stale state.

### Task group C: Settings propagation flow

Trace the full path from a user saving a settings change to the runtime
honoring it. Verify each step:

1. User toggles in `ConfigurationView` → a `@State` var updates
2. User clicks Save → `saveConfiguration()` runs
3. `saveConfiguration()` builds a new `ServerConfiguration` from state vars
4. `ServerConfigurationStore.save(configuration)` persists to disk
5. `modelReloadNeeded` is computed from `previousServerCfg != configuration`
   for gen* + cache* fields
6. If `modelReloadNeeded`, the `Task { @MainActor }` block calls
   `ModelRuntime.shared.refreshCacheConfig()`
7. `refreshCacheConfig` reads a fresh `ServerConfiguration` via
   `ServerConfigurationStore.load()`
8. For each loaded container, `installCacheCoordinator` re-runs
9. The coordinator is atomically replaced; next generation sees new config

**Verify every hop.** In particular:
- [ ] The new fields (`cacheEnabled`, `cacheDiskEnabled`, `cacheDiskMaxGB`,
      `cacheMaxBlocks`) are in `modelReloadNeeded`
- [ ] `genTurboQuant` is now in `modelReloadNeeded` (pre-existing bug fix)
- [ ] None of the new fields are ALSO in `serverRestartNeeded` (they
      shouldn't trigger a NIO restart)
- [ ] `invalidateConfig()` dead code is not called from anywhere — but
      `refreshCacheConfig()` does the job instead

### Task group D: API compatibility surface

The migration deliberately preserves several API-level fields that no
longer affect caching but still flow through the pipeline. Verify each
one is still wired correctly:

1. `ChatCompletionRequest.cache_hint` — HTTP decoder accepts it, flows to
   `GenerationParameters.cacheHint`, passed to service, ignored by MLX path.
2. `ChatCompletionRequest.session_id` — same flow, ignored by MLX path.
3. `ChatCompletionResponse.prefix_hash` — populated by `HTTPHandler` via
   `ModelRuntime.computePrefixHash(systemContent:, toolNames:)`.
4. `StreamChoice.prefix_hash` — populated in the first streaming chunk.
5. `PromptManifest.staticPrefixHash(toolNames:)` — still computed per
   request, flows to `ComposedContext.cacheHint` / `.staticPrefix`, never
   read by the MLX cache path.
6. `GenerationParameters.staticPrefix` — field exists, set by callers,
   never read.

For each: confirm that removing any of them would break API compat and
document which external clients would be affected. Do NOT remove them.

### Task group E: Test coverage

Verify the following tests exist and compile:

1. `ServerConfigurationStoreTests` — 5 new tests from C-013:
   - `cacheFields_missingInJSON_decodeAsNil`
   - `cacheFields_fullRoundTrip_preservesExplicitValues`
   - `cacheFields_explicitTrueRoundTrip`
   - `cacheFields_mixedNilAndExplicit`
   - `cacheFields_partialJSON_onlyDecodedFields`

2. `ModelRuntimePrefixTests` — should still have `modelRuntimeIsAnActor()`
   (unchanged from migration).

3. `PrefixHashTests` — should be unchanged, exercising
   `ModelRuntime.computePrefixHash`.

Identify **missing** test coverage:
- No integration test for `refreshCacheConfig()` with a mock container
- No test verifying `isDirectoryWritable` on a read-only path
- No test for the `cacheEnabled = false` path through `installCacheCoordinator`
- No test that `enableCaching` atomic swap actually doesn't window-through-nil

List these as follow-up work but do NOT fail the review on them.

### Task group F: Default behavior validation

The migration changes the default experience. Verify:

1. **Fresh install, no `ServerConfiguration.json`**:
   - `cacheEnabled` defaults to on (nil → true)
   - `cacheDiskEnabled` defaults to on
   - `cacheDiskMaxGB` defaults to 4.0
   - `cacheMaxBlocks` defaults to 1000 (or 2000 on ≥48 GB RAM)
   - TurboQuant defaults to on (unconditional)

2. **Existing user with old `ServerConfiguration.json` (pre-migration)**:
   - Old JSON doesn't have the new cache fields
   - Decoder returns nil for each → treated as default-on
   - Their existing gen* fields are preserved unchanged
   - No data loss, no unexpected behavior change from their pre-migration
     settings that they had explicitly set

3. **User who disabled something**:
   - `genTurboQuant = false` in old JSON → still honored
   - `cacheEnabled = false` in new JSON → coordinator disabled on next load

### Task group G: Cross-function interaction checks

Walk each of these code paths end-to-end:

1. **First model load after fresh install**
   - `loadContainer` → `installCacheCoordinator` → `buildCacheCoordinatorConfig`
   - Verify the master toggle check, disk dir probe, coordinator creation,
     hybrid detection sequence

2. **Model unload via "Unload" button in cache inspector**
   - `MLXService.unloadRuntimeModel` → `ModelRuntime.unload(name:)` →
     `cancelActiveGeneration` → `disableCaching` → remove from cache
   - Verify the disable happens BEFORE the dict removal

3. **"Clear All" button in cache inspector**
   - `MLXService.clearRuntimeCache` → `ModelRuntime.clearAll` → disables
     all coordinators → clears `modelCache` → Memory.clearCache
   - Then `OsaurusPaths.clearDiskKVCache` wipes L2
   - Verify the order is models first, disk second

4. **Settings save that only changes port**
   - `modelReloadNeeded` should be `false`
   - `serverRestartNeeded` should be `true`
   - `refreshCacheConfig` should NOT run

5. **Settings save that only changes TurboQuant**
   - `modelReloadNeeded` should be `true`
   - `serverRestartNeeded` should be `false`
   - `refreshCacheConfig` runs; NIO does NOT restart

6. **VLM generation with images**
   - `prepareAndGenerate` → `TokenIterator(..., cacheCoordinator: x)`
   - vmlx internally checks `input.image == nil` and skips coordinator fetch
   - Verify the skip logic is in vmlx, not osaurus (should be in vmlx)

7. **Window close cleanup**
   - `closeWindow` → captures sessionId + agentId → Task:
     `invalidateSession` (no-op) + `invalidatePreflightCache` +
     `invalidateCache(agentId:)` on memory assembler + unload unused models
   - Verify the invalidation order and that nothing is skipped

### Task group H: Documentation consistency

Cross-check the four docs for contradictions:

1. Does `01-README.md` decision register match `03-CONSIDERATIONS.md`
   section for the same decision?
2. Does `02-GAPS.md` P0/P1 classification match `03-CONSIDERATIONS.md`
   classification for the same gap?
3. Does every `04-CHANGE-AUDIT.md` entry reference the correct section
   in `02-GAPS.md` or `03-CONSIDERATIONS.md`?
4. Are file paths and line numbers in the audit entries still accurate?
   (Diff drift is the main failure mode here.)

### Task group I: Build & run sanity

You (the agent) probably can't build this yourself, but you can check for
things that would break the build at read-time:

1. Unresolved symbol references
2. Missing imports
3. Inconsistent type signatures (e.g., a helper takes `ServerConfiguration?`
   but a caller passes `ServerConfiguration`)
4. Orphaned `@State` vars declared but never read/written
5. Dead code paths (e.g., a `case` in a switch that nothing produces)

Report each finding with file path + line number.

### Task group J: The one thing that's most likely to be wrong

If the migration has a bug we missed, it's most likely in one of:

1. **`refreshCacheConfig` interleaving with active generations** — the
   concurrency invariants documented in Task group B are the load-bearing
   ones. Re-verify them.

2. **`Tokenizers` 0.1.21 API compatibility** — the `SwiftTransformersTokenizerLoader.swift`
   uses `applyChatTemplate(messages:tools:additionalContext:)` which might
   be a 1.x addition. This is a BUILD-time issue, not runtime, but it'll
   block merge.

3. **The `Bool?` encoding round-trip** — `JSONEncoder` by default omits nil
   Optional fields. Verify that an explicit `cacheEnabled = true` doesn't
   get collapsed to nil on re-decode.

4. **The disk cache write-probe racing with real writes** — if two model
   loads happen concurrently, both probe files could briefly exist in the
   same directory.

Allocate extra attention to these.

---

## Output format

Produce a single structured report with these sections:

```
## VMLX Cache Migration Audit — [YYYY-MM-DD]

### Summary
[1-paragraph verdict: SAFE_TO_MERGE / NEEDS_FIXES / BLOCKED]

### Per-change verification (A)
[Table of C-001 through C-013 with pass/fail per change]

### Concurrency invariants (B)
[9 items, each with PASS/FAIL + 1-line justification]

### Settings propagation (C)
[Step-by-step trace result]

### API compat (D)
[6 items, each confirmed preserved]

### Test coverage (E)
[List of confirmed tests + missing-but-not-blocking items]

### Default behavior (F)
[3 scenarios verified]

### Cross-function paths (G)
[7 paths traced]

### Doc consistency (H)
[Contradiction findings or "none"]

### Build sanity (I)
[List of findings]

### High-risk areas (J)
[Extra scrutiny on the 4 items]

### Open questions for humans
[Anything that the team must decide before merge]

### Recommended merge decision
[APPROVE / APPROVE_WITH_FOLLOWUPS / REQUEST_CHANGES / BLOCK]
```

Do not paraphrase or truncate. Each section must explicitly address every
check listed above, even if the answer is "no issues found".
