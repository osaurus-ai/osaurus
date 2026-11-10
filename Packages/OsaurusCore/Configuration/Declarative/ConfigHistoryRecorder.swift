//
//  ConfigHistoryRecorder.swift
//  osaurus
//
//  Turns landed applies into configuration history. `ConfigApplier.apply`
//  calls in with its lock held: once before the apply (a document that no
//  longer matches the latest snapshot was changed outside any apply and gets
//  an `.observed` row first) and once after (the new document, attributed to
//  the caller). Launch and opening History run the same drift check. A
//  failed write logs and never fails the apply.
//

import Foundation

enum ConfigHistoryRecorder {
    /// Tests point the recorder at their own database.
    @TaskLocal static var databaseOverride: ConfigHistoryDatabase?
    static var database: ConfigHistoryDatabase { databaseOverride ?? .shared }

    /// Newest snapshot sequence this process has seen; part of the
    /// Orchestrator's tool fingerprint and reported by `status`.
    @MainActor private(set) static var latestSequence: Int?

    static let didChange = Notification.Name("ai.osaurus.config.history.didChange")

    /// An apply landed when at least one row reports a change.
    static func landed(_ results: [ConfigApplyResult]) -> Bool {
        results.contains { $0.status == .done || $0.status == .started }
    }

    /// Writes an `.observed` row when the live document differs from the
    /// latest snapshot. On a Mac with no history yet this is sequence 0,
    /// the document as found.
    @discardableResult
    static func noticeDrift(_ noticedAt: ConfigChangeCaller.NoticedAt) async -> ConfigSnapshot? {
        await record(caller: .observed(noticedAt: noticedAt), approvalId: nil, requestText: nil)
    }

    /// Records the document after an apply, when the apply landed and the
    /// document changed.
    @discardableResult
    static func recordApply(
        _ results: [ConfigApplyResult], caller: ConfigChangeCaller, approvalId: UUID?, requestText: String?
    ) async -> ConfigSnapshot? {
        guard landed(results) else { return nil }
        return await record(caller: caller, approvalId: approvalId, requestText: requestText)
    }

    /// Loads the latest sequence for the fingerprint without writing.
    static func refreshLatestSequence() async {
        let database = database
        let sequence = await onBackground { try? database.latest()?.sequence }
        await MainActor.run { latestSequence = sequence ?? nil }
    }

    private static func record(
        caller: ConfigChangeCaller, approvalId: UUID?, requestText: String?
    ) async -> ConfigSnapshot? {
        let yaml: String
        do {
            yaml = try await MainActor.run { try ConfigYAML.canonical(ConfigExporter.export()) }
        } catch {
            print("[Osaurus][ConfigHistory] export failed: \(error.localizedDescription)")
            return nil
        }
        let database = database
        let outcome: Result<ConfigSnapshot?, Error> = await onBackground {
            Result {
                try database.append(
                    yaml: yaml, caller: caller, approvalId: approvalId, requestText: requestText)
            }
        }
        switch outcome {
        case .success(let snapshot):
            guard let snapshot else { return nil }
            await MainActor.run {
                latestSequence = snapshot.sequence
                NotificationCenter.default.post(name: didChange, object: nil)
            }
            return snapshot
        case .failure(let error):
            print("[Osaurus][ConfigHistory] write failed (\(caller.kind)): \(error.localizedDescription)")
            return nil
        }
    }

    private static func onBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}
