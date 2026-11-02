import Foundation

/// One bounded worker over durable, per-chunk completion receipts. Missing model
/// assets or resident inference defer vectors without invalidating text search.
actor KnowledgeVectorIndexer {
    private let load: @Sendable (String, Int) throws -> [KnowledgeChunkHit]
    private let complete: @Sendable (KnowledgeChunkHit) throws -> Void
    private let embed: @Sendable (KnowledgeChunkHit) async throws -> Void
    private let enabled: @Sendable (String) async -> Bool
    private let allowed: @Sendable () async -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private let failure: @Sendable (Error) -> Void
    private var collections: [String] = []
    private var drainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryID: UUID?
    private var retryDelay: Duration = .seconds(1)

    init(
        load: @escaping @Sendable (String, Int) throws -> [KnowledgeChunkHit],
        complete: @escaping @Sendable (KnowledgeChunkHit) throws -> Void,
        embed: @escaping @Sendable (KnowledgeChunkHit) async throws -> Void,
        enabled: @escaping @Sendable (String) async -> Bool,
        allowed: @escaping @Sendable () async -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        failure: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.load = load; self.complete = complete; self.embed = embed
        self.enabled = enabled; self.allowed = allowed; self.sleep = sleep; self.failure = failure
    }

    deinit { drainTask?.cancel(); retryTask?.cancel() }

    func request(collectionId: String) {
        if !collections.contains(collectionId) { collections.append(collectionId) }
        startIfNeeded()
    }

    func cancel(collectionId: String) {
        collections.removeAll { $0 == collectionId }
        if collections.isEmpty {
            retryTask?.cancel(); retryTask = nil; retryID = nil
            retryDelay = .seconds(1)
        }
    }

    private func startIfNeeded() {
        guard !collections.isEmpty, drainTask == nil, retryTask == nil else { return }
        drainTask = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { drainTask = nil }
        while !Task.isCancelled, let collection = collections.first {
            guard await enabled(collection) else {
                collections.removeAll { $0 == collection }
                continue
            }
            guard await allowed() else { scheduleRetry(); return }
            do {
                let batch = try load(collection, 16)
                if batch.isEmpty {
                    collections.removeAll { $0 == collection }
                    continue
                }
                for hit in batch {
                    guard !Task.isCancelled, collections.contains(collection) else { break }
                    guard await enabled(collection) else {
                        collections.removeAll { $0 == collection }
                        break
                    }
                    guard await allowed() else { scheduleRetry(); return }
                    try await embed(hit)
                    // The receipt checks the current content again after the await.
                    // Never acknowledge replaced text or a deleted collection.
                    guard collections.contains(collection), await enabled(collection) else { break }
                    try complete(hit)
                    retryDelay = .seconds(1)
                }
                rotate(collection)
                await Task.yield()
            } catch {
                failure(error)
                rotate(collection)
                scheduleRetry()
                return
            }
        }
    }

    private func rotate(_ collection: String) {
        guard collections.first == collection else { return }
        collections.removeFirst(); collections.append(collection)
    }

    private func scheduleRetry() {
        // INVARIANT: a registration burst shares one failed attempt and one
        // bounded retry. SQLite, not this task, owns the missing-vector backlog.
        guard !collections.isEmpty, retryTask == nil else { return }
        let id = UUID(), delay = retryDelay
        retryID = id; retryDelay = min(delay * 2, .seconds(30))
        let sleep = self.sleep
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.retry(id: id)
        }
    }

    private func retry(id: UUID) {
        guard retryID == id else { return }
        retryTask = nil; retryID = nil
        startIfNeeded()
    }
}
