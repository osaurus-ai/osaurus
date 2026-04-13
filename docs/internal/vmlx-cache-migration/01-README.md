# VMLX Cache Migration — Team Review Package

> **Branch**: `feat/vmlx-cache-migration`
> **Status**: Ready for team review (not merged)
> **Base**: `main` @ `2dde1216`
>
> This folder contains the full paper trail for the vmlx-swift-lm caching
> migration. Everything under `docs/internal/` is team-only — do not expose
> to public contributors or include in release builds.

## ⚠️ Round 3 scope change — read this first

This branch went through three rounds of scope. The audit log (`04-CHANGE-AUDIT.md`)
reflects all three. Don't skim — the early changes are partially superseded.

**What the branch actually does now**:

1. **Package-level migration** — replaces osaurus's custom `KVCacheStore` with
   vmlx-swift-lm's `CacheCoordinator` (paged L1 + disk L2 + SSM companion +
   TurboQuant). Covers the JIT crash fix (#814), Gemma 4 JANG shape fixes
   (#808, #813), and unlocks the package's continuous batching engine for
   future use. This is the bulk of the work in commits `9d66eb12` and
   `db492f29`.

2. **User-visible cache surface stripped** — osaurus doesn't expose any cache
   knobs. No "Cache Storage" settings subsection, no Disk KV Cache row in the
   model inspector, no `cacheEnabled`/`cacheDiskMaxGB`/`cacheMaxBlocks` fields
   in `ServerConfiguration`. Caching is invisible infrastructure handled by
   the package with hardcoded osaurus-internal defaults. This is the Round 3
   revert, commits `51d055a3` and `0bb41b90`.

3. **Memory default off + Settings toggle** — `MemoryConfiguration.enabled`
   defaults to `false`. A new toggle in Settings → Chat → Memory lets users
   opt in. Existing users with explicit `"enabled": true` in their JSON keep
   memory on; everyone else starts with memory off on next launch.

4. **Tools default off + chat-bar Tools chip** — `ChatConfiguration.disableTools`
   defaults to `true`. Same opt-in story: a Settings toggle plus a new Tools
   chip in `FloatingInputCard` that overrides the global for one conversation.

**What the branch does NOT do** (explicitly deferred):

- BatchEngine migration — the `TokenIterator` single-sequence path still runs.
  Switching to `BatchEngine` for continuous batching is a separate, larger
  architectural change.
- Experience Mode presets (Simple / Balanced / Power / Developer) — deferred
  to a future branch.
- First-launch onboarding modal — deferred.
- Per-tool checkboxes in a Tools popover — the chip is a simple on/off cycle
  for now. Power users can still use `Agent.manualToolNames`.

**Per-change audit**: every entry is in `04-CHANGE-AUDIT.md`. The Round 3
entries are at the **bottom** of the file under the "Round 3 — cache-surface
strip + memory/tools defaults" section heading. They supersede parts of
C-001..C-013.

---

## Important — package hosting note

This migration currently points at the **private** `osaurus-ai/vmlx-swift-lm`
GitHub repository:

```swift
.package(url: "https://github.com/osaurus-ai/vmlx-swift-lm", branch: "main")
```

**When we're ready for production release**, this will be moved to the existing
`osaurus-ai/mlx-swift-lm` repository URL (which may be renamed / replaced in
place with the vmlx codebase). The intent:

- The public repo name stays `mlx-swift-lm` for continuity with the upstream
  Apple project nomenclature.
- The private `vmlx-swift-lm` is the development fork we iterate on.
- At release time the vmlx contents are either (a) merged into the main
  osaurus `mlx-swift-lm` repo, or (b) the osaurus Package.swift reference is
  updated to point at whichever public URL the final package lives at.

**Action for reviewers**: when merging this branch, verify the Package.swift
dependency URL matches the current canonical location. Do not assume it
stays at `osaurus-ai/vmlx-swift-lm` forever — that's the dev-time alias.

Every reference to `vmlx-swift-lm` in these docs should be understood as
"whichever repo osaurus's fork of mlx-swift-lm lives at when you read this".

---

## Review philosophy for this package

**Every change is documented. Every integration point is traced. Every
decision is reversible.** The three rounds of audit produced four docs
totaling ~2,500 lines because the migration touches enough cross-cutting
concerns (settings propagation, actor concurrency, disk I/O, UI, API compat,
error handling) that a casual review would miss important details.

If you're reviewing on behalf of the team:
- Do not skim. Every entry in `04-CHANGE-AUDIT.md` has a reason to be there.
- Every "Audit focus" bullet in a change entry is a specific point where
  something could go wrong. Treat them as a checklist.
- Open concerns in the "Decision register" and "Open concerns" sections
  below are explicitly flagged for team input — don't merge without
  acknowledging each one.
- If an agent is reviewing this on your behalf, point it at `00-AGENT-BRIEF.md`
  for a structured dispatch prompt.

---

## What this migration does, in plain English

osaurus shipped with its own custom KV cache layer (`KVCacheStore`) that manually
managed hot RAM and cold SSD tiers, session caches, prefix caches, and a
two-phase prefill workaround for hybrid SSM models. That entire layer has been
replaced with **vmlx-swift-lm's built-in `CacheCoordinator`**, which provides:

- **L1 paged cache** — 64-token blocks, SHA-256 chain hashing, LRU eviction
- **L2 disk cache** — SQLite + safetensors, persists across app restarts
- **SSM companion cache** — hybrid-model state handling (Qwen3.5-A3B, Jamba, Nemotron-H)
- **TurboQuant** — 4.7–5× KV memory compression, now enabled by default
- **Automatic hybrid detection** — coordinator auto-detects Mamba/ArraysCache layers
- **macOS 26 M1/M2 crash fix** — the `compile(shapeless: true)` JIT bug in
  Gemma 4 JANG models (issues #808, #813, #814) is fixed upstream in vmlx

osaurus lost ~1,953 lines of custom cache code and gained a simpler, faster,
more correct caching system.

## Why you're reading this

This is not a one-line fix. It touches generation, model lifecycle, settings
persistence, UI, tests, and crosses the boundary between osaurus and the
vmlx-swift-lm package. I want your team to review it granularly before we
merge — there are concurrency subtleties, API-compat decisions, and default
tuning choices that deserve scrutiny.

## How to read these docs

Numbered in reading order:

| # | File | What it is | Audience | Length |
|---|------|------------|----------|--------|
| **01** | [`01-README.md`](./01-README.md) | This file — orientation + decision register | Humans | short |
| **02** | [`02-GAPS.md`](./02-GAPS.md) | First-pass gap analysis — what still needs work | Humans + agents | medium |
| **03** | [`03-CONSIDERATIONS.md`](./03-CONSIDERATIONS.md) | Second-pass nuances, edge cases, cross-function audit | Humans + agents | long |
| **04** | [`04-CHANGE-AUDIT.md`](./04-CHANGE-AUDIT.md) | Granular per-change audit log (C-001 … C-013) | Agents | long |
| **00** | [`00-AGENT-BRIEF.md`](./00-AGENT-BRIEF.md) | Machine-readable entry point if you're dispatching an agent | Agents only | short |

**If you have 10 minutes**: read this file + the "Change register" table below.
**If you have 30 minutes**: add `02-GAPS.md` and `03-CONSIDERATIONS.md` §Summary.
**If you're doing a real review**: read them in order 01 → 02 → 03 → 04.

---

## Change register (C-001 through C-018 + C-R01..C-R06)

Every code change in this branch is numbered and documented in `04-CHANGE-AUDIT.md`.

### Round 1 & 2 — initial cache migration + first-pass UX

These entries built out a user-visible cache settings surface that
was **later reverted** in Round 3. Listed here for history. Some
changes (C-002, C-003, C-010, C-011 helpers, the core migration work)
remain load-bearing; others (C-001, C-006, C-007, C-008, C-012, C-013)
are superseded.

| ID | File | What | Round 3 status |
|----|------|------|----------------|
| C-001 | `ServerConfiguration.swift` | Add `cacheEnabled` master toggle field | **Reverted by C-R01** |
| C-002 | `RuntimeConfig.swift` | `autoTurboQuant()` → unconditional `true` | Kept |
| C-003 | `ConfigurationView.swift` | UI badge/helper mirrors C-002 | Kept |
| C-004 | `ModelRuntime.swift` | Factor `buildCacheCoordinatorConfig` + helpers | **Simplified by C-R06** |
| C-005 | `ModelRuntime.swift` | Add `refreshCacheConfig()` hot-reload | **Removed by C-R06** |
| C-006 | `ConfigurationView.swift` | Reset + load/save for cache fields | **Reverted by C-R02** |
| C-007 | `ConfigurationView.swift` | Master "KV Caching" toggle UI | **Reverted by C-R02** |
| C-008 | `ConfigurationView.swift` | Split `serverRestartNeeded` / `modelReloadNeeded` | **Simplified by C-R03** |
| C-009 | `ModelRuntime.swift` | Fix dict-iteration race + nil-coordinator window | **Obsolete** (refreshCacheConfig gone) |
| — | `MLXGenerationEngine.swift` | Remove unused `import MLXLLM` | Kept |
| C-010 | `ChatWindowManager.swift` | Invalidate `MemoryContextAssembler` on window close | Kept |
| C-011 | `OsaurusPaths.swift` | Add `diskKVCache()` / usage / clear helpers | Kept (used internally) |
| C-012 | `ModelCacheInspectorView.swift` | Disk cache row + expanded Clear All | **Reverted by C-R04** |
| C-013 | `ServerConfigurationStoreTests.swift` | 5 round-trip tests for cache fields | **Reverted by C-R05** |

### Round 3 — cache surface strip + memory/tools defaults

These are the current-state changes that define the branch's end state.

| ID | File | What | Severity |
|----|------|------|----------|
| C-R01 | `ServerConfiguration.swift` | Remove user-facing cache fields | P0 |
| C-R02 | `ConfigurationView.swift` | Remove Cache Storage subsection | P1 |
| C-R03 | `ConfigurationView.swift` | `modelReloadNeeded` → `runtimeConfigChanged` + use `invalidateConfig` | P1 |
| C-R04 | `ModelCacheInspectorView.swift` | Remove Disk KV Cache row | P1 |
| C-R05 | `ServerConfigurationStoreTests.swift` | Migration-compat test for removed fields | P1 |
| C-R06 | `ModelRuntime.swift` | Simplify `buildCacheCoordinatorConfig` (no serverCfg); drop `refreshCacheConfig` | P1 |
| **C-014** | `MemoryConfiguration.swift` | Flip `enabled` default to `false` | **P0** |
| **C-015** | `ConfigurationView.swift` | Add Memory toggle to Settings → Chat | **P0** |
| **C-016** | `ChatConfiguration.swift` | Flip `disableTools` default to `true` | **P0** |
| **C-017** | `ChatWindowState.swift` | Add `toolsDisabledOverride: Bool?` | P1 |
| **C-018** | `FloatingInputCard.swift` | Add Tools chip to chat bar selector row | P1 |

Plus the original migration commit `9d66eb12` which did the bulk removal
(KVCacheStore + custom cache logic — ~1,953 lines deleted).

### Commits in chronological order

1. `9d66eb12` — Initial vmlx migration (KVCacheStore deletion + CacheCoordinator)
2. `db492f29` — Round 1/2 cache UI + refresh hot-reload
3. `51d055a3` — Clean up misplaced design doc folder
4. `0bb41b90` — **Round 3** cache strip + memory/tools defaults + Tools chip
5. (Next) — Round 3 documentation updates + polish (this commit)

---

## Decision register — what to challenge

These are the conscious choices made during the migration. Any of them can be
reversed if the team disagrees.

### D-1: TurboQuant default-on for all users

- **Decision**: `RuntimeConfig.autoTurboQuant()` returns `true` unconditionally.
- **Alternative considered**: keep the old "auto-enable on <16 GB headroom" behavior.
- **Rationale**: vmlx-swift-lm documents no meaningful quality regression from
  TurboQuant. Compression is 4.7–5×, enabling longer context windows on all
  hardware. User explicitly requested default-on.
- **Risk**: We haven't benchmarked quality on every model family. If a specific
  architecture regresses, we'd need to revert to auto-detect or add a blocklist.
- **Escape hatch**: User can explicitly set `genTurboQuant = false` in settings.
- **Reviewer question**: Are we comfortable shipping this default without more
  benchmarking? Or should we keep it conservative (headroom-triggered) until
  we have regression data?

### D-2: Keep API compat fields even though they're dead

- **Decision**: `ChatCompletionRequest.cache_hint`, `ChatCompletionRequest.session_id`,
  `ChatCompletionResponse.prefix_hash`, `GenerationParameters.cacheHint`,
  `.staticPrefix`, `.sessionId`, `ModelRuntime.computePrefixHash`,
  `PromptManifest.staticPrefixHash` — all still exist and flow through the
  pipeline, but none of them affect the new `CacheCoordinator`'s cache lookup
  (which is content-addressed by token block hashes).
- **Alternative considered**: aggressive removal.
- **Rationale**: API backwards compatibility. Clients may be storing
  `prefix_hash` and resending it as `cache_hint`. Removing the fields would
  break them. The harm from keeping them is just ~microseconds of wasted
  SHA-256 work per request.
- **Flagged for future**: These fields should be removed in a major version
  bump. Documented in `03-CONSIDERATIONS.md` §N.
- **Reviewer question**: Is this the right line? Or should we at least strip
  the internal passthroughs (`GenerationParameters.staticPrefix`, which isn't
  read by anything)?

### D-3: Master toggle rather than granular overrides

- **Decision**: Added `cacheEnabled` as a single top-level master toggle.
  Sub-toggles (Disk Cache, max blocks, disk cap) are disabled+dimmed when
  master is off.
- **Alternative considered**: Per-tier toggles with no master.
- **Rationale**: User explicitly requested "all enabled by default, but a
  way to turn everything off". Single switch is simpler for 95% of users.
  Power users who want per-tier control still have the Advanced disclosure.
- **Reviewer question**: Should we also add a per-tier "memory cache" toggle?
  Currently you can turn off disk-only, but not paged-only.

### D-4: Hot-reload via `refreshCacheConfig()` instead of requiring model reload

- **Decision**: Settings changes that affect generation/cache (all gen* and
  cache* fields) trigger `ModelRuntime.refreshCacheConfig()` which rebuilds
  the coordinator on every loaded model without unloading.
- **Alternative considered**: Show a banner saying "changes take effect on
  next model load". Much simpler.
- **Rationale**: Users benchmarking settings changes would be forced to wait
  for a full unload+reload on every tweak. Hot-reload is a much better UX.
- **Complexity introduced**: `refreshCacheConfig` has three concurrency
  invariants (cancel active gen first, snapshot dict before iterating, let
  `enableCaching` atomically swap coordinators). Documented inline and in
  `04-CHANGE-AUDIT.md` C-005 / C-009.
- **Reviewer question**: Is the complexity worth it? We could alternatively
  drop `refreshCacheConfig` and just accept the "restart required" UX if
  the team prefers simpler guarantees.

### D-5: Disk cache directory at `<root>/cache/kv_v2/`

- **Decision**: L2 disk cache lives under osaurus's existing `cache()` root
  in a `kv_v2/` subdirectory.
- **Alternative considered**: `~/Library/Caches/ai.osaurus/` (Apple-standard
  location).
- **Rationale**: osaurus already uses `OsaurusPaths.cache()` for other cache
  surfaces. Consistency trumps Apple convention. Users can relocate by moving
  `OsaurusPaths.root()` via `OSAURUS_HOME` etc.
- **Reviewer question**: Should we migrate to `~/Library/Caches/` for better
  "clean my Mac" tool interop? (Would be a breaking change for users who
  have existing caches.)

### D-6: `session_id` / `invalidateSession` are now no-ops for the cache

- **Decision**: `ModelRuntime.invalidateSession(_:)` is a documented no-op.
  `sessionId` still flows through the API and `GenerationParameters` but
  has no effect on the cache layer.
- **Alternative considered**: Rewire session tracking to call
  `container.disableCaching()` + `enableCaching()` on the relevant model.
- **Rationale**: The new `CacheCoordinator` is content-addressed. There's no
  per-session key to invalidate. Clearing would waste the shared cache blocks
  that other sessions benefit from.
- **Trade-off**: Users who close a 10k-token conversation won't see immediate
  RAM reclamation — the blocks stay until LRU pressure evicts them.
- **Reviewer question**: Is this acceptable? If not, the only way to preserve
  "close window frees RAM" is to disable+re-enable the coordinator on close,
  which nukes the whole cache.

---

## Open concerns — need your team's judgment

### OC-1: `swift-transformers` version conflict (P0, blocking)

vmlx-swift-lm added a dependency on `swift-transformers from: "0.1.21"` for
macro code generation. osaurus was using `from: "1.1.6"`. These ranges don't
overlap — SPM resolution will fail.

**Current state**: The branch has the osaurus Package.swift patched to
`from: "0.1.21"` (uncommitted). The `Tokenizers.Tokenizer` API used by
`SwiftTransformersTokenizerLoader.swift` may or may not compile against 0.1.21
— specifically `applyChatTemplate(messages:tools:additionalContext:)` is
recent-ish.

**Needs**: A real Xcode build attempt to verify. I cannot do this from my
environment.

**Fallback options** if 0.1.21 doesn't have the API we need:
- Option A: Adapt `SwiftTransformersTokenizerLoader.swift` to the 0.1.21 API
- Option B: Ask vmlx-swift-lm to drop its unused `swift-transformers` dep
  (the dep was added for macro string literals, not for any linked target)

### OC-2: TurboQuant default-on — unbenchmarked

Ship with a release note "report regressions" and revert to auto-detect if
users complain? Or benchmark first?

### OC-3: `activeGenerationTask` single-slot tracking

Pre-existing: `ModelRuntime.activeGenerationTask` only tracks the most recent
generation. Concurrent generations across multiple windows leave earlier tasks
unreferenced. This is unchanged from before migration. Worth fixing as a
follow-up?

### OC-4: Model-content-hash in `modelKey`

If a user replaces a model file under the same name, the disk cache could
return stale KV state for incorrect weights. Currently `modelKey` is just the
model name. Should we hash the config + tokenizer for collision-resistance?

### OC-5: `PromptManifest.Cacheability` enum now decorative

The `.static`/`.dynamic` classification on prompt sections was used by the
old prefix-cache build path. It's now unused at the cache layer but still
computed per request. Leave for debug observability, or remove?

### OC-6: Pre-existing `genTurboQuant` missing from change-detection

`serverRestartNeeded` never included `genTurboQuant`. That meant changing
TurboQuant in settings used to do nothing. C-008 fixes this as a side effect.
**We're fixing a bug main had for months** — worth calling out in the PR body.

---

## What to test before merging

### Automated (can run from Xcode)
- [ ] `swift build` completes — this is the blocker per OC-1
- [ ] `swift test --filter ServerConfigurationStoreTests` — 5 new tests from C-013
- [ ] `swift test --filter ModelRuntimePrefixTests` — should still pass (unchanged)
- [ ] `swift test --filter PrefixHashTests` — should still pass (unchanged)

### Manual (requires real model)
- [ ] Load a text-only model (Qwen2-7B). Send 2 turns. Watch logs for
      "Cache hit" messages from vmlx.
- [ ] Load a VLM (Qwen2-VL). Send an image+text. Verify no cache fetch
      attempt in logs (should be silent-bypass).
- [ ] Load a hybrid model (Qwen3.5-A3B). Verify `isHybrid=true` in the
      `installCacheCoordinator` log line. Send 2 turns. Verify no full
      re-prefill on turn 2.
- [ ] Kill and restart the app. Load the same text-only model. Send the
      same first message. Verify L2 disk cache hit in logs.
- [ ] Open Settings → Local Inference → Cache Storage. Toggle master off,
      save. Send a turn. Verify log shows `cacheCoordinator=nil`, full prefill.
- [ ] Toggle master back on, save. Verify refreshCacheConfig log appears
      (should see "refreshCacheConfig: applied to N loaded model(s)").
- [ ] Open Model Cache Inspector. Verify Disk KV Cache row shows non-zero
      size after the earlier runs. Click Clear, verify goes to zero.

### macOS 26 / M1/M2 regression check
- [ ] Load `gemma-4-26b-a4b-it-jang-*` (or similar JANG model) on a real
      M1/M2 Mac running macOS 26. Verify no `Index out of range` crash.
      This was issue #814 — the root cause is fixed upstream in vmlx via
      `HardwareInfo.isCompiledDecodeSupported`.

---

## Files in this folder

```
docs/internal/vmlx-cache-migration/
├── 00-AGENT-BRIEF.md            ← machine-readable entry point for agent reviews
├── 01-README.md                 ← you are here
├── 02-GAPS.md                   ← first-pass gap analysis
├── 03-CONSIDERATIONS.md         ← second-pass nuances + edge cases
└── 04-CHANGE-AUDIT.md           ← per-change audit log (C-001 through C-013)
```

## Files outside this folder that are part of the branch

Touched by the migration (see `04-CHANGE-AUDIT.md` for line-by-line detail):

- `Packages/OsaurusCore/Package.swift` — dependency swap (uncommitted)
- `Packages/OsaurusCore/Models/Configuration/ServerConfiguration.swift`
- `Packages/OsaurusCore/Services/ModelRuntime.swift`
- `Packages/OsaurusCore/Services/ModelRuntime/MLXGenerationEngine.swift`
- `Packages/OsaurusCore/Services/ModelRuntime/RuntimeConfig.swift`
- `Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift`
- `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`
- `Packages/OsaurusCore/Views/Model/ModelCacheInspectorView.swift`
- `Packages/OsaurusCore/Utils/OsaurusPaths.swift`
- `Packages/OsaurusCore/Tests/Networking/ServerConfigurationStoreTests.swift`

Deleted in the original migration commit `9d66eb12`:
- `Packages/OsaurusCore/Services/ModelRuntime/KVCacheStore.swift` (495 lines)
- `Packages/OsaurusCore/Tests/Service/KVCacheStoreTests.swift` (~570 lines)
- `Packages/OsaurusCore/Tests/Model/MLXGenerationEngineTests.swift` (~80 lines)
- Package.resolved files (to force SPM re-resolve)

---

## Contact

Questions, pushback, or "let's discuss" on any decision above → reply on the
PR when it's opened, or ping Eric directly. Every decision in the register is
reversible — nothing is load-bearing yet.
