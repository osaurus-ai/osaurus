//
//  ConfigHistoryFixtures.swift
//  osaurus
//
//  Seeded configuration history for evaluation lanes: real applies to the
//  (isolated) live store, each recorded with the caller, request, label, and
//  time a case needs, so questions about past changes have real versions to
//  read and revert to.
//

import Foundation

public enum ConfigHistoryFixtures {
    public struct Step: Sendable {
        public let yaml: String
        public let prune: Bool
        public let caller: ConfigChangeCaller
        public let requestText: String?
        public let label: String?
        public let takenAt: Date

        public init(
            yaml: String, prune: Bool = false, caller: ConfigChangeCaller, requestText: String? = nil,
            label: String? = nil, takenAt: Date
        ) {
            self.yaml = yaml
            self.prune = prune
            self.caller = caller
            self.requestText = requestText
            self.label = label
            self.takenAt = takenAt
        }
    }

    public struct SeedError: LocalizedError {
        public let step: Int
        public let reason: String
        public var errorDescription: String? { "step \(step): \(reason)" }
    }

    /// Replaces the history with the document as found (version 0, taken at
    /// `foundAt`, named `foundLabel`; `prepare` is applied first so the case
    /// starts from a known state) followed by one version per step. Each
    /// step's document is applied to the live store first; a step that does
    /// not fully land (failed, cancelled, waiting on the user) or changes
    /// nothing throws, since the history would no longer be the one the case
    /// describes. Steps can't create providers: that opens the credential
    /// sheet. The live document ends at the last step.
    public static func seed(
        _ steps: [Step], foundAt: Date, foundLabel: String? = nil, prepare: String? = nil
    ) async throws {
        let database = ConfigHistoryRecorder.database
        if let prepare {
            // No history caller: the seed writes its own rows below.
            let document = try ConfigYAML.decode(prepare)
            let results = await ConfigApplier.apply(document: document, prune: false, caller: nil)
            if let missed = results.first(where: { $0.status != .done }) {
                throw SeedError(
                    step: 0, reason: "\(missed.section) \(missed.target) \(missed.status.rawValue): \(missed.message ?? "")")
            }
        }
        try database.deleteAll()
        if let found = try database.append(
            yaml: try await canonicalLiveDocument(), caller: .observed(noticedAt: .launch), takenAt: foundAt),
            let foundLabel
        {
            try database.setLabel(foundLabel, sequence: found.sequence)
        }
        for (index, step) in steps.enumerated() {
            let document = try ConfigYAML.decode(step.yaml)
            let results = await ConfigApplier.apply(document: document, prune: step.prune, caller: nil)
            if let missed = results.first(where: { $0.status != .done }) {
                throw SeedError(
                    step: index + 1,
                    reason: "\(missed.section) \(missed.target) \(missed.status.rawValue): \(missed.message ?? "")")
            }
            guard
                let row = try database.append(
                    yaml: try await canonicalLiveDocument(), caller: step.caller, requestText: step.requestText,
                    takenAt: step.takenAt)
            else { throw SeedError(step: index + 1, reason: "the document did not change") }
            if let label = step.label { try database.setLabel(label, sequence: row.sequence) }
        }
        await ConfigHistoryRecorder.refreshLatestSequence()
    }

    /// Empties the history after a case.
    public static func clear() async {
        try? ConfigHistoryRecorder.database.deleteAll()
        await ConfigHistoryRecorder.refreshLatestSequence()
    }

    private static func canonicalLiveDocument() async throws -> String {
        try await MainActor.run { try ConfigYAML.canonical(ConfigExporter.export()) }
    }
}
