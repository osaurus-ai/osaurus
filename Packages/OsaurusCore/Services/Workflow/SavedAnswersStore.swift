//
//  SavedAnswersStore.swift
//  osaurus
//
//  Remembered dialog answers, one set per installed workflow on this Mac
//  (shared by every agent that calls it). Each answer belongs to one
//  field of one dialog node, so two forms that both ask for `email` keep
//  separate answers. Non-secret values live in
//  `~/.osaurus/workflows/<id>/answers.json`; secret fields keep only a
//  marker there and their value in the Keychain. Saved answers never
//  leave the Mac: export strips them and templates never carry them.
//

import Combine
import Foundation

public struct SavedAnswer: Codable, Sendable, Equatable, Identifiable {
    public let fieldKey: String
    /// The dialog node the field belongs to.
    public var nodeID: String
    public var type: DialogFieldType
    /// Nil for secret fields (the value is in the Keychain).
    public var value: JSONValue?
    public var updatedAt: Date

    public var id: String { SavedAnswersStore.key(nodeID: nodeID, fieldKey: fieldKey) }
    public var isSecret: Bool { type == .secret }

    enum CodingKeys: String, CodingKey {
        case fieldKey = "field_key"
        case nodeID = "node_id"
        case type, value
        case updatedAt = "updated_at"
    }
}

@MainActor
public final class SavedAnswersStore: ObservableObject {
    public static let shared = SavedAnswersStore()

    /// Bumped on every write so views listing answers refresh.
    @Published public private(set) var revision = 0

    /// Answers by `key(nodeID:fieldKey:)`.
    private var cache: [UUID: [String: SavedAnswer]] = [:]

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func fileURL(_ workflowID: UUID) -> URL {
        OsaurusPaths.workflowDirectory(workflowID).appendingPathComponent("answers.json")
    }

    /// The dictionary key for one field of one node.
    nonisolated public static func key(nodeID: String, fieldKey: String) -> String { "\(nodeID)/\(fieldKey)" }

    private func load(_ workflowID: UUID) -> [String: SavedAnswer] {
        if let cached = cache[workflowID] { return cached }
        let url = Self.fileURL(workflowID)
        let onDisk =
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode([String: SavedAnswer].self, from: $0) }
            ?? [:]
        // Files written before answers were keyed by node used the bare
        // field key; re-key them from the node each answer recorded.
        var answers: [String: SavedAnswer] = [:]
        var rewrote = false
        for (storedKey, answer) in onDisk {
            let key = Self.key(nodeID: answer.nodeID, fieldKey: answer.fieldKey)
            if storedKey != key {
                rewrote = true
                if answer.isSecret {
                    // The value sat under the bare field key too.
                    let legacy = "answer:\(workflowID.uuidString.lowercased()):\(answer.fieldKey)"
                    if let value = WorkflowSecretsKeychain.read(account: legacy) {
                        WorkflowSecretsKeychain.save(
                            value,
                            account: WorkflowSecretsKeychain.answerAccount(
                                workflowID: workflowID, nodeID: answer.nodeID, fieldKey: answer.fieldKey))
                        WorkflowSecretsKeychain.delete(account: legacy)
                    }
                }
            }
            answers[key] = answer
        }
        cache[workflowID] = answers
        if rewrote { persist(workflowID, answers) }
        return answers
    }

    private func persist(_ workflowID: UUID, _ answers: [String: SavedAnswer]) {
        cache[workflowID] = answers
        revision += 1
        let url = Self.fileURL(workflowID)
        if answers.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        if let data = try? Self.encoder.encode(answers) { try? data.write(to: url, options: .atomic) }
    }

    public func all(workflowID: UUID) -> [SavedAnswer] {
        load(workflowID).values.sorted { $0.id < $1.id }
    }

    /// The saved value, reading secret fields from the Keychain.
    public func value(workflowID: UUID, nodeID: String, fieldKey: String) -> JSONValue? {
        guard let answer = load(workflowID)[Self.key(nodeID: nodeID, fieldKey: fieldKey)] else { return nil }
        if answer.isSecret {
            return WorkflowSecretsKeychain.read(
                account: WorkflowSecretsKeychain.answerAccount(workflowID: workflowID, nodeID: nodeID, fieldKey: fieldKey)
            ).map(JSONValue.string)
        }
        return answer.value
    }

    public func save(workflowID: UUID, nodeID: String, field: DialogField, value: JSONValue) {
        var answers = load(workflowID)
        if field.type == .secret {
            let account = WorkflowSecretsKeychain.answerAccount(workflowID: workflowID, nodeID: nodeID, fieldKey: field.key)
            WorkflowSecretsKeychain.save(value.stringValue ?? value.compactJSONString, account: account)
        }
        answers[Self.key(nodeID: nodeID, fieldKey: field.key)] = SavedAnswer(
            fieldKey: field.key, nodeID: nodeID, type: field.type,
            value: field.type == .secret ? nil : value, updatedAt: Date())
        persist(workflowID, answers)
    }

    public func clear(workflowID: UUID, nodeID: String, fieldKey: String) {
        var answers = load(workflowID)
        guard let removed = answers.removeValue(forKey: Self.key(nodeID: nodeID, fieldKey: fieldKey)) else { return }
        if removed.isSecret {
            WorkflowSecretsKeychain.delete(
                account: WorkflowSecretsKeychain.answerAccount(workflowID: workflowID, nodeID: nodeID, fieldKey: fieldKey))
        }
        persist(workflowID, answers)
    }

    public func clearAll(workflowID: UUID) {
        for answer in load(workflowID).values {
            clear(workflowID: workflowID, nodeID: answer.nodeID, fieldKey: answer.fieldKey)
        }
        persist(workflowID, [:])
    }

    /// After an update re-pins a workflow: keep answers whose node still
    /// asks the field with the same type, clear the rest.
    public func migrate(workflowID: UUID, to definition: WorkflowDefinition) {
        var types: [String: DialogFieldType] = [:]
        for node in definition.nodes {
            if case .dialog(let spec) = node.kind {
                for field in spec.fields { types[Self.key(nodeID: node.id, fieldKey: field.key)] = field.type }
            }
        }
        for answer in load(workflowID).values where types[answer.id] != answer.type {
            clear(workflowID: workflowID, nodeID: answer.nodeID, fieldKey: answer.fieldKey)
        }
    }

    func resetForTesting() {
        cache = [:]
        revision = 0
    }
}
