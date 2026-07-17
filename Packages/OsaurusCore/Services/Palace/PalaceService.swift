//
//  PalaceService.swift
//  osaurus
//
//  CRUD + taxonomy orchestration for Palace. Verbatim contract: content is
//  filed exactly as provided. Dedup is exact content-hash within
//  (wing, room). Embedding is best-effort at write time — a drawer whose
//  embed failed still exists and is findable via FTS; `palace_status`
//  surfaces embedding coverage. No LLM calls anywhere on this path.
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
                "Content is \(count) characters; the per-drawer limit is "
                + "\(PalaceConfiguration.maxContentLength)."
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
        // The pre-check above is the fast path; the DB `UNIQUE(wing_id,
        // room_id, content_hash)` is the authority. If insert reports a
        // conflict (an identical drawer landed between the check and here),
        // return the winner as a dedup rather than a phantom id.
        guard try db.insertDrawer(drawer) else {
            let winner =
                try db.findDrawer(wingId: wing.id, roomId: room.id, contentHash: hash) ?? drawer
            return AddResult(drawer: winner, deduped: true, embedded: false)
        }

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
        // Drop the OLD content's vector before best-effort re-embedding: if
        // the re-embed fails (model missing), a stale vector must not keep
        // answering semantic queries for meaning the drawer no longer has.
        // FTS stays correct either way via the update trigger.
        try? db.deleteEmbedding(drawerId: id)
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

    public func listDrawers(
        wing wingName: String?,
        room roomName: String?,
        limit: Int,
        offset: Int
    ) throws -> [PalaceDrawer] {
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
    private func embedBestEffort(
        drawerId: String,
        content: String,
        config: PalaceConfiguration
    ) async -> Bool {
        guard config.embeddingBackend == "mlx", let embedder else { return false }
        do {
            let vectors = try await embedder([content])
            guard let vector = vectors.first, !vector.isEmpty else { return false }
            try db.storeEmbedding(
                drawerId: drawerId,
                vector: vector,
                model: EmbeddingService.modelName
            )
            return true
        } catch {
            return false
        }
    }

    /// Normalize wing/room names to MemPalace-style slugs: lowercase,
    /// `[a-z0-9_]` only, spaces/dashes → underscore, everything else
    /// dropped. Same shape as `OsaurusPaths.claudePluginSafeId`.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let keep = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        let separators = CharacterSet(charactersIn: " -")
        var out = ""
        out.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            if keep.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if separators.contains(scalar) {
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
