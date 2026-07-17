# Osaurus Palace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement "Osaurus Palace" — a native Swift, on-device, MemPalace-style verbatim memory subsystem (wings → rooms → drawers, `palace_*` tools, scoped semantic + FTS search) — starting with the Phase 0 spike PR, feature-flagged **off** by default.

**Architecture:** Palace is a sibling of Memory v2, not a replacement: a new `palace.sqlite` opened through `OsaurusStorageOpener` (detection-first plaintext/SQLCipher), a `PalaceDatabase` modeled on `RouterBillingDatabase`/`MemoryDatabase` (serial queue, `PRAGMA user_version` migrations, `OsaurusDatabaseHandle` maintenance registration, FTS5 external-content mirror), a `PalaceService`/`PalaceSearchService` pair, and nine `palace_*` tools registered as built-ins but stripped from the model-visible schema by `SystemPromptComposer` unless `palace.json: enabled=true`. Memory v2 write/read paths are untouched.

**Tech Stack:** Swift 6 (`Packages/OsaurusCore`), SQLite via `OsaurusSQLCipher` C API, FTS5, `EmbeddingService` (potion-base-4M, 128-dim) for vectors, swift-testing (`@Suite`/`@Test`/`#expect`).

**Spec:** `~/docs/specs/osaurus-palace-native-spec.md` (MemPalace → Osaurus mapping). This plan implements **Phase 0** in full detail and locks the PR sequence for Phases 1–4.

---

## Hard constraints (from the commissioning request)

1. `palace.enabled = false` by default — a fresh install must show zero behavior change.
2. **No Memory v2 regressions** — no edits to Memory write/read behavior; the only shared-file edits are additive (registry list, composer strip-set, storage catalog entry, paths).
3. **All paths via `OsaurusPaths`** — no hardcoded `~/.osaurus` anywhere in Palace code.

## Resolved open decisions (spec §17)

| # | Decision | Resolution for Phase 0 |
|---|----------|------------------------|
| 1 | Package boundary | `Packages/OsaurusCore` monolith — every sibling feature (Memory, Agent DB, Billing) lives there; a separate package would fight the existing `Storage/`/`Services/`/`Tools/` layering. |
| 2 | Vector backend | SQLite `palace_embeddings` table + in-Swift cosine brute force (spec §6.2 Option B) for Phase 0; `PalaceVectorStore` protocol so Phase 1 can swap in VecturaKit. |
| 3 | Tool naming | `palace_*` only (no `mempalace_*` aliases) — avoids collision with the external MemPalace MCP server; alias table documented in Phase 1's `docs/PALACE.md`. |
| 4 | Auto-inject default | Off. Phase 0 has **no** auto-injection at all (that's Phase 3's `PalaceReadCoordinator`). |
| 5 | Branding | Code says "Palace"; docs will credit "MemPalace-style" (Phase 1). |

**Gating design note:** the spec says "hidden from `ToolRegistry` (same pattern as `db_*` gating)". The actual `db_*` pattern (read from source) is: tools are *always registered* as built-ins in `ToolRegistry.registerBuiltInTools()` (`ToolRegistry.swift:219-234`) and *stripped from the model-visible schema* in `SystemPromptComposer.resolveTools` (`SystemPromptComposer.swift:2079-2085`, keyed on `AgentConfigSnapshot.dbEnabled`). Palace mirrors that, with two differences justified by the flag being **global** (`palace.json`) rather than per-agent:
- The strip applies in **both** auto and manual modes with no `additionalToolNames` carve-out — feature off means the model never sees the tools.
- Every tool's `execute()` re-checks the flag and returns an `unavailable` envelope, so a stale frozen schema or a direct HTTP tool call can't touch a disabled palace.

## PR sequence (spec §14 phases → PRs)

| PR | Phase | Contents | Ships behind flag? |
|----|-------|----------|--------------------|
| **PR 1 (this plan)** | 0 — Spike | `OsaurusPaths` palace accessors, `palace.json` config (default off), `PalaceDatabase` schema v1 (wings/rooms/drawers + FTS5 + embeddings), `PalaceService`, `PalaceSearchService` (brute-force vector + FTS fallback), 9 `palace_*` CRUD/search tools, composer gate, storage-catalog entry, unit + integration tests, this plan doc | Yes — `enabled=false` |
| PR 2 | 1 — MVP retrieval | `PalaceVectorStore` VecturaKit impl (or keep brute force if 20k-drawer perf holds), `max_distance` tuning, `palace_rebuild_index`, KG tables (schema v2) + `palace_kg_*` tools, Management UI search slice, `docs/PALACE.md`, 50-question retrieval fixture (R@5 ≥ 90%) | Yes |
| PR 3 | 2 — Ingest & hooks | `PalaceIngestService` (chunking 800/100, `.gitignore` respect, idempotent re-ingest), `osaurus palace mine/search/status` CLI, session-end transcript mirroring (opt-in), `palace_diary_*`, tunnels (schema v3) | Yes |
| PR 4 | 3 — Memory coordination | `PalaceReadCoordinator`, relevance-gate extension, `palaceBudgetTokens` injection alongside Memory v2, insights logging | Yes |
| PR 5+ | 4 — Quality | Hybrid keyword+temporal boost, LongMemEval subset script, export/import | Yes |

Phases 1–4 get their own plan documents once PR 1 lands and maintainer feedback is in. Everything below is **Phase 0 only**.

---

## File structure (Phase 0)

| File | Responsibility |
|------|----------------|
| `Packages/OsaurusCore/Utils/OsaurusPaths.swift` (modify) | `palace()`, `palaceDatabaseFile()`, `palaceConfigFile()` accessors |
| `Packages/OsaurusCore/Models/Palace/PalaceConfiguration.swift` (create) | `PalaceConfiguration` Codable struct (enabled=false default) + `PalaceConfigurationStore` (cached load/save, never-auto-save-on-missing-file) |
| `Packages/OsaurusCore/Models/Palace/PalaceModels.swift` (create) | `PalaceWing`, `PalaceRoom`, `PalaceDrawer`, `PalaceSearchHit`, `PalaceStatus` DTOs |
| `Packages/OsaurusCore/Storage/PalaceDatabase.swift` (create) | SQLite schema v1, migrations, CRUD, FTS5 mirror, embedding rows |
| `Packages/OsaurusCore/Services/Palace/PalaceService.swift` (create) | Taxonomy ensure, dedup-by-hash add, get/update/delete, status |
| `Packages/OsaurusCore/Services/Palace/PalaceSearchService.swift` (create) | Query embed → cosine brute force; FTS5 fallback; scoping |
| `Packages/OsaurusCore/Tools/Palace/PalaceTools.swift` (create) | 9 `palace_*` tools |
| `Packages/OsaurusCore/Tools/ToolRegistry.swift` (modify) | Register the 9 tools as built-ins |
| `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift` (modify) | `palaceToolNames` set + global strip |
| `Packages/OsaurusCore/Storage/StorageDatabaseCatalog.swift` (modify) | Register `palace.sqlite` for rekey/export/maintenance |
| `Packages/OsaurusCore/Tests/Palace/PalaceConfigurationTests.swift` (create) | Config defaults/decode tests |
| `Packages/OsaurusCore/Tests/Palace/PalaceDatabaseTests.swift` (create) | Schema/CRUD/dedup/FTS unit tests (in-memory DB) |
| `Packages/OsaurusCore/Tests/Palace/PalaceSearchServiceTests.swift` (create) | Cosine ranking + FTS fallback + scoping tests |
| `Packages/OsaurusCore/Tests/Palace/PalaceToolsIntegrationTests.swift` (create) | Tool round-trip: add → search → get; disabled-flag envelope |

SPM note: `OsaurusCore`'s main target has `path: "."` and the test target `path: "Tests"` (`Package.swift:211,231`), so new directories are picked up with no manifest edit.

Build/test commands (from `AGENTS.md` + `Makefile`):

```bash
# fast unit loop (what CI's test-core mirrors)
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
OSU_MODELS_DIR=/tmp/osaurus-test-models \
make test
# targeted:
swift test --package-path Packages/OsaurusCore --filter Palace
```

---

### Task 1: OsaurusPaths accessors + PalaceConfiguration

**Files:**
- Modify: `Packages/OsaurusCore/Utils/OsaurusPaths.swift` (after `methods()` ~line 288, and in Configuration Files block ~line 483)
- Create: `Packages/OsaurusCore/Models/Palace/PalaceConfiguration.swift`
- Test: `Packages/OsaurusCore/Tests/Palace/PalaceConfigurationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
//
//  PalaceConfigurationTests.swift
//  osaurusTests
//
//  Palace ships disabled: a fresh install must load `enabled == false`
//  and a missing palace.json must NOT be auto-created (see the
//  RemoteProviderConfigurationStore.load data-loss rationale).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PalaceConfigurationTests {

    private func withTempRoot<T>(_ body: () throws -> T) rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palace-config-tests-\(UUID().uuidString)", isDirectory: true)
        OsaurusPaths.overrideRoot = root
        PalaceConfigurationStore.invalidateCache()
        defer {
            OsaurusPaths.overrideRoot = nil
            PalaceConfigurationStore.invalidateCache()
            try? FileManager.default.removeItem(at: root)
        }
        return try body()
    }

    @Test func defaults_are_disabled() {
        let config = PalaceConfiguration()
        #expect(config.enabled == false)
        #expect(config.embeddingBackend == "mlx")
        #expect(config.defaultWing == "default")
        #expect(config.searchDefaultLimit == 5)
    }

    @Test func missing_file_loads_default_and_does_not_write() {
        withTempRoot {
            let loaded = PalaceConfigurationStore.load()
            #expect(loaded.enabled == false)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.palaceConfigFile().path))
        }
    }

    @Test func partial_json_decodes_with_defaults() throws {
        try withTempRoot {
            let url = OsaurusPaths.palaceConfigFile()
            try OsaurusPaths.ensureExists(url.deletingLastPathComponent())
            try Data(#"{"enabled": true}"#.utf8).write(to: url)
            let loaded = PalaceConfigurationStore.load()
            #expect(loaded.enabled == true)
            #expect(loaded.searchDefaultLimit == 5)  // default survives partial file
        }
    }

    @Test func save_load_round_trip() {
        withTempRoot {
            var config = PalaceConfiguration()
            config.enabled = true
            config.defaultWing = "vault"
            PalaceConfigurationStore.save(config)
            PalaceConfigurationStore.invalidateCache()
            let loaded = PalaceConfigurationStore.load()
            #expect(loaded.enabled == true)
            #expect(loaded.defaultWing == "vault")
        }
    }

    @Test func paths_resolve_under_root() {
        withTempRoot {
            #expect(OsaurusPaths.palaceDatabaseFile().path.hasSuffix("palace/palace.sqlite"))
            #expect(OsaurusPaths.palaceConfigFile().path.hasSuffix("config/palace.json"))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/OsaurusCore --filter PalaceConfigurationTests`
Expected: FAIL — `cannot find 'PalaceConfiguration' in scope` (compile error counts as the failing state).

- [ ] **Step 3: Add OsaurusPaths accessors**

In `OsaurusPaths.swift`, after `methods()` (line ~288):

```swift
    /// Palace (verbatim memory archive) data directory
    public static func palace() -> URL {
        root().appendingPathComponent("palace", isDirectory: true)
    }
```

In the `// MARK: - Configuration Files` block (beside `memoryConfigFile()`, line ~483):

```swift
    /// Palace SQLite database file: `~/.osaurus/palace/palace.sqlite`
    public static func palaceDatabaseFile() -> URL { palace().appendingPathComponent("palace.sqlite") }
    public static func palaceConfigFile() -> URL { config().appendingPathComponent("palace.json") }
```

- [ ] **Step 4: Create PalaceConfiguration.swift**

```swift
//
//  PalaceConfiguration.swift
//  osaurus
//
//  User-configurable settings for the Palace verbatim-memory subsystem.
//  Palace is OFF by default: `enabled == false` must produce zero behavior
//  change anywhere in the app (tools stripped from the schema, no DB file
//  created, no launch-time work).
//

import Foundation
import os

public struct PalaceConfiguration: Codable, Equatable, Sendable {
    /// Master toggle. Default FALSE — Palace is opt-in.
    public var enabled: Bool

    /// Embedding backend ("mlx" or "none"). When "none" (or when the
    /// embedding model is unavailable), search falls back to FTS5.
    public var embeddingBackend: String

    /// Wing used when a tool call omits `wing`.
    public var defaultWing: String

    /// Default LIMIT for `palace_search`.
    public var searchDefaultLimit: Int

    /// Maximum cosine distance (1 - similarity) for a vector hit to be
    /// returned. 2.0 disables the filter.
    public var maxDistance: Double

    // MARK: - Internal constants (not user-configurable in Phase 0)

    /// Maximum allowed content length for a single drawer. Larger payloads
    /// are rejected with a clear tool error; blob-file spillover is a later
    /// phase (`blob_ref` column already exists in the schema).
    public static let maxContentLength = 100_000

    public init(
        enabled: Bool = false,
        embeddingBackend: String = "mlx",
        defaultWing: String = "default",
        searchDefaultLimit: Int = 5,
        maxDistance: Double = 1.5
    ) {
        self.enabled = enabled
        self.embeddingBackend = embeddingBackend
        self.defaultWing = defaultWing
        self.searchDefaultLimit = searchDefaultLimit
        self.maxDistance = maxDistance
    }

    /// Returns a copy with all values clamped to valid ranges.
    public func validated() -> PalaceConfiguration {
        var c = self
        c.searchDefaultLimit = max(1, min(c.searchDefaultLimit, 50))
        c.maxDistance = max(0.0, min(c.maxDistance, 2.0))
        if c.defaultWing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.defaultWing = "default"
        }
        return c
    }

    public init(from decoder: Decoder) throws {
        let defaults = PalaceConfiguration()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        embeddingBackend =
            try c.decodeIfPresent(String.self, forKey: .embeddingBackend) ?? defaults.embeddingBackend
        defaultWing = try c.decodeIfPresent(String.self, forKey: .defaultWing) ?? defaults.defaultWing
        searchDefaultLimit =
            try c.decodeIfPresent(Int.self, forKey: .searchDefaultLimit) ?? defaults.searchDefaultLimit
        maxDistance = try c.decodeIfPresent(Double.self, forKey: .maxDistance) ?? defaults.maxDistance
    }

    public static var `default`: PalaceConfiguration { PalaceConfiguration() }
}

// MARK: - Store

public enum PalaceConfigurationStore: Sendable {
    private static let logger = Logger(subsystem: "com.dinoki.osaurus", category: "PalaceConfig")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let lock = OSAllocatedUnfairLock<PalaceConfiguration?>(initialState: nil)

    public static func load() -> PalaceConfiguration {
        if let cached = lock.withLock({ $0 }) { return cached }

        let url = OsaurusPaths.palaceConfigFile()
        // CRITICAL: see RemoteProviderConfigurationStore.load — never
        // auto-save an empty default on missing-file. The 2026-04
        // storage-migration recovery race showed this pattern can
        // permanently destroy user data.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PalaceConfiguration()
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(PalaceConfiguration.self, from: data)
            let validated = config.validated()
            lock.withLock { $0 = validated }
            return validated
        } catch {
            logger.error("Failed to load palace config: \(error)")
            return .default
        }
    }

    public static func save(_ config: PalaceConfiguration) {
        let validated = config.validated()
        let url = OsaurusPaths.palaceConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let data = try encoder.encode(validated)
            lock.withLock { $0 = validated }
            ConfigDiskWriter.write(
                data,
                to: url,
                synchronous: OsaurusPaths.overrideRoot != nil,
                onError: { logger.error("Failed to save palace config: \($0.localizedDescription)") }
            )
        } catch {
            logger.error("Failed to save palace config: \(error)")
        }
    }

    public static func invalidateCache() {
        lock.withLock { $0 = nil }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/OsaurusCore --filter PalaceConfigurationTests`
Expected: PASS (5 tests)

- [ ] **Step 6: Commit**

```bash
git add Packages/OsaurusCore/Utils/OsaurusPaths.swift \
        Packages/OsaurusCore/Models/Palace/PalaceConfiguration.swift \
        Packages/OsaurusCore/Tests/Palace/PalaceConfigurationTests.swift
git commit -m "palace: paths + palace.json config, disabled by default"
```

---

### Task 2: PalaceModels DTOs

**Files:**
- Create: `Packages/OsaurusCore/Models/Palace/PalaceModels.swift`

(No dedicated test — pure data structs; covered by Task 3+ tests.)

- [ ] **Step 1: Create PalaceModels.swift**

```swift
//
//  PalaceModels.swift
//  osaurus
//
//  DTOs for the Palace verbatim-memory subsystem (wings → rooms → drawers).
//  Verbatim contract: `PalaceDrawer.content` is stored exactly as provided —
//  no summarization, trimming, or rewriting on the write path.
//

import Foundation

public struct PalaceWing: Sendable, Equatable {
    public let id: String
    public let name: String
    public let displayName: String?
    public let kind: String  // project | person | agent | system
    public let agentId: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        displayName: String? = nil,
        kind: String = "project",
        agentId: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.agentId = agentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PalaceRoom: Sendable, Equatable {
    public let id: String
    public let wingId: String
    public let name: String

    public init(id: String = UUID().uuidString, wingId: String, name: String) {
        self.id = id
        self.wingId = wingId
        self.name = name
    }
}

public struct PalaceDrawer: Sendable, Equatable {
    public let id: String
    public let wingId: String
    public let roomId: String
    public let content: String
    public let blobRef: String?
    public let sourceFile: String?
    public let sourceLineStart: Int?
    public let sourceLineEnd: Int?
    public let addedBy: String
    public let contentHash: String
    public let charOffset: Int?
    public let createdAt: String
    public let metadataJSON: String?

    public init(
        id: String = UUID().uuidString,
        wingId: String,
        roomId: String,
        content: String,
        blobRef: String? = nil,
        sourceFile: String? = nil,
        sourceLineStart: Int? = nil,
        sourceLineEnd: Int? = nil,
        addedBy: String = "system",
        contentHash: String,
        charOffset: Int? = nil,
        createdAt: String,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.wingId = wingId
        self.roomId = roomId
        self.content = content
        self.blobRef = blobRef
        self.sourceFile = sourceFile
        self.sourceLineStart = sourceLineStart
        self.sourceLineEnd = sourceLineEnd
        self.addedBy = addedBy
        self.contentHash = contentHash
        self.charOffset = charOffset
        self.createdAt = createdAt
        self.metadataJSON = metadataJSON
    }
}

/// One search result. `score` semantics depend on `matchType`:
/// vector → cosine similarity in [-1, 1] (higher is better);
/// fts → bm25 rank converted to a positive "higher is better" value.
public struct PalaceSearchHit: Sendable {
    public enum MatchType: String, Sendable {
        case vector
        case fts
    }

    public let drawer: PalaceDrawer
    public let wingName: String
    public let roomName: String
    public let score: Double
    public let matchType: MatchType
}

public struct PalaceStatus: Sendable, Equatable {
    public let wingCount: Int
    public let roomCount: Int
    public let drawerCount: Int
    public let embeddedDrawerCount: Int
    public let embeddingBackend: String
    public let enabled: Bool
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --package-path Packages/OsaurusCore --target OsaurusCore 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/OsaurusCore/Models/Palace/PalaceModels.swift
git commit -m "palace: wing/room/drawer DTOs"
```

---

### Task 3: PalaceDatabase — schema v1, CRUD, FTS5, embeddings

**Files:**
- Create: `Packages/OsaurusCore/Storage/PalaceDatabase.swift`
- Test: `Packages/OsaurusCore/Tests/Palace/PalaceDatabaseTests.swift`

Design notes (all mirrored from `RouterBillingDatabase.swift` / `MemoryDatabase.swift`):
- `final class`, `@unchecked Sendable`, `shared` singleton, serial `DispatchQueue`, instantiable for tests via `openInMemory()`.
- `open()` waits on `StorageMutationGate.blockingAwaitNotMutating()`, ensures `OsaurusPaths.palace()` exists, opens via `OsaurusStorageOpener.open(path:)` (constraint 3: this is the only place the DB path is resolved, and it comes from `OsaurusPaths.palaceDatabaseFile()`), runs migrations, registers an `OsaurusDatabaseHandle` named `"palace"`.
- Failed migration closes the half-open connection (the `MemoryDatabase.open()` lesson at `MemoryDatabase.swift:130-146` — leaving `db` set turns retries into no-op successes).
- Schema v1 creates taxonomy + drawers + embeddings + FTS5 external-content mirror with ai/ad/au triggers (`migrateToV6` pattern in `MemoryDatabase.swift:337-459`). KG tables land in Phase 1 as v2; tunnels in Phase 2 as v3.
- Forward-version fail-fast: refuse to open `user_version >` build's latest.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  PalaceDatabaseTests.swift
//  osaurusTests
//
//  Schema, CRUD, dedup, scoping, and FTS-sync coverage for PalaceDatabase.
//  Runs against an in-memory database — never touches ~/.osaurus.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct PalaceDatabaseTests {

    private func makeDB() throws -> PalaceDatabase {
        let db = PalaceDatabase()
        try db.openInMemory()
        return db
    }

    /// Insert helper: ensures taxonomy then files one drawer.
    @discardableResult
    private func addDrawer(
        _ db: PalaceDatabase,
        wing: String = "test_wing",
        room: String = "general",
        content: String
    ) throws -> PalaceDrawer {
        let wingRow = try db.ensureWing(name: wing)
        let roomRow = try db.ensureRoom(wingId: wingRow.id, name: room)
        let drawer = PalaceDrawer(
            wingId: wingRow.id,
            roomId: roomRow.id,
            content: content,
            contentHash: PalaceDatabase.contentHash(content),
            createdAt: "2026-07-02T00:00:00Z"
        )
        try db.insertDrawer(drawer)
        return drawer
    }

    @Test func openInMemory_startsEmpty() throws {
        let db = try makeDB()
        #expect(try db.countDrawers() == 0)
        #expect(try db.listWings().isEmpty)
    }

    @Test func ensureWing_isIdempotent() throws {
        let db = try makeDB()
        let a = try db.ensureWing(name: "vault")
        let b = try db.ensureWing(name: "vault")
        #expect(a.id == b.id)
        #expect(try db.listWings().count == 1)
    }

    @Test func ensureRoom_isIdempotent_perWing() throws {
        let db = try makeDB()
        let wing = try db.ensureWing(name: "vault")
        let other = try db.ensureWing(name: "other")
        let r1 = try db.ensureRoom(wingId: wing.id, name: "dreams")
        let r2 = try db.ensureRoom(wingId: wing.id, name: "dreams")
        let r3 = try db.ensureRoom(wingId: other.id, name: "dreams")
        #expect(r1.id == r2.id)
        #expect(r1.id != r3.id)  // same name, different wing → different room
    }

    @Test func insert_get_roundTrip_isVerbatim() throws {
        let db = try makeDB()
        let content = "  Verbatim!  \n\twith whitespace preserved \u{1F409}  "
        let inserted = try addDrawer(db, content: content)
        let fetched = try db.getDrawer(id: inserted.id)
        #expect(fetched?.content == content)  // byte-for-byte, no trimming
        #expect(fetched?.contentHash == PalaceDatabase.contentHash(content))
    }

    @Test func findDrawerByHash_dedup() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "same content")
        let hash = PalaceDatabase.contentHash("same content")
        let hit = try db.findDrawer(wingId: drawer.wingId, roomId: drawer.roomId, contentHash: hash)
        #expect(hit?.id == drawer.id)
        let miss = try db.findDrawer(wingId: drawer.wingId, roomId: drawer.roomId,
                                     contentHash: PalaceDatabase.contentHash("different"))
        #expect(miss == nil)
    }

    @Test func updateDrawer_rewritesContentAndHash() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "before")
        let updated = try db.updateDrawerContent(id: drawer.id, content: "after")
        #expect(updated)
        let fetched = try db.getDrawer(id: drawer.id)
        #expect(fetched?.content == "after")
        #expect(fetched?.contentHash == PalaceDatabase.contentHash("after"))
    }

    @Test func deleteDrawer_removesRowAndEmbedding() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "to be deleted")
        try db.storeEmbedding(drawerId: drawer.id, vector: [0.1, 0.2], model: "test")
        #expect(try db.deleteDrawer(id: drawer.id))
        #expect(try db.getDrawer(id: drawer.id) == nil)
        #expect(try db.loadEmbeddings(wingId: nil, roomId: nil).isEmpty)
        #expect(!(try db.deleteDrawer(id: drawer.id)))  // second delete: no row
    }

    @Test func listDrawers_scopesByWingAndRoom() throws {
        let db = try makeDB()
        try addDrawer(db, wing: "a", room: "r1", content: "one")
        try addDrawer(db, wing: "a", room: "r2", content: "two")
        try addDrawer(db, wing: "b", room: "r1", content: "three")

        let wingA = try db.getWing(name: "a")!
        let all = try db.listDrawers(wingId: nil, roomId: nil, limit: 100, offset: 0)
        let onlyA = try db.listDrawers(wingId: wingA.id, roomId: nil, limit: 100, offset: 0)
        let roomR1 = try db.ensureRoom(wingId: wingA.id, name: "r1")
        let onlyAR1 = try db.listDrawers(wingId: wingA.id, roomId: roomR1.id, limit: 100, offset: 0)

        #expect(all.count == 3)
        #expect(onlyA.count == 2)
        #expect(onlyAR1.count == 1)
        #expect(onlyAR1.first?.content == "one")
        // Scoped results are a subset of the global list (spec §13.1).
        let allIds = Set(all.map(\.id))
        #expect(Set(onlyA.map(\.id)).isSubset(of: allIds))
    }

    @Test func ftsSearch_findsInsertedContent_andTracksUpdatesDeletes() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "the GraphQL migration decision")
        try addDrawer(db, content: "an unrelated note about swimming")

        let hits = try db.ftsSearch(query: "graphql", wingId: nil, roomId: nil, limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.drawer.id == drawer.id)

        // Update re-syncs the FTS mirror (au trigger).
        _ = try db.updateDrawerContent(id: drawer.id, content: "now about kubernetes")
        #expect(try db.ftsSearch(query: "graphql", wingId: nil, roomId: nil, limit: 10).isEmpty)
        #expect(try db.ftsSearch(query: "kubernetes", wingId: nil, roomId: nil, limit: 10).count == 1)

        // Delete drops it from the index (ad trigger).
        _ = try db.deleteDrawer(id: drawer.id)
        #expect(try db.ftsSearch(query: "kubernetes", wingId: nil, roomId: nil, limit: 10).isEmpty)
    }

    @Test func ftsSearch_isSafeWithQuotesAndOperators() throws {
        let db = try makeDB()
        try addDrawer(db, content: "content with \"quotes\" and AND OR NOT operators")
        // Must not throw an FTS5 syntax error — the query is token-quoted.
        let hits = try db.ftsSearch(query: "\"quotes\" AND(", wingId: nil, roomId: nil, limit: 10)
        #expect(hits.count == 1)
    }

    @Test func embeddings_roundTrip_andScoping() throws {
        let db = try makeDB()
        let d1 = try addDrawer(db, wing: "a", content: "first")
        let d2 = try addDrawer(db, wing: "b", content: "second")
        try db.storeEmbedding(drawerId: d1.id, vector: [1, 0, 0], model: "test")
        try db.storeEmbedding(drawerId: d2.id, vector: [0, 1, 0], model: "test")

        let all = try db.loadEmbeddings(wingId: nil, roomId: nil)
        #expect(all.count == 2)
        let wingA = try db.getWing(name: "a")!
        let scoped = try db.loadEmbeddings(wingId: wingA.id, roomId: nil)
        #expect(scoped.count == 1)
        #expect(scoped.first?.drawerId == d1.id)
        #expect(scoped.first?.vector == [1, 0, 0])

        // Upsert replaces.
        try db.storeEmbedding(drawerId: d1.id, vector: [0.5, 0.5, 0], model: "test2")
        let replaced = try db.loadEmbeddings(wingId: wingA.id, roomId: nil)
        #expect(replaced.first?.vector == [0.5, 0.5, 0])
    }

    @Test func status_counts() throws {
        let db = try makeDB()
        let d = try addDrawer(db, wing: "a", room: "r1", content: "x")
        try addDrawer(db, wing: "a", room: "r2", content: "y")
        try db.storeEmbedding(drawerId: d.id, vector: [1], model: "test")
        #expect(try db.countWings() == 1)
        #expect(try db.countRooms() == 2)
        #expect(try db.countDrawers() == 2)
        #expect(try db.countEmbeddedDrawers() == 1)
    }

    @Test func forwardVersion_isRefused() throws {
        let db = PalaceDatabase()
        try db.openInMemory()
        try db.debugSetSchemaVersion(999)
        db.close()
        // Reopening the same in-memory DB isn't possible; assert via a
        // second connection against a temp file instead.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("palace-db-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("palace.sqlite").path
        let first = PalaceDatabase()
        try first.open(atPath: path)
        try first.debugSetSchemaVersion(999)
        first.close()
        let second = PalaceDatabase()
        #expect(throws: (any Error).self) {
            try second.open(atPath: path)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/OsaurusCore --filter PalaceDatabaseTests`
Expected: FAIL — `cannot find 'PalaceDatabase' in scope`.

- [ ] **Step 3: Create PalaceDatabase.swift**

```swift
//
//  PalaceDatabase.swift
//  osaurus
//
//  SQLite database for the Palace verbatim-memory subsystem.
//  WAL mode, serial queue, versioned migrations — same discipline as
//  MemoryDatabase / RouterBillingDatabase.
//
//  Schema v1:
//    palace_wings      — taxonomy: top-level scopes (project/person/agent/system)
//    palace_rooms      — taxonomy: (wing, name)-unique subdivisions
//    palace_drawers    — verbatim text chunks; content stored exactly as given
//    palace_embeddings — one vector per drawer (Float32 LE blob), upserted
//    fts_palace_drawers — FTS5 external-content mirror of drawer content
//
//  KG tables arrive in Phase 1 (v2); tunnels in Phase 2 (v3).
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum PalaceDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case databaseFromNewerVersion(found: Int, expected: Int)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open palace database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Palace migration failed: \(msg)"
        case .databaseFromNewerVersion(let found, let expected):
            return
                "Palace database is schema v\(found) but this build supports up to v\(expected). Refusing to open to avoid forward-version corruption."
        case .notOpen: return "Palace database is not open"
        }
    }
}

public final class PalaceDatabase: @unchecked Sendable {
    public static let shared = PalaceDatabase()

    /// Highest schema version this build knows how to produce. Opening a DB
    /// stamped newer than this is refused (forward-version fail-fast).
    private static let latestSchemaVersion = 1

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.palace.database")

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        try open(atPath: OsaurusPaths.palaceDatabaseFile().path)
    }

    /// Open at an explicit path. Production callers use `open()`; tests use
    /// a temp path to exercise the on-disk open flow.
    func open(atPath path: String) throws {
        // See `ChatHistoryDatabase.open()` for the gate rationale — every
        // `*Database.open()` parks while a key rotation is in flight so we
        // can't open a half-rekeyed file.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(
                URL(fileURLWithPath: path).deletingLastPathComponent())
            do {
                db = try OsaurusStorageOpener.open(path: path)
            } catch let error as EncryptedSQLiteError {
                throw PalaceDatabaseError.failedToOpen(error.localizedDescription)
            }
            do {
                try runMigrations()
            } catch {
                // Close the half-opened connection before rethrowing —
                // leaving `db` set turns every retry of `open()` into an
                // instant no-op success against the unmigrated schema
                // (the MemoryDatabase.open() lesson).
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "palace",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. **Plaintext.**
    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(
                path: ":memory:",
                key: nil,
                applyPerfPragmas: false
            )
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "palace")
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Schema & Migrations

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        guard currentVersion <= Self.latestSchemaVersion else {
            throw PalaceDatabaseError.databaseFromNewerVersion(
                found: currentVersion,
                expected: Self.latestSchemaVersion
            )
        }
        if currentVersion < 1 {
            try runMigrationStep(1, migrateToV1)
        }
    }

    private func runMigrationStep(_ version: Int, _ body: () throws -> Void) throws {
        try executeRaw("BEGIN TRANSACTION")
        do {
            try body()
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw PalaceDatabaseError.migrationFailed("v\(version): \(error.localizedDescription)")
        }
    }

    private func getSchemaVersion() throws -> Int {
        var version = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    /// Test hook: stamp an arbitrary schema version so forward-version
    /// refusal can be exercised.
    func debugSetSchemaVersion(_ version: Int) throws {
        try queue.sync { try setSchemaVersion(version) }
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_wings (
                    id            TEXT PRIMARY KEY,
                    name          TEXT NOT NULL UNIQUE,
                    display_name  TEXT,
                    kind          TEXT NOT NULL DEFAULT 'project',
                    agent_id      TEXT,
                    created_at    TEXT NOT NULL,
                    updated_at    TEXT NOT NULL
                )
            """
        )
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_rooms (
                    id       TEXT PRIMARY KEY,
                    wing_id  TEXT NOT NULL REFERENCES palace_wings(id),
                    name     TEXT NOT NULL,
                    UNIQUE(wing_id, name)
                )
            """
        )
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_drawers (
                    id                 TEXT PRIMARY KEY,
                    wing_id            TEXT NOT NULL,
                    room_id            TEXT NOT NULL,
                    content            TEXT NOT NULL,
                    blob_ref           TEXT,
                    source_file        TEXT,
                    source_line_start  INTEGER,
                    source_line_end    INTEGER,
                    added_by           TEXT NOT NULL DEFAULT 'system',
                    content_hash       TEXT NOT NULL,
                    char_offset        INTEGER,
                    created_at         TEXT NOT NULL,
                    metadata_json      TEXT
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_palace_drawers_wing_room ON palace_drawers(wing_id, room_id)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_palace_drawers_hash ON palace_drawers(content_hash)"
        )

        // One vector per drawer. Float32 little-endian blob; `dims` is
        // denormalized so a model change is detectable per row.
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_embeddings (
                    drawer_id  TEXT PRIMARY KEY,
                    dims       INTEGER NOT NULL,
                    model      TEXT NOT NULL,
                    vector     BLOB NOT NULL
                )
            """
        )

        // FTS5 external-content mirror + sync triggers — same pattern as
        // MemoryDatabase.migrateToV6 (fts_pinned). SQLCipher transparently
        // encrypts the FTS5 shadow tables when the DB is encrypted.
        try executeRaw(
            """
                CREATE VIRTUAL TABLE IF NOT EXISTS fts_palace_drawers USING fts5(
                    content,
                    content='palace_drawers',
                    content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                )
            """
        )
        try executeRaw(
            """
                CREATE TRIGGER IF NOT EXISTS palace_drawers_ai AFTER INSERT ON palace_drawers BEGIN
                    INSERT INTO fts_palace_drawers(rowid, content) VALUES (new.rowid, new.content);
                END
            """
        )
        try executeRaw(
            """
                CREATE TRIGGER IF NOT EXISTS palace_drawers_ad AFTER DELETE ON palace_drawers BEGIN
                    INSERT INTO fts_palace_drawers(fts_palace_drawers, rowid, content)
                    VALUES('delete', old.rowid, old.content);
                END
            """
        )
        try executeRaw(
            """
                CREATE TRIGGER IF NOT EXISTS palace_drawers_au AFTER UPDATE ON palace_drawers BEGIN
                    INSERT INTO fts_palace_drawers(fts_palace_drawers, rowid, content)
                    VALUES('delete', old.rowid, old.content);
                    INSERT INTO fts_palace_drawers(rowid, content) VALUES (new.rowid, new.content);
                END
            """
        )

        try setSchemaVersion(1)
    }

    // MARK: - Hashing

    /// SHA256 hex of the exact content string (UTF-8). Dedup key.
    public static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Wings

    @discardableResult
    public func ensureWing(name: String, kind: String = "project", agentId: String? = nil) throws
        -> PalaceWing
    {
        if let existing = try getWing(name: name) { return existing }
        let now = Self.iso8601Now()
        let wing = PalaceWing(name: name, kind: kind, agentId: agentId, createdAt: now, updatedAt: now)
        try executeUpdate(
            """
            INSERT INTO palace_wings (id, name, display_name, kind, agent_id, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(name) DO NOTHING
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: wing.id)
            Self.bindText(stmt, index: 2, value: wing.name)
            Self.bindText(stmt, index: 3, value: wing.displayName)
            Self.bindText(stmt, index: 4, value: wing.kind)
            Self.bindText(stmt, index: 5, value: wing.agentId)
            Self.bindText(stmt, index: 6, value: wing.createdAt)
            Self.bindText(stmt, index: 7, value: wing.updatedAt)
        }
        // Re-read: a concurrent insert may have won the ON CONFLICT race.
        guard let row = try getWing(name: name) else {
            throw PalaceDatabaseError.failedToExecute("ensureWing(\(name)) inserted no row")
        }
        return row
    }

    public func getWing(name: String) throws -> PalaceWing? {
        var wing: PalaceWing?
        try prepareAndExecute(
            "SELECT id, name, display_name, kind, agent_id, created_at, updated_at FROM palace_wings WHERE name = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: name) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    wing = Self.wingFromRow(stmt)
                }
            }
        )
        return wing
    }

    public func listWings() throws -> [PalaceWing] {
        var wings: [PalaceWing] = []
        try prepareAndExecute(
            "SELECT id, name, display_name, kind, agent_id, created_at, updated_at FROM palace_wings ORDER BY name",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    wings.append(Self.wingFromRow(stmt))
                }
            }
        )
        return wings
    }

    private static func wingFromRow(_ stmt: OpaquePointer) -> PalaceWing {
        PalaceWing(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            displayName: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
            kind: String(cString: sqlite3_column_text(stmt, 3)),
            agentId: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            createdAt: String(cString: sqlite3_column_text(stmt, 5)),
            updatedAt: String(cString: sqlite3_column_text(stmt, 6))
        )
    }

    // MARK: - Rooms

    @discardableResult
    public func ensureRoom(wingId: String, name: String) throws -> PalaceRoom {
        if let existing = try getRoom(wingId: wingId, name: name) { return existing }
        let room = PalaceRoom(wingId: wingId, name: name)
        try executeUpdate(
            """
            INSERT INTO palace_rooms (id, wing_id, name) VALUES (?1, ?2, ?3)
            ON CONFLICT(wing_id, name) DO NOTHING
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: room.id)
            Self.bindText(stmt, index: 2, value: room.wingId)
            Self.bindText(stmt, index: 3, value: room.name)
        }
        guard let row = try getRoom(wingId: wingId, name: name) else {
            throw PalaceDatabaseError.failedToExecute("ensureRoom(\(name)) inserted no row")
        }
        return row
    }

    public func getRoom(wingId: String, name: String) throws -> PalaceRoom? {
        var room: PalaceRoom?
        try prepareAndExecute(
            "SELECT id, wing_id, name FROM palace_rooms WHERE wing_id = ?1 AND name = ?2",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: wingId)
                Self.bindText(stmt, index: 2, value: name)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    room = PalaceRoom(
                        id: String(cString: sqlite3_column_text(stmt, 0)),
                        wingId: String(cString: sqlite3_column_text(stmt, 1)),
                        name: String(cString: sqlite3_column_text(stmt, 2))
                    )
                }
            }
        )
        return room
    }

    public func listRooms(wingId: String) throws -> [PalaceRoom] {
        var rooms: [PalaceRoom] = []
        try prepareAndExecute(
            "SELECT id, wing_id, name FROM palace_rooms WHERE wing_id = ?1 ORDER BY name",
            bind: { stmt in Self.bindText(stmt, index: 1, value: wingId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rooms.append(
                        PalaceRoom(
                            id: String(cString: sqlite3_column_text(stmt, 0)),
                            wingId: String(cString: sqlite3_column_text(stmt, 1)),
                            name: String(cString: sqlite3_column_text(stmt, 2))
                        ))
                }
            }
        )
        return rooms
    }

    // MARK: - Drawers

    public func insertDrawer(_ drawer: PalaceDrawer) throws {
        try executeUpdate(
            """
            INSERT INTO palace_drawers
                (id, wing_id, room_id, content, blob_ref, source_file,
                 source_line_start, source_line_end, added_by, content_hash,
                 char_offset, created_at, metadata_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: drawer.id)
            Self.bindText(stmt, index: 2, value: drawer.wingId)
            Self.bindText(stmt, index: 3, value: drawer.roomId)
            Self.bindText(stmt, index: 4, value: drawer.content)
            Self.bindText(stmt, index: 5, value: drawer.blobRef)
            Self.bindText(stmt, index: 6, value: drawer.sourceFile)
            Self.bindInt(stmt, index: 7, value: drawer.sourceLineStart)
            Self.bindInt(stmt, index: 8, value: drawer.sourceLineEnd)
            Self.bindText(stmt, index: 9, value: drawer.addedBy)
            Self.bindText(stmt, index: 10, value: drawer.contentHash)
            Self.bindInt(stmt, index: 11, value: drawer.charOffset)
            Self.bindText(stmt, index: 12, value: drawer.createdAt)
            Self.bindText(stmt, index: 13, value: drawer.metadataJSON)
        }
    }

    private static let drawerColumns = """
        id, wing_id, room_id, content, blob_ref, source_file,
        source_line_start, source_line_end, added_by, content_hash,
        char_offset, created_at, metadata_json
        """

    public func getDrawer(id: String) throws -> PalaceDrawer? {
        var drawer: PalaceDrawer?
        try prepareAndExecute(
            "SELECT \(Self.drawerColumns) FROM palace_drawers WHERE id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    drawer = Self.drawerFromRow(stmt)
                }
            }
        )
        return drawer
    }

    public func findDrawer(wingId: String, roomId: String, contentHash: String) throws
        -> PalaceDrawer?
    {
        var drawer: PalaceDrawer?
        try prepareAndExecute(
            "SELECT \(Self.drawerColumns) FROM palace_drawers WHERE wing_id = ?1 AND room_id = ?2 AND content_hash = ?3 LIMIT 1",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: wingId)
                Self.bindText(stmt, index: 2, value: roomId)
                Self.bindText(stmt, index: 3, value: contentHash)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    drawer = Self.drawerFromRow(stmt)
                }
            }
        )
        return drawer
    }

    public func listDrawers(wingId: String?, roomId: String?, limit: Int, offset: Int) throws
        -> [PalaceDrawer]
    {
        var sql = "SELECT \(Self.drawerColumns) FROM palace_drawers"
        var conditions: [String] = []
        if wingId != nil { conditions.append("wing_id = ?1") }
        if roomId != nil { conditions.append("room_id = ?2") }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY created_at DESC LIMIT ?3 OFFSET ?4"

        var drawers: [PalaceDrawer] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                // Bind placeholders that appear in the final SQL only.
                if let wingId { Self.bindText(stmt, index: 1, value: wingId) }
                if let roomId { Self.bindText(stmt, index: 2, value: roomId) }
                sqlite3_bind_int(stmt, 3, Int32(max(1, min(limit, 500))))
                sqlite3_bind_int(stmt, 4, Int32(max(0, offset)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    drawers.append(Self.drawerFromRow(stmt))
                }
            }
        )
        return drawers
    }

    @discardableResult
    public func updateDrawerContent(id: String, content: String) throws -> Bool {
        var changed = false
        try prepareAndExecute(
            "UPDATE palace_drawers SET content = ?1, content_hash = ?2 WHERE id = ?3",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: content)
                Self.bindText(stmt, index: 2, value: Self.contentHash(content))
                Self.bindText(stmt, index: 3, value: id)
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw PalaceDatabaseError.failedToExecute("UPDATE step returned \(step)")
                }
            }
        )
        try execute { connection in
            changed = sqlite3_changes(connection) > 0
        }
        return changed
    }

    @discardableResult
    public func deleteDrawer(id: String) throws -> Bool {
        var changed = false
        try prepareAndExecute(
            "DELETE FROM palace_drawers WHERE id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id) },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw PalaceDatabaseError.failedToExecute("DELETE step returned \(step)")
                }
            }
        )
        try execute { connection in
            changed = sqlite3_changes(connection) > 0
        }
        if changed {
            try executeUpdate("DELETE FROM palace_embeddings WHERE drawer_id = ?1") { stmt in
                Self.bindText(stmt, index: 1, value: id)
            }
        }
        return changed
    }

    private static func drawerFromRow(_ stmt: OpaquePointer) -> PalaceDrawer {
        PalaceDrawer(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            wingId: String(cString: sqlite3_column_text(stmt, 1)),
            roomId: String(cString: sqlite3_column_text(stmt, 2)),
            content: String(cString: sqlite3_column_text(stmt, 3)),
            blobRef: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            sourceFile: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            sourceLineStart: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 6)),
            sourceLineEnd: sqlite3_column_type(stmt, 7) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 7)),
            addedBy: String(cString: sqlite3_column_text(stmt, 8)),
            contentHash: String(cString: sqlite3_column_text(stmt, 9)),
            charOffset: sqlite3_column_type(stmt, 10) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 10)),
            createdAt: String(cString: sqlite3_column_text(stmt, 11)),
            metadataJSON: sqlite3_column_text(stmt, 12).map { String(cString: $0) }
        )
    }

    // MARK: - FTS search

    public struct FTSHit: Sendable {
        public let drawer: PalaceDrawer
        /// bm25() rank — LOWER is better (SQLite convention). Callers
        /// convert to a "higher is better" score.
        public let rank: Double
    }

    /// FTS5 MATCH over drawer content, optionally scoped. The raw query is
    /// converted to a quoted-token AND query so user input can never be
    /// parsed as FTS5 syntax (`"foo" "bar"`).
    public func ftsSearch(query: String, wingId: String?, roomId: String?, limit: Int) throws
        -> [FTSHit]
    {
        let match = Self.ftsQuote(query)
        guard !match.isEmpty else { return [] }

        var sql = """
            SELECT \(Self.drawerColumns
                .split(separator: ",")
                .map { "d.\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: ", ")), bm25(fts_palace_drawers) AS rank
            FROM fts_palace_drawers f
            JOIN palace_drawers d ON d.rowid = f.rowid
            WHERE fts_palace_drawers MATCH ?1
            """
        if wingId != nil { sql += " AND d.wing_id = ?2" }
        if roomId != nil { sql += " AND d.room_id = ?3" }
        sql += " ORDER BY rank LIMIT ?4"

        var hits: [FTSHit] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: match)
                if let wingId { Self.bindText(stmt, index: 2, value: wingId) }
                if let roomId { Self.bindText(stmt, index: 3, value: roomId) }
                sqlite3_bind_int(stmt, 4, Int32(max(1, min(limit, 100))))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    hits.append(
                        FTSHit(
                            drawer: Self.drawerFromRow(stmt),
                            rank: sqlite3_column_double(stmt, 13)
                        ))
                }
            }
        )
        return hits
    }

    /// Convert free text to a safe FTS5 query — the exact
    /// `MemoryDatabase.ftsMatchQuery` sanitization (MemoryDatabase.swift:2295):
    /// scrub to alphanumerics/whitespace/-/_, then double-quote every token
    /// (implicit AND). Prevents user input from being parsed as FTS5
    /// operators. Empty result → caller returns no hits.
    static func ftsQuote(_ query: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_"))
        let scrubbed = String(query.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return
            scrubbed
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0)\"" }
            .joined(separator: " ")
    }

    // MARK: - Embeddings

    public struct EmbeddingRow: Sendable {
        public let drawerId: String
        public let model: String
        public let vector: [Float]
    }

    public func storeEmbedding(drawerId: String, vector: [Float], model: String) throws {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try executeUpdate(
            """
            INSERT INTO palace_embeddings (drawer_id, dims, model, vector)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(drawer_id) DO UPDATE SET
                dims = excluded.dims, model = excluded.model, vector = excluded.vector
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: drawerId)
            sqlite3_bind_int(stmt, 2, Int32(vector.count))
            Self.bindText(stmt, index: 3, value: model)
            blob.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(
                    stmt, 4, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransientBind)
            }
        }
    }

    /// Load embeddings, optionally scoped to a wing/room via a join on
    /// palace_drawers. Vector blobs decode as Float32 little-endian.
    public func loadEmbeddings(wingId: String?, roomId: String?) throws -> [EmbeddingRow] {
        var sql = """
            SELECT e.drawer_id, e.model, e.vector, e.dims
            FROM palace_embeddings e
            JOIN palace_drawers d ON d.id = e.drawer_id
            """
        var conditions: [String] = []
        if wingId != nil { conditions.append("d.wing_id = ?1") }
        if roomId != nil { conditions.append("d.room_id = ?2") }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }

        var rows: [EmbeddingRow] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let wingId { Self.bindText(stmt, index: 1, value: wingId) }
                if let roomId { Self.bindText(stmt, index: 2, value: roomId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let drawerId = String(cString: sqlite3_column_text(stmt, 0))
                    let model = String(cString: sqlite3_column_text(stmt, 1))
                    let dims = Int(sqlite3_column_int(stmt, 3))
                    guard let blobPtr = sqlite3_column_blob(stmt, 2) else { continue }
                    let blobLen = Int(sqlite3_column_bytes(stmt, 2))
                    guard blobLen == dims * MemoryLayout<Float>.size else { continue }
                    let vector = Data(bytes: blobPtr, count: blobLen).withUnsafeBytes {
                        Array($0.bindMemory(to: Float.self))
                    }
                    rows.append(EmbeddingRow(drawerId: drawerId, model: model, vector: vector))
                }
            }
        )
        return rows
    }

    // MARK: - Counts

    public func countWings() throws -> Int { try count("SELECT COUNT(*) FROM palace_wings") }
    public func countRooms() throws -> Int { try count("SELECT COUNT(*) FROM palace_rooms") }
    public func countDrawers() throws -> Int { try count("SELECT COUNT(*) FROM palace_drawers") }
    public func countEmbeddedDrawers() throws -> Int {
        try count("SELECT COUNT(*) FROM palace_embeddings")
    }

    private func count(_ sql: String) throws -> Int {
        var n = 0
        try prepareAndExecute(
            sql, bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    n = Int(sqlite3_column_int(stmt, 0))
                }
            })
        return n
    }

    // MARK: - Query plumbing (mirrors MemoryDatabase)

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw PalaceDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw PalaceDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw PalaceDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt
        else {
            throw PalaceDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    private func execute<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else { throw PalaceDatabaseError.notOpen }
            return try operation(connection)
        }
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard let connection = db else { throw PalaceDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK,
                let statement = stmt
            else {
                throw PalaceDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    @discardableResult
    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Bool {
        try prepareAndExecute(
            sql, bind: bind,
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    let connection = sqlite3_db_handle(stmt)
                    let extended = connection.map { sqlite3_extended_errcode($0) } ?? 0
                    let msg = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
                    throw PalaceDatabaseError.failedToExecute(
                        "step=\(step) extended=\(extended) msg=\(msg) sql=\(sql.prefix(120))")
                }
            })
        return true
    }

    // MARK: - Binding helpers

    /// SQLITE_TRANSIENT for blob binds (forces SQLite to copy the buffer).
    private static let sqliteTransientBind = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransientBind)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func bindInt(_ stmt: OpaquePointer, index: Int32, value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }
}
```

**Implementation caveats for this task (verify against source while coding):**
- Check how `MemoryDatabase` binds text (`sqliteTransient` at `MemoryDatabase.swift:2865-2871`) — if a shared `sqliteTransient` constant exists in the module, reuse it instead of redefining.
- `listDrawers`/`ftsSearch` build SQL with conditional placeholders — placeholder *numbers* must match the built SQL exactly. If `wingId == nil && roomId != nil`, `?2` appears without `?1`; SQLite allows gaps in numbered parameters, which is why explicit `?N` numbering is used instead of positional `?`.
- `bm25()` requires the FTS5 table name as its argument and is only valid in a MATCH query — already handled above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/OsaurusCore --filter PalaceDatabaseTests`
Expected: PASS (12 tests)

- [ ] **Step 5: Commit**

```bash
git add Packages/OsaurusCore/Storage/PalaceDatabase.swift \
        Packages/OsaurusCore/Tests/Palace/PalaceDatabaseTests.swift
git commit -m "palace: PalaceDatabase schema v1 — wings/rooms/drawers, FTS5 mirror, embeddings"
```

---

### Task 4: PalaceService + PalaceSearchService

**Files:**
- Create: `Packages/OsaurusCore/Services/Palace/PalaceService.swift`
- Create: `Packages/OsaurusCore/Services/Palace/PalaceSearchService.swift`
- Test: `Packages/OsaurusCore/Tests/Palace/PalaceSearchServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
//
//  PalaceSearchServiceTests.swift
//  osaurusTests
//
//  Pure ranking tests (hand-made vectors, no embedding model) + FTS
//  fallback path. The vector path with a real model is covered by the
//  integration test only when the model is present.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct PalaceSearchServiceTests {

    @Test func cosineSimilarity_ordersAndNormalizes() {
        // Identical direction → 1; orthogonal → 0; opposite → -1.
        #expect(abs(PalaceSearchService.cosineSimilarity([1, 0], [2, 0]) - 1.0) < 1e-6)
        #expect(abs(PalaceSearchService.cosineSimilarity([1, 0], [0, 3])) < 1e-6)
        #expect(abs(PalaceSearchService.cosineSimilarity([1, 0], [-1, 0]) + 1.0) < 1e-6)
        // Zero vector → 0 (not NaN).
        #expect(PalaceSearchService.cosineSimilarity([0, 0], [1, 0]) == 0)
        // Dimension mismatch → 0 (skipped, not crashed).
        #expect(PalaceSearchService.cosineSimilarity([1, 0, 0], [1, 0]) == 0)
    }

    @Test func rank_returnsTopKAboveThreshold() {
        let candidates: [PalaceDatabase.EmbeddingRow] = [
            .init(drawerId: "far", model: "t", vector: [-1, 0]),
            .init(drawerId: "near", model: "t", vector: [1, 0]),
            .init(drawerId: "mid", model: "t", vector: [0.7, 0.7]),
        ]
        let ranked = PalaceSearchService.rank(
            queryVector: [1, 0], candidates: candidates, limit: 2, maxDistance: 1.5)
        #expect(ranked.map(\.drawerId) == ["near", "mid"])
        // maxDistance 1.5 → similarity ≥ -0.5 → "far" (sim -1, distance 2) excluded
        // even when limit permits.
        let rankedAll = PalaceSearchService.rank(
            queryVector: [1, 0], candidates: candidates, limit: 10, maxDistance: 1.5)
        #expect(!rankedAll.map(\.drawerId).contains("far"))
    }

    @Test func search_fallsBackToFTS_whenBackendNone() async throws {
        let db = PalaceDatabase()
        try db.openInMemory()
        let wing = try db.ensureWing(name: "w")
        let room = try db.ensureRoom(wingId: wing.id, name: "r")
        let drawer = PalaceDrawer(
            wingId: wing.id, roomId: room.id,
            content: "verbatim quote about lucid dreaming",
            contentHash: PalaceDatabase.contentHash("verbatim quote about lucid dreaming"),
            createdAt: "2026-07-02T00:00:00Z")
        try db.insertDrawer(drawer)

        var config = PalaceConfiguration()
        config.embeddingBackend = "none"
        let hits = await PalaceSearchService.search(
            query: "lucid dreaming", wing: nil, room: nil, limit: 5,
            db: db, config: config)
        #expect(hits.count == 1)
        #expect(hits.first?.matchType == .fts)
        #expect(hits.first?.drawer.id == drawer.id)
        #expect(hits.first?.wingName == "w")
        #expect(hits.first?.roomName == "r")
    }

    @Test func search_scopesByWing() async throws {
        let db = PalaceDatabase()
        try db.openInMemory()
        for wingName in ["alpha", "beta"] {
            let wing = try db.ensureWing(name: wingName)
            let room = try db.ensureRoom(wingId: wing.id, name: "r")
            let content = "shared topic banana in \(wingName)"
            try db.insertDrawer(
                PalaceDrawer(
                    wingId: wing.id, roomId: room.id, content: content,
                    contentHash: PalaceDatabase.contentHash(content),
                    createdAt: "2026-07-02T00:00:00Z"))
        }
        var config = PalaceConfiguration()
        config.embeddingBackend = "none"
        let scoped = await PalaceSearchService.search(
            query: "banana", wing: "alpha", room: nil, limit: 10, db: db, config: config)
        #expect(scoped.count == 1)
        #expect(scoped.first?.wingName == "alpha")
        // Unknown wing → empty, not global leak.
        let unknown = await PalaceSearchService.search(
            query: "banana", wing: "nope", room: nil, limit: 10, db: db, config: config)
        #expect(unknown.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/OsaurusCore --filter PalaceSearchServiceTests`
Expected: FAIL — `cannot find 'PalaceSearchService' in scope`.

- [ ] **Step 3: Create PalaceService.swift**

```swift
//
//  PalaceService.swift
//  osaurus
//
//  CRUD + taxonomy orchestration for Palace. Verbatim contract: content is
//  filed exactly as provided. Dedup is exact content-hash within
//  (wing, room). Embedding is best-effort at write time — a drawer whose
//  embed failed still exists and is findable via FTS; `palace_status`
//  surfaces the pending count. No LLM calls anywhere on this path.
//

import Foundation

public enum PalaceServiceError: Error, LocalizedError {
    case disabled
    case contentTooLarge(Int)
    case drawerNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Palace is disabled. Set \"enabled\": true in config/palace.json."
        case .contentTooLarge(let count):
            return
                "Content is \(count) characters; the per-drawer limit is \(PalaceConfiguration.maxContentLength)."
        case .drawerNotFound(let id):
            return "No drawer with id \(id)."
        }
    }
}

public actor PalaceService {
    public static let shared = PalaceService()

    private let db: PalaceDatabase
    private let embedder: (@Sendable ([String]) async throws -> [[Float]])?

    /// Production init: shared DB + real embedding service.
    public init() {
        self.db = PalaceDatabase.shared
        self.embedder = { texts in
            try await EmbeddingService.shared.embed(texts: texts)
        }
    }

    /// Test init: explicit DB, optional fake embedder (nil → skip embedding).
    init(db: PalaceDatabase, embedder: (@Sendable ([String]) async throws -> [[Float]])?) {
        self.db = db
        self.embedder = embedder
    }

    /// Throws `.disabled` when the feature flag is off; opens the DB lazily
    /// on first use. Nothing under `~/.osaurus/palace/` is created until an
    /// enabled palace performs its first operation.
    private func ensureReady() throws -> PalaceConfiguration {
        let config = PalaceConfigurationStore.load()
        guard config.enabled else { throw PalaceServiceError.disabled }
        if !db.isOpen {
            try db.open()
        }
        return config
    }

    // MARK: - Status

    public func status() throws -> PalaceStatus {
        let config = try ensureReady()
        return PalaceStatus(
            wingCount: try db.countWings(),
            roomCount: try db.countRooms(),
            drawerCount: try db.countDrawers(),
            embeddedDrawerCount: try db.countEmbeddedDrawers(),
            embeddingBackend: config.embeddingBackend,
            enabled: true
        )
    }

    // MARK: - CRUD

    public struct AddResult: Sendable {
        public let drawer: PalaceDrawer
        public let deduped: Bool
        public let embedded: Bool
    }

    public func addDrawer(
        content: String,
        wing wingName: String?,
        room roomName: String?,
        sourceFile: String? = nil,
        addedBy: String = "agent",
        metadataJSON: String? = nil
    ) async throws -> AddResult {
        let config = try ensureReady()
        guard content.count <= PalaceConfiguration.maxContentLength else {
            throw PalaceServiceError.contentTooLarge(content.count)
        }

        let wing = try db.ensureWing(name: Self.slug(wingName ?? config.defaultWing))
        let room = try db.ensureRoom(wingId: wing.id, name: Self.slug(roomName ?? "general"))

        let hash = PalaceDatabase.contentHash(content)
        if let existing = try db.findDrawer(wingId: wing.id, roomId: room.id, contentHash: hash) {
            return AddResult(drawer: existing, deduped: true, embedded: false)
        }

        let drawer = PalaceDrawer(
            wingId: wing.id,
            roomId: room.id,
            content: content,
            sourceFile: sourceFile,
            addedBy: addedBy,
            contentHash: hash,
            createdAt: PalaceDatabase.iso8601Now(),
            metadataJSON: metadataJSON
        )
        try db.insertDrawer(drawer)

        let embedded = await embedBestEffort(drawerId: drawer.id, content: content, config: config)
        return AddResult(drawer: drawer, deduped: false, embedded: embedded)
    }

    public func getDrawer(id: String) throws -> PalaceDrawer? {
        _ = try ensureReady()
        return try db.getDrawer(id: id)
    }

    public func updateDrawer(id: String, content: String) async throws -> PalaceDrawer {
        let config = try ensureReady()
        guard content.count <= PalaceConfiguration.maxContentLength else {
            throw PalaceServiceError.contentTooLarge(content.count)
        }
        guard try db.updateDrawerContent(id: id, content: content) else {
            throw PalaceServiceError.drawerNotFound(id)
        }
        _ = await embedBestEffort(drawerId: id, content: content, config: config)
        guard let updated = try db.getDrawer(id: id) else {
            throw PalaceServiceError.drawerNotFound(id)
        }
        return updated
    }

    public func deleteDrawer(id: String) throws -> Bool {
        _ = try ensureReady()
        return try db.deleteDrawer(id: id)
    }

    public func listWings() throws -> [PalaceWing] {
        _ = try ensureReady()
        return try db.listWings()
    }

    public func listRooms(wing wingName: String) throws -> [PalaceRoom] {
        _ = try ensureReady()
        guard let wing = try db.getWing(name: Self.slug(wingName)) else { return [] }
        return try db.listRooms(wingId: wing.id)
    }

    public func listDrawers(wing wingName: String?, room roomName: String?, limit: Int, offset: Int)
        throws -> [PalaceDrawer]
    {
        _ = try ensureReady()
        var wingId: String?
        var roomId: String?
        if let wingName {
            guard let wing = try db.getWing(name: Self.slug(wingName)) else { return [] }
            wingId = wing.id
            if let roomName {
                guard let room = try db.getRoom(wingId: wing.id, name: Self.slug(roomName)) else {
                    return []
                }
                roomId = room.id
            }
        }
        return try db.listDrawers(wingId: wingId, roomId: roomId, limit: limit, offset: offset)
    }

    public func search(query: String, wing: String?, room: String?, limit: Int?) async throws
        -> [PalaceSearchHit]
    {
        let config = try ensureReady()
        return await PalaceSearchService.search(
            query: query,
            wing: wing.map(Self.slug),
            room: room.map(Self.slug),
            limit: limit ?? config.searchDefaultLimit,
            db: db,
            config: config
        )
    }

    // MARK: - Helpers

    /// Best-effort write-time embedding. Failure (model missing, Metal
    /// unavailable in tests, backend "none") leaves the drawer FTS-only;
    /// never throws.
    private func embedBestEffort(drawerId: String, content: String, config: PalaceConfiguration)
        async -> Bool
    {
        guard config.embeddingBackend == "mlx", let embedder else { return false }
        do {
            let vectors = try await embedder([content])
            guard let vector = vectors.first, !vector.isEmpty else { return false }
            try db.storeEmbedding(
                drawerId: drawerId, vector: vector, model: EmbeddingService.modelName)
            return true
        } catch {
            return false
        }
    }

    /// Normalize wing/room names to MemPalace-style slugs:
    /// lowercase, `[a-z0-9_]`, spaces/dashes → underscore.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            if ("a"..."z").contains(String(scalar)) || ("0"..."9").contains(String(scalar))
                || scalar == "_"
            {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "-" {
                out.append("_")
            }
            // Anything else is dropped.
        }
        while out.contains("__") {
            out = out.replacingOccurrences(of: "__", with: "_")
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "default" : trimmed
    }
}
```

- [ ] **Step 4: Create PalaceSearchService.swift**

```swift
//
//  PalaceSearchService.swift
//  osaurus
//
//  Scoped retrieval for Palace. Phase 0 strategy:
//    1. vector: embed the query, brute-force cosine over stored embeddings
//       (fine well past the <1k-drawer Phase 0 target; VecturaKit or an
//       ANN index replaces this in Phase 1 behind PalaceVectorStore).
//    2. fallback: FTS5 MATCH when the backend is "none", the query embed
//       fails, or no drawer has a vector yet.
//  Pure functions are static so ranking is unit-testable without a model.
//

import Foundation

public enum PalaceSearchService {

    /// Top-level search. Never throws: retrieval degradation (no model, no
    /// vectors) falls back to FTS; a scoping miss returns [].
    public static func search(
        query: String,
        wing wingName: String?,
        room roomName: String?,
        limit: Int,
        db: PalaceDatabase,
        config: PalaceConfiguration
    ) async -> [PalaceSearchHit] {
        // Resolve scope names → ids (and bail early on unknown scope).
        var wingId: String?
        var roomId: String?
        if let wingName {
            guard let wing = try? db.getWing(name: wingName), let wing else { return [] }
            wingId = wing.id
            if let roomName {
                guard let room = try? db.getRoom(wingId: wing.id, name: roomName), let room else {
                    return []
                }
                roomId = room.id
            }
        }

        let limit = max(1, min(limit, 50))

        if config.embeddingBackend == "mlx" {
            if let hits = await vectorSearch(
                query: query, wingId: wingId, roomId: roomId, limit: limit,
                maxDistance: config.maxDistance, db: db),
                !hits.isEmpty
            {
                return resolveNames(hits: hits, db: db)
            }
        }
        let ftsHits = (try? db.ftsSearch(query: query, wingId: wingId, roomId: roomId, limit: limit)) ?? []
        let mapped = ftsHits.map { hit in
            // bm25 rank is negative-is-better in SQLite (lower = better,
            // typically negative). Convert to a positive higher-is-better
            // score for a uniform envelope.
            RankedDrawer(drawerId: hit.drawer.id, drawer: hit.drawer, score: -hit.rank, matchType: .fts)
        }
        return resolveNames(hits: mapped, db: db)
    }

    // MARK: - Vector path

    private static func vectorSearch(
        query: String,
        wingId: String?,
        roomId: String?,
        limit: Int,
        maxDistance: Double,
        db: PalaceDatabase
    ) async -> [RankedDrawer]? {
        guard let queryVector = try? await EmbeddingService.shared.embed(texts: [query]).first,
            !queryVector.isEmpty
        else { return nil }
        guard let candidates = try? db.loadEmbeddings(wingId: wingId, roomId: roomId),
            !candidates.isEmpty
        else { return nil }

        let ranked = rank(
            queryVector: queryVector, candidates: candidates, limit: limit, maxDistance: maxDistance)
        return ranked.compactMap { scored in
            guard let drawer = try? db.getDrawer(id: scored.drawerId), let drawer else { return nil }
            return RankedDrawer(
                drawerId: scored.drawerId, drawer: drawer, score: scored.score, matchType: .vector)
        }
    }

    struct ScoredId: Sendable {
        let drawerId: String
        let score: Double
    }

    struct RankedDrawer: Sendable {
        let drawerId: String
        let drawer: PalaceDrawer
        let score: Double
        let matchType: PalaceSearchHit.MatchType
    }

    /// Brute-force cosine ranking. `maxDistance` uses cosine distance
    /// (1 - similarity); 2.0 admits everything. Dimension-mismatched
    /// candidates (stale model) score 0 and are naturally filtered by any
    /// maxDistance < 1.
    static func rank(
        queryVector: [Float],
        candidates: [PalaceDatabase.EmbeddingRow],
        limit: Int,
        maxDistance: Double
    ) -> [ScoredId] {
        candidates
            .map { ScoredId(drawerId: $0.drawerId, score: cosineSimilarity(queryVector, $0.vector)) }
            .filter { (1.0 - $0.score) <= maxDistance }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Plain-Swift cosine similarity. 128-dim × ≤1k candidates is
    /// microseconds; no Accelerate dependency needed in Phase 0.
    /// Returns 0 for zero vectors or dimension mismatch (skip, don't crash).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / ((normA * normB).squareRoot())
    }

    // MARK: - Name resolution

    /// Attach wing/room display names to hits (taxonomy is small; a
    /// two-map lookup beats a three-way join here).
    private static func resolveNames(hits: [RankedDrawer], db: PalaceDatabase) -> [PalaceSearchHit] {
        guard !hits.isEmpty else { return [] }
        let wings = (try? db.listWings()) ?? []
        let wingById = Dictionary(uniqueKeysWithValues: wings.map { ($0.id, $0) })
        var roomNameById: [String: String] = [:]
        for wing in wings {
            for room in (try? db.listRooms(wingId: wing.id)) ?? [] {
                roomNameById[room.id] = room.name
            }
        }
        return hits.map { hit in
            PalaceSearchHit(
                drawer: hit.drawer,
                wingName: wingById[hit.drawer.wingId]?.name ?? "?",
                roomName: roomNameById[hit.drawer.roomId] ?? "?",
                score: hit.score,
                matchType: hit.matchType
            )
        }
    }
}
```

**Implementation caveats:**
- `guard let wing = try? db.getWing(...), let wing` — double-optional unwrap from `try?` on an optional-returning throwing function; write it as `guard let wing = ((try? db.getWing(name: wingName)) ?? nil)` if the compiler rejects the shorthand.
- `EmbeddingService.modelName` is `"potion-base-4M"` (128-dim) — `MemoryConfiguration.embeddingModel`'s `nomic-embed-text-v1.5` default is NOT what `EmbeddingService` actually loads; do not copy that default into palace config assumptions.
- `PalaceService.slug` range-contains on `String(scalar)` is awkward — implement with `CharacterSet` like `OsaurusPaths.claudePluginSafeId` (line 584-603) if cleaner.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/OsaurusCore --filter PalaceSearchServiceTests`
Expected: PASS (4 tests)

- [ ] **Step 6: Commit**

```bash
git add Packages/OsaurusCore/Services/Palace/ \
        Packages/OsaurusCore/Tests/Palace/PalaceSearchServiceTests.swift
git commit -m "palace: PalaceService CRUD/dedup + brute-force vector search with FTS fallback"
```

---

### Task 5: palace_* tools + registration + composer gate + storage catalog

**Files:**
- Create: `Packages/OsaurusCore/Tools/Palace/PalaceTools.swift`
- Modify: `Packages/OsaurusCore/Tools/ToolRegistry.swift` (`registerBuiltInTools`, after the DB tool block ~line 234)
- Modify: `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift` (near `agentDBToolNames` ~line 1585, and in `resolveTools` before the `if !isManual` block ~line 2079)
- Modify: `Packages/OsaurusCore/Storage/StorageDatabaseCatalog.swift` (`databaseTargets()` core list ~line 38)

- [ ] **Step 1: Create PalaceTools.swift**

Nine tools. All follow the `SearchMemoryTool` idioms: `requireArgumentsDictionary` / `requireString` helpers, `ToolEnvelope.success(tool:text:)` / `ToolEnvelope.failure(kind:message:...)`. Every `execute()` starts with the shared enabled-check.

```swift
//
//  PalaceTools.swift
//  osaurus
//
//  Model-facing tools for the Palace verbatim-memory subsystem.
//  All nine register as built-ins; SystemPromptComposer strips them from
//  the model-visible schema when `palace.enabled` is false, and every
//  execute() re-checks the flag (defense in depth for frozen schemas and
//  direct HTTP tool calls).
//

import Foundation

/// Shared preflight: nil when Palace is usable, otherwise a ready-to-return
/// failure envelope.
private func palaceDisabledEnvelope(tool: String) -> String? {
    guard !PalaceConfigurationStore.load().enabled else { return nil }
    return ToolEnvelope.failure(
        kind: .unavailable,
        message:
            "Palace is disabled. Enable it by setting \"enabled\": true in ~/.osaurus/config/palace.json.",
        tool: tool,
        retryable: false
    )
}

private func palaceErrorEnvelope(_ error: Error, tool: String) -> String {
    ToolEnvelope.failure(
        kind: .executionError,
        message: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
        tool: tool,
        retryable: false
    )
}

// MARK: - palace_status

final class PalaceStatusTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_status"
    let description =
        "Report Palace verbatim-memory status: wing/room/drawer counts and embedding coverage."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        do {
            let status = try await PalaceService.shared.status()
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "wings": status.wingCount,
                    "rooms": status.roomCount,
                    "drawers": status.drawerCount,
                    "embedded_drawers": status.embeddedDrawerCount,
                    "embedding_backend": status.embeddingBackend,
                ])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_add_drawer

final class PalaceAddDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_add_drawer"
    let description =
        "File a VERBATIM text chunk into the Palace archive. Content is stored exactly as "
        + "given (no summarizing). Duplicate content in the same wing+room is deduplicated. "
        + "Use `wing` for the project/person scope and `room` for the topic."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "content": .object([
                "type": .string("string"),
                "description": .string("The exact text to preserve, verbatim."),
            ]),
            "wing": .object([
                "type": .string("string"),
                "description": .string("Scope slug (e.g. project name). Defaults to the configured default wing."),
            ]),
            "room": .object([
                "type": .string("string"),
                "description": .string("Topic slug within the wing. Defaults to `general`."),
            ]),
            "source_file": .object([
                "type": .string("string"),
                "description": .string("Optional origin path or URL for attribution."),
            ]),
            "metadata_json": .object([
                "type": .string("string"),
                "description": .string("Optional JSON object string with extra metadata (tags, session id)."),
            ]),
        ]),
        "required": .array([.string("content")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "non-empty text to store", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }

        // metadata_json, when present, must parse as a JSON object.
        var metadataJSON: String?
        if let raw = args["metadata_json"] as? String, !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
            else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`metadata_json` must be a JSON object string.",
                    field: "metadata_json",
                    expected: "e.g. {\"tags\": [\"dream\"]}",
                    tool: name)
            }
            metadataJSON = raw
        }

        do {
            let result = try await PalaceService.shared.addDrawer(
                content: content,
                wing: args["wing"] as? String,
                room: args["room"] as? String,
                sourceFile: args["source_file"] as? String,
                metadataJSON: metadataJSON
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "drawer_id": result.drawer.id,
                    "deduped": result.deduped,
                    "embedded": result.embedded,
                ])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_get_drawer

final class PalaceGetDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_get_drawer"
    let description = "Fetch the full verbatim content and metadata of one Palace drawer by id."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "drawer_id": .object([
                "type": .string("string"),
                "description": .string("Drawer id from palace_search / palace_add_drawer / palace_list_drawers."),
            ])
        ]),
        "required": .array([.string("drawer_id")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "drawer_id", expected: "a drawer id string", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }
        do {
            guard let drawer = try await PalaceService.shared.getDrawer(id: id) else {
                return ToolEnvelope.failure(
                    kind: .notFound, message: "No drawer with id \(id).", tool: name)
            }
            var result: [String: Any] = [
                "drawer_id": drawer.id,
                "content": drawer.content,
                "content_hash": drawer.contentHash,
                "created_at": drawer.createdAt,
                "added_by": drawer.addedBy,
            ]
            if let sourceFile = drawer.sourceFile { result["source_file"] = sourceFile }
            if let metadata = drawer.metadataJSON { result["metadata_json"] = metadata }
            return ToolEnvelope.success(tool: name, result: result)
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_update_drawer

final class PalaceUpdateDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_update_drawer"
    let description =
        "Replace the verbatim content of an existing Palace drawer (re-hashes and re-embeds)."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "drawer_id": .object([
                "type": .string("string"),
                "description": .string("Drawer id to update."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("The new exact text (full replacement)."),
            ]),
        ]),
        "required": .array([.string("drawer_id"), .string("content")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "drawer_id", expected: "a drawer id string", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "non-empty replacement text", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        do {
            let updated = try await PalaceService.shared.updateDrawer(id: id, content: content)
            return ToolEnvelope.success(
                tool: name,
                result: ["drawer_id": updated.id, "content_hash": updated.contentHash])
        } catch PalaceServiceError.drawerNotFound {
            return ToolEnvelope.failure(
                kind: .notFound, message: "No drawer with id \(id).", tool: name)
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_delete_drawer

final class PalaceDeleteDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_delete_drawer"
    let description = "Permanently delete one Palace drawer (and its search index entries) by id."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "drawer_id": .object([
                "type": .string("string"),
                "description": .string("Drawer id to delete."),
            ])
        ]),
        "required": .array([.string("drawer_id")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "drawer_id", expected: "a drawer id string", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }
        do {
            let deleted = try await PalaceService.shared.deleteDrawer(id: id)
            guard deleted else {
                return ToolEnvelope.failure(
                    kind: .notFound, message: "No drawer with id \(id).", tool: name)
            }
            return ToolEnvelope.success(tool: name, result: ["deleted": true, "drawer_id": id])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_list_wings / rooms / drawers

final class PalaceListWingsTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_list_wings"
    let description = "List all Palace wings (top-level scopes)."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        do {
            let wings = try await PalaceService.shared.listWings()
            let entries = wings.map { ["name": $0.name, "kind": $0.kind] }
            return ToolEnvelope.success(tool: name, result: ["wings": entries])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

final class PalaceListRoomsTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_list_rooms"
    let description = "List the rooms (topics) inside one Palace wing."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "wing": .object([
                "type": .string("string"),
                "description": .string("Wing slug to list rooms for."),
            ])
        ]),
        "required": .array([.string("wing")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let wingReq = requireString(args, "wing", expected: "a wing slug", tool: name)
        guard case .value(let wing) = wingReq else { return wingReq.failureEnvelope ?? "" }
        do {
            let rooms = try await PalaceService.shared.listRooms(wing: wing)
            return ToolEnvelope.success(
                tool: name, result: ["wing": wing, "rooms": rooms.map(\.name)])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

final class PalaceListDrawersTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_list_drawers"
    let description =
        "List Palace drawers (newest first), optionally scoped by wing and room. Returns previews; "
        + "use palace_get_drawer for full content."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "wing": .object([
                "type": .string("string"),
                "description": .string("Optional wing slug filter."),
            ]),
            "room": .object([
                "type": .string("string"),
                "description": .string("Optional room slug filter (requires wing)."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max results (default 20, max 100)."),
            ]),
            "offset": .object([
                "type": .string("integer"),
                "description": .string("Pagination offset (default 0)."),
            ]),
        ]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        if args["room"] != nil, args["wing"] == nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`room` requires `wing`.",
                field: "room",
                expected: "provide `wing` when filtering by room",
                tool: name)
        }
        let limit = max(1, min(100, ArgumentCoercion.int(args["limit"]) ?? 20))
        let offset = max(0, ArgumentCoercion.int(args["offset"]) ?? 0)
        do {
            let drawers = try await PalaceService.shared.listDrawers(
                wing: args["wing"] as? String,
                room: args["room"] as? String,
                limit: limit,
                offset: offset
            )
            let entries = drawers.map { drawer -> [String: Any] in
                [
                    "drawer_id": drawer.id,
                    "preview": String(drawer.content.prefix(160)),
                    "created_at": drawer.createdAt,
                ]
            }
            return ToolEnvelope.success(tool: name, result: ["drawers": entries, "count": entries.count])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_search

final class PalaceSearchTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_search"
    let description =
        "Semantic + keyword search over the Palace verbatim archive. Use when the user asks for "
        + "exact wording, quotes, or archived material. Scope with `wing`/`room` when known. "
        + "Returns previews with drawer ids; use palace_get_drawer for full text."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Natural-language query."),
            ]),
            "wing": .object([
                "type": .string("string"),
                "description": .string("Optional wing slug scope."),
            ]),
            "room": .object([
                "type": .string("string"),
                "description": .string("Optional room slug scope (requires wing)."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max results (default from palace.json, max 50)."),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let queryReq = requireString(args, "query", expected: "non-empty query text", tool: name)
        guard case .value(let query) = queryReq else { return queryReq.failureEnvelope ?? "" }
        if args["room"] != nil, args["wing"] == nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`room` requires `wing`.",
                field: "room",
                expected: "provide `wing` when scoping by room",
                tool: name)
        }
        do {
            let hits = try await PalaceService.shared.search(
                query: query,
                wing: args["wing"] as? String,
                room: args["room"] as? String,
                limit: ArgumentCoercion.int(args["limit"])
            )
            if hits.isEmpty {
                return ToolEnvelope.success(tool: name, text: "No drawers match '\(query)'.")
            }
            let entries = hits.map { hit -> [String: Any] in
                [
                    "drawer_id": hit.drawer.id,
                    "wing": hit.wingName,
                    "room": hit.roomName,
                    "score": (hit.score * 1000).rounded() / 1000,
                    "match": hit.matchType.rawValue,
                    "preview": String(hit.drawer.content.prefix(300)),
                ]
            }
            return ToolEnvelope.success(tool: name, result: ["hits": entries, "count": entries.count])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}
```

- [ ] **Step 2: Register in ToolRegistry**

In `ToolRegistry.registerBuiltInTools()` (`ToolRegistry.swift`, after `DBDropViewTool()` line ~234):

```swift
            // Palace verbatim-memory feature (docs/plans/palace-implementation-plan.md).
            // Registered as built-ins like db_*; SystemPromptComposer strips
            // them from the model-visible schema unless the GLOBAL
            // `palace.json: enabled` flag is true (default false). Each
            // tool's execute() re-checks the flag so a frozen schema or a
            // direct HTTP tool call can't reach a disabled palace.
            PalaceStatusTool(),
            PalaceSearchTool(),
            PalaceAddDrawerTool(),
            PalaceGetDrawerTool(),
            PalaceUpdateDrawerTool(),
            PalaceDeleteDrawerTool(),
            PalaceListWingsTool(),
            PalaceListRoomsTool(),
            PalaceListDrawersTool(),
```

- [ ] **Step 3: Add the composer gate**

In `SystemPromptComposer.swift`, next to `agentDBToolNames` (line ~1591):

```swift
    /// Tools belonging to the Palace feature
    /// (docs/plans/palace-implementation-plan.md). Unlike the per-agent
    /// `agentDBToolNames` gate, Palace is a GLOBAL opt-in
    /// (`config/palace.json: enabled`, default false), so the strip applies
    /// in both auto and manual modes with no `additionalToolNames`
    /// carve-out — feature off means no model ever sees the tools.
    static let palaceToolNames: Set<String> = [
        "palace_status", "palace_search", "palace_add_drawer", "palace_get_drawer",
        "palace_update_drawer", "palace_delete_drawer",
        "palace_list_wings", "palace_list_rooms", "palace_list_drawers",
    ]
```

In `resolveTools`, immediately BEFORE the `if !isManual {` per-agent gate block (line ~2079):

```swift
        // Palace global feature gate (default off). Applies in both auto
        // and manual modes — the palace.json flag governs the subsystem,
        // not per-agent tool hygiene. Execution re-checks the flag, so
        // this strip is schema hygiene, not the security boundary.
        if !PalaceConfigurationStore.load().enabled {
            for name in Self.palaceToolNames {
                byName.removeValue(forKey: name)
            }
        }
```

- [ ] **Step 4: Register in StorageDatabaseCatalog**

In `StorageDatabaseCatalog.databaseTargets()`, after the core `targets` array literal:

```swift
        // Palace verbatim-memory archive. Feature-flagged (default off) and
        // created lazily on first use, so unlike the always-created core
        // databases above it may legitimately not exist — and
        // `StorageExportService.rekeyDatabase` has no missing-file guard
        // (sqlite3_open on the absent palace/ directory fails and would
        // abort rotation mid-loop). Guard on existence like the
        // plugin/agent discovery below.
        let palacePath = OsaurusPaths.palaceDatabaseFile().path
        if FileManager.default.fileExists(atPath: palacePath) {
            targets.append(.init(label: "palace", path: palacePath))
        }
```

**Why existence-guarded (review finding, verified):** the plaintext-export path guards missing files (`exportOneDatabase`, `StorageExportService.swift:259`) but the rekey loop (`performRotation` → `rekeyDatabase`, `StorageExportService.swift:228-236, 322-326`) does a bare `sqlite3_open` and throws on failure — an unconditional palace entry would abort key rotation for every default (palace-disabled) install with at-rest encryption enabled, after the core DBs were already rekeyed but before the new key was installed. The other core DBs are all created at launch, so palace is the only target that can be missing.

- [ ] **Step 5: Build + run the full Palace filter**

Run: `swift build --package-path Packages/OsaurusCore 2>&1 | tail -3 && swift test --package-path Packages/OsaurusCore --filter Palace`
Expected: build succeeds; all Palace tests pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/OsaurusCore/Tools/Palace/PalaceTools.swift \
        Packages/OsaurusCore/Tools/ToolRegistry.swift \
        Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift \
        Packages/OsaurusCore/Storage/StorageDatabaseCatalog.swift
git commit -m "palace: nine palace_* tools, registry + composer gate (global, default off), storage-catalog entry"
```

---

### Task 6: Integration test — tool round-trip + flag gating + no-Memory-regression guard

**Files:**
- Create: `Packages/OsaurusCore/Tests/Palace/PalaceToolsIntegrationTests.swift`

- [ ] **Step 1: Write the integration tests**

```swift
//
//  PalaceToolsIntegrationTests.swift
//  osaurusTests
//
//  End-to-end tool round-trip against a temp OsaurusPaths root:
//  enable palace.json → palace_add_drawer → palace_search → palace_get_drawer,
//  plus the disabled-flag envelope and the composer strip set.
//  Uses embeddingBackend "none" so no model download is needed in CI —
//  the search path exercised here is FTS5.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PalaceToolsIntegrationTests {

    /// Runs `body` against an isolated OsaurusPaths root with palace
    /// enabled (embeddingBackend "none") and a fresh PalaceDatabase.shared
    /// state. Serialized suite: OsaurusPaths.overrideRoot is process-global.
    private func withEnabledPalace(_ body: () async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palace-integration-\(UUID().uuidString)", isDirectory: true)
        OsaurusPaths.overrideRoot = root
        PalaceConfigurationStore.invalidateCache()
        var config = PalaceConfiguration()
        config.enabled = true
        config.embeddingBackend = "none"
        PalaceConfigurationStore.save(config)
        defer {
            PalaceDatabase.shared.close()
            OsaurusPaths.overrideRoot = nil
            PalaceConfigurationStore.invalidateCache()
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    private func decodeEnvelope(_ json: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (obj as? [String: Any]) ?? [:]
    }

    @Test func disabled_flag_returns_unavailable_and_creates_nothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palace-disabled-\(UUID().uuidString)", isDirectory: true)
        OsaurusPaths.overrideRoot = root
        PalaceConfigurationStore.invalidateCache()
        defer {
            OsaurusPaths.overrideRoot = nil
            PalaceConfigurationStore.invalidateCache()
            try? FileManager.default.removeItem(at: root)
        }

        let result = try await PalaceAddDrawerTool().execute(
            argumentsJSON: #"{"content": "should not land"}"#)
        let envelope = try decodeEnvelope(result)
        #expect(envelope["ok"] as? Bool == false)
        // Nothing was created on disk — the disabled palace does zero work.
        #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.palaceDatabaseFile().path))
    }

    @Test func add_search_get_roundTrip() async throws {
        try await withEnabledPalace {
            let addResult = try await PalaceAddDrawerTool().execute(
                argumentsJSON:
                    #"{"content": "The verbatim GraphQL federation decision from March.", "wing": "test_project", "room": "decisions"}"#
            )
            let addEnvelope = try decodeEnvelope(addResult)
            #expect(addEnvelope["ok"] as? Bool == true)
            let drawerId =
                ((addEnvelope["result"] as? [String: Any])?["drawer_id"] as? String) ?? ""
            #expect(!drawerId.isEmpty)

            // Search finds it (FTS path), scoped and unscoped.
            for argsJSON in [
                #"{"query": "graphql federation"}"#,
                #"{"query": "graphql federation", "wing": "test_project", "room": "decisions"}"#,
            ] {
                let searchResult = try await PalaceSearchTool().execute(argumentsJSON: argsJSON)
                let searchEnvelope = try decodeEnvelope(searchResult)
                #expect(searchEnvelope["ok"] as? Bool == true)
                let hits =
                    ((searchEnvelope["result"] as? [String: Any])?["hits"] as? [[String: Any]]) ?? []
                #expect(hits.count == 1)
                #expect(hits.first?["drawer_id"] as? String == drawerId)
            }

            // Get returns the full verbatim content.
            let getResult = try await PalaceGetDrawerTool().execute(
                argumentsJSON: #"{"drawer_id": "\#(drawerId)"}"#)
            let getEnvelope = try decodeEnvelope(getResult)
            #expect(getEnvelope["ok"] as? Bool == true)
            let content = ((getEnvelope["result"] as? [String: Any])?["content"] as? String) ?? ""
            #expect(content == "The verbatim GraphQL federation decision from March.")

            // Dedup: identical re-add returns the same drawer, deduped=true.
            let dupResult = try await PalaceAddDrawerTool().execute(
                argumentsJSON:
                    #"{"content": "The verbatim GraphQL federation decision from March.", "wing": "test_project", "room": "decisions"}"#
            )
            let dupEnvelope = try decodeEnvelope(dupResult)
            let dup = (dupEnvelope["result"] as? [String: Any]) ?? [:]
            #expect(dup["deduped"] as? Bool == true)
            #expect(dup["drawer_id"] as? String == drawerId)

            // Status reflects one drawer.
            let statusResult = try await PalaceStatusTool().execute(argumentsJSON: "{}")
            let statusEnvelope = try decodeEnvelope(statusResult)
            let status = (statusEnvelope["result"] as? [String: Any]) ?? [:]
            #expect(status["drawers"] as? Int == 1)
            #expect(status["wings"] as? Int == 1)
        }
    }

    @Test func composer_strip_set_matches_registered_tool_names() {
        // The strip set and the registered tool names must stay in lockstep;
        // a palace tool missing from `palaceToolNames` would leak into the
        // schema while the flag is off.
        let registered: Set<String> = [
            PalaceStatusTool().name, PalaceSearchTool().name, PalaceAddDrawerTool().name,
            PalaceGetDrawerTool().name, PalaceUpdateDrawerTool().name,
            PalaceDeleteDrawerTool().name, PalaceListWingsTool().name,
            PalaceListRoomsTool().name, PalaceListDrawersTool().name,
        ]
        #expect(registered == SystemPromptComposer.palaceToolNames)
    }

    /// No-Memory-v2-regression guard: with palace enabled and used, the
    /// memory database file is untouched (Palace never opens or writes it).
    @Test func palace_usage_does_not_touch_memory_database() async throws {
        try await withEnabledPalace {
            _ = try await PalaceAddDrawerTool().execute(
                argumentsJSON: #"{"content": "palace-only write"}"#)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.memoryDatabaseFile().path))
        }
    }
}
```

**Implementation caveats:**
- `PalaceDatabase.shared` retains its open handle across tests in the same process — the `withEnabledPalace` teardown calls `close()` so the next test's overrideRoot gets a fresh open. If `PalaceService.shared`'s actor caches state beyond the DB handle, inject a fresh `PalaceService(db:embedder:)` instead of using `.shared` in these tests.
- The `.serialized` suite attribute alone is NOT enough: `OsaurusPaths.overrideRoot` is process-global and Swift Testing runs *suites* in parallel. Wrap every overrideRoot-mutating body in `await StoragePathsTestLock.shared.run { ... }` (`Tests/Helpers/StoragePathsTestLock.swift`) — same applies to the `PalaceConfigurationTests` temp-root helper.

- [ ] **Step 2: Run the full Palace suite + the Memory suite (regression gate)**

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test OSU_MODELS_DIR=/tmp/osaurus-test-models \
  swift test --package-path Packages/OsaurusCore --filter Palace
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test OSU_MODELS_DIR=/tmp/osaurus-test-models \
  swift test --package-path Packages/OsaurusCore --filter Memory
```
Expected: all PASS. The Memory filter run is the no-regression evidence for the PR description.

- [ ] **Step 3: Run the whole test suite once**

Run: `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test OSU_MODELS_DIR=/tmp/osaurus-test-models make test`
Expected: PASS (same pass/fail profile as bare `upstream/main` — run the baseline first if any pre-existing failures appear).

- [ ] **Step 4: Commit**

```bash
git add Packages/OsaurusCore/Tests/Palace/PalaceToolsIntegrationTests.swift
git commit -m "palace: integration tests — tool round-trip, flag gating, memory-untouched guard"
```

---

### Task 7: Lint + PR

Branch: `feat/palace-phase-0` (CONTRIBUTING prefers `feat/…` + Conventional Commits — use `feat(palace): …` subjects).

- [ ] **Step 1: swift-format lint (lefthook is not installed locally — run its pre-push job manually)**

```bash
xcrun swift-format lint --strict --recursive Packages/OsaurusCore/Models/Palace \
  Packages/OsaurusCore/Storage/PalaceDatabase.swift \
  Packages/OsaurusCore/Services/Palace Packages/OsaurusCore/Tools/Palace \
  Packages/OsaurusCore/Tests/Palace
```
Expected: no findings (fix and re-run otherwise).

- [ ] **Step 2: Add this plan document**

```bash
git add docs/plans/palace-implementation-plan.md
git commit -m "docs(palace): implementation plan (Phase 0-4 PR sequence)"
```

- [ ] **Step 3: Push branch + open PR**

```bash
git push -u origin feat/palace-phase-0
gh pr create --repo osaurus-ai/osaurus \
  --title "feat(palace): Phase 0 — MemPalace-style verbatim memory (schema, CRUD tools, basic search; flagged off)" \
  --body-file /tmp/palace-pr-body.md
```

PR body must include: motivation (verbatim archive vs Memory v2's distillation — "Memory = secretary, Palace = archive"), the flag posture (`palace.enabled=false`, zero default behavior change), the phased plan pointer, test evidence (Palace suite + Memory suite output), and the spec attribution note (MemPalace MIT).

---

## Self-review checklist (run after implementation, before PR)

1. `grep -rn "\.osaurus" Packages/OsaurusCore/{Storage/PalaceDatabase.swift,Services/Palace,Models/Palace,Tools/Palace}` → only comments; every path flows through `OsaurusPaths`.
2. Fresh-install posture: with no `palace.json`, `PalaceConfigurationStore.load().enabled == false`, no `~/.osaurus/palace/` directory is created, `resolveTools` strips all nine names, `registerBuiltInTools` still registers them (execution-side envelope covers direct calls).
3. Memory v2 diff audit: `git diff upstream/main -- Packages/OsaurusCore/Services/Memory Packages/OsaurusCore/Storage/MemoryDatabase.swift` → EMPTY.
4. All new SQL uses numbered placeholders and binds — no string interpolation of user content.
5. `swift test --filter Palace` + `--filter Memory` + `make test` all green.

## Post-review hardening (applied before PR)

A three-lens adversarial review (correctness / integration / spec) ran against the completed Phase 0 diff; confirmed findings were fixed before the PR:

1. **Key-rotation abort (high):** catalog entry made existence-guarded (see Task 5 Step 4 rationale).
2. **Int32 offset trap (high):** `listDrawers` binds `offset` via `sqlite3_bind_int64` — a model-hallucinated `{"offset": 3000000000}` used to trap `Int32(_:)` and crash the app.
3. **Plugin-host schema leak (medium):** `ToolRegistry.alwaysLoadedSpecs` now filters `palaceToolNames` when palace is disabled — `PluginHostAPI.applyAgentTools` builds schemas from `alwaysLoadedSpecs` directly and never runs the composer strip. The composer strip remains as defense in depth.
4. **Config cache staleness (medium):** `PalaceConfigurationStore` cache is keyed on palace.json's mtime, so hand-edits (the only Phase 0 enable/disable mechanism) take effect without an app restart; `save()` still updates the cache in-process ahead of the async disk write.
5. **Stale embedding on failed re-embed (medium):** `PalaceService.updateDrawer` drops the old vector before best-effort re-embedding, so a drawer whose re-embed failed can no longer be retrieved by its previous meaning.
6. **Dimension-mismatch hits (low):** `PalaceSearchService.rank` excludes candidates whose vector dimension differs from the query (stale model rows) instead of scoring them 0 — zero-scores passed the default `maxDistance` and suppressed the FTS fallback.

Plus two hygiene tweaks: `deleteDrawer` gained the file-standard `dispatchPrecondition(.notOnQueue)`, and the maintenance reopener reuses the recorded open path so a test-path database is never reopened at the production path. Each fix has a matching regression test.

A second close-out audit pass (Coder/SRE/independent-verifier) confirmed the above and surfaced one more: **drawer dedup had no DB-level `UNIQUE` constraint** (wings/rooms did) — only an app-level check-then-insert. Not currently exploitable (the `PalaceService` actor runs find→insert synchronously; first `await` is after the insert), but an invariant asymmetry a future suspension-point refactor would make live. Closed by adding `UNIQUE(wing_id, room_id, content_hash)` to schema v1 (zero migration — nothing deployed), `insertDrawer` `ON CONFLICT DO NOTHING`→Bool, and a service-level lost-race re-fetch, with DB-level + concurrent-collapse tests.

## Known deferrals (explicit, not forgotten)

- **MCP surface** (spec: "MCP: osaurus mcp exposes palace tools when enabled") — Phase 1. Verified: `GET /mcp/tools` (HTTPHandler.swift:9284) lists every globally-enabled registry tool and does NOT consult the composer strip — `db_*` tools appear there even with `dbEnabled=false` on every agent, so palace matches existing precedent. The execute-level flag check is the actual boundary on the `/mcp/call` path (which runs with no agent context).
- **Blob spillover** (`blob_ref`) — column exists; write path rejects >100k chars until Phase 1/2 decides the blob format.
- **`palace_rebuild_index` / VecturaKit / KG / tunnels / diaries / ingest / UI / retrieval fixture** — see PR sequence table.
