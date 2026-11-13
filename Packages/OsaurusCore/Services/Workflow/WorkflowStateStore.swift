//
//  WorkflowStateStore.swift
//  osaurus
//
//  A workflow's own stored data: named tables of key → value rows that
//  persist from run to run, so a workflow can count, remember what it
//  has seen, or cache a lookup without an agent database. Scoped by
//  workflow id — an installed workflow's runs share one store, a draft's
//  tests another — and kept as one JSON file per workflow under
//  `~/.osaurus/workflows/state/`. Reads and writes are serialized with a
//  lock so parallel steps (map items, concurrent runs) stay consistent;
//  `revision` ticks on the main actor for views.
//

import Combine
import Foundation

public struct WorkflowStateRow: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var value: JSONValue
    public var updatedAt: Date

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, value
        case updatedAt = "updated_at"
    }

    public var json: JSONValue {
        .object([
            "key": .string(key), "value": value,
            "updated_at": .string(WorkflowStateStore.iso.string(from: updatedAt)),
        ])
    }
}

public struct WorkflowStateTable: Equatable, Sendable, Identifiable {
    public var name: String
    public var count: Int
    public var updatedAt: Date?

    public var id: String { name }
}

public enum WorkflowStateError: Error, LocalizedError, Equatable {
    case notANumber(key: String)
    case valueTooLarge(bytes: Int)
    case tooManyRows(table: String)
    case tooManyTables
    case badName(String)

    public var errorDescription: String? {
        switch self {
        case .notANumber(let key): return L("`\(key)` holds a value that is not a number, so it cannot be incremented.")
        case .valueTooLarge(let bytes):
            return L("The value is \(bytes) bytes; stored values are at most \(WorkflowStateStore.maximumValueBytes).")
        case .tooManyRows(let table):
            return L(
                "Table `\(table)` already has \(WorkflowStateStore.maximumRowsPerTable) rows; delete or clear before adding more."
            )
        case .tooManyTables: return L("A workflow may have at most \(WorkflowStateStore.maximumTables) tables.")
        case .badName(let name):
            return L(
                "`\(name)` is not a valid table or key: use 1 to \(WorkflowStateStore.maximumNameLength) characters without newlines."
            )
        }
    }
}

public final class WorkflowStateStore: ObservableObject, @unchecked Sendable {
    public static let shared = WorkflowStateStore()

    public static let maximumValueBytes = 64 * 1024
    public static let maximumRowsPerTable = 5_000
    public static let maximumTables = 50
    public static let maximumNameLength = 200

    // ISO8601DateFormatter is documented thread-safe; the type just lacks
    // the Sendable mark.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Bumps on every write, on the main actor, for views that show a
    /// workflow's tables.
    @MainActor @Published public private(set) var revision = 0

    struct File: Codable, Equatable {
        var tables: [String: [String: WorkflowStateRow]] = [:]
    }

    private let lock = NSLock()
    private var cache: [UUID: File] = [:]
    private let directory: URL

    init(directory: URL = OsaurusPaths.workflows().appendingPathComponent("state", isDirectory: true)) {
        self.directory = directory
    }

    // MARK: - Reads

    public func get(workflow: UUID, table: String, key: String) throws -> WorkflowStateRow? {
        try validate(table)
        try validate(key)
        return withFile(workflow) { $0.tables[table]?[key] }
    }

    public func list(workflow: UUID, table: String, limit: Int) throws -> [WorkflowStateRow] {
        try validate(table)
        return withFile(workflow) { file in
            Array(
                (file.tables[table]?.values ?? [:].values).sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, limit))
            )
        }
    }

    /// Every table of the workflow with its row count, by name.
    public func tables(workflow: UUID) -> [WorkflowStateTable] {
        withFile(workflow) { file in
            file.tables.filter { !$0.value.isEmpty }
                .map { name, rows in
                    WorkflowStateTable(name: name, count: rows.count, updatedAt: rows.values.map(\.updatedAt).max())
                }
                .sorted { $0.name < $1.name }
        }
    }

    // MARK: - Writes

    @discardableResult
    public func set(workflow: UUID, table: String, key: String, value: JSONValue, now: Date = Date()) throws
        -> WorkflowStateRow
    {
        try validate(table)
        try validate(key)
        let bytes = value.compactJSONString.utf8.count
        guard bytes <= Self.maximumValueBytes else { throw WorkflowStateError.valueTooLarge(bytes: bytes) }
        return try mutate(workflow) { file in
            if file.tables[table] == nil {
                guard file.tables.count < Self.maximumTables else { throw WorkflowStateError.tooManyTables }
                file.tables[table] = [:]
            }
            if file.tables[table]?[key] == nil, (file.tables[table]?.count ?? 0) >= Self.maximumRowsPerTable {
                throw WorkflowStateError.tooManyRows(table: table)
            }
            let row = WorkflowStateRow(key: key, value: value, updatedAt: now)
            file.tables[table]?[key] = row
            return row
        }
    }

    public func increment(workflow: UUID, table: String, key: String, by amount: Double, now: Date = Date()) throws
        -> Double
    {
        try validate(table)
        try validate(key)
        return try mutate(workflow) { file in
            let current = file.tables[table]?[key]?.value
            let base: Double
            switch current {
            case nil, .null?: base = 0
            case .number(let n)?: base = n
            case .string(let s)? where Double(s) != nil: base = Double(s)!
            default: throw WorkflowStateError.notANumber(key: key)
            }
            if file.tables[table] == nil {
                guard file.tables.count < Self.maximumTables else { throw WorkflowStateError.tooManyTables }
                file.tables[table] = [:]
            }
            if current == nil, (file.tables[table]?.count ?? 0) >= Self.maximumRowsPerTable {
                throw WorkflowStateError.tooManyRows(table: table)
            }
            let next = base + amount
            file.tables[table]?[key] = WorkflowStateRow(key: key, value: .number(next), updatedAt: now)
            return next
        }
    }

    @discardableResult
    public func delete(workflow: UUID, table: String, key: String) throws -> Bool {
        try validate(table)
        try validate(key)
        return try mutate(workflow) { file in
            let removed = file.tables[table]?.removeValue(forKey: key) != nil
            if file.tables[table]?.isEmpty == true { file.tables[table] = nil }
            return removed
        }
    }

    @discardableResult
    public func clear(workflow: UUID, table: String) throws -> Int {
        try validate(table)
        return try mutate(workflow) { file in
            let count = file.tables[table]?.count ?? 0
            file.tables[table] = nil
            return count
        }
    }

    /// Forgets everything the workflow stored: on uninstall and when a
    /// draft is deleted.
    public func deleteAll(workflow: UUID) {
        lock.lock()
        cache[workflow] = nil
        try? FileManager.default.removeItem(at: url(workflow))
        lock.unlock()
        bump()
    }

    // MARK: - Internals

    func validate(_ name: String) throws {
        guard !name.isEmpty, name.count <= Self.maximumNameLength, !name.contains("\n") else {
            throw WorkflowStateError.badName(name)
        }
    }

    private func withFile<T>(_ workflow: UUID, _ read: (File) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return read(load(workflow))
    }

    private func mutate<T>(_ workflow: UUID, _ change: (inout File) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var file = load(workflow)
        let result = try change(&file)
        cache[workflow] = file
        write(file, workflow: workflow)
        bump()
        return result
    }

    private func load(_ workflow: UUID) -> File {
        if let cached = cache[workflow] { return cached }
        var file = File()
        if let data = try? Data(contentsOf: url(workflow)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            file = (try? decoder.decode(File.self, from: data)) ?? File()
        }
        cache[workflow] = file
        return file
    }

    private func write(_ file: File, workflow: UUID) {
        do {
            let target = url(workflow)
            if file.tables.isEmpty {
                try? FileManager.default.removeItem(at: target)
                return
            }
            try OsaurusPaths.ensureExists(directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: target, options: .atomic)
        } catch {
            print("[WorkflowStateStore] write failed: \(error)")
        }
    }

    private func url(_ workflow: UUID) -> URL {
        directory.appendingPathComponent("\(workflow.uuidString).json")
    }

    private func bump() {
        Task { @MainActor in self.revision &+= 1 }
    }

    /// Drops the in-memory cache and every file.
    public func resetForTesting() {
        lock.lock()
        cache = [:]
        try? FileManager.default.removeItem(at: directory)
        lock.unlock()
    }
}

// MARK: - Executor

/// Runs a `state` step against the run's workflow.
enum StateNodeExecutor {
    static func run(spec: StateSpec, context: WorkflowNodeContext, store: WorkflowStateStore = .shared) async throws
        -> WorkflowNodeOutcome
    {
        let table = render(spec.table, in: context).flatMap { $0.isEmpty ? nil : $0 } ?? StateSpec.defaultTable
        let workflow = context.workflowID
        func key() throws -> String {
            guard let key = render(spec.key, in: context), !key.isEmpty else {
                throw WorkflowNodeError.unsupported(L("A `\(spec.action.rawValue)` state step needs a key."))
            }
            return key
        }
        do {
            switch spec.action {
            case .get:
                let row = try store.get(workflow: workflow, table: table, key: try key())
                return outcome([
                    "exists": .bool(row != nil),
                    "value": row?.value ?? .null,
                    "updated_at": row.map { .string(WorkflowStateStore.iso.string(from: $0.updatedAt)) } ?? .null,
                ])
            case .set:
                let value =
                    spec.value.map { literalOrText(BindingRenderer.renderValue($0, in: context.bindings)) } ?? .null
                let row = try store.set(workflow: workflow, table: table, key: try key(), value: value)
                return outcome([
                    "value": row.value, "updated_at": .string(WorkflowStateStore.iso.string(from: row.updatedAt)),
                ])
            case .increment:
                let amount: Double
                if let text = render(spec.by, in: context), !text.isEmpty {
                    guard let n = Double(text) else {
                        throw WorkflowNodeError.unsupported(L("`by` must be a number; it rendered as “\(text)”."))
                    }
                    amount = n
                } else {
                    amount = 1
                }
                let value = try store.increment(workflow: workflow, table: table, key: try key(), by: amount)
                return outcome(["value": .number(value)])
            case .delete:
                let deleted = try store.delete(workflow: workflow, table: table, key: try key())
                return outcome(["deleted": .bool(deleted)])
            case .list:
                let limit = min(max(spec.limit ?? StateSpec.defaultListLimit, 0), StateSpec.maximumListLimit)
                let rows = try store.list(workflow: workflow, table: table, limit: limit)
                return outcome(["rows": .array(rows.map(\.json)), "count": .number(Double(rows.count))])
            case .clear:
                let count = try store.clear(workflow: workflow, table: table)
                return outcome(["count": .number(Double(count))])
            }
        } catch let error as WorkflowStateError {
            throw WorkflowNodeError.unsupported(error.localizedDescription)
        }
    }

    /// A rendered `value` that reads as a JSON literal — an object, an
    /// array, a number, `true`, `false`, or `null` — is stored as that
    /// value; any other text is stored as a string.
    static func literalOrText(_ rendered: JSONValue) -> JSONValue {
        guard case .string(let text) = rendered else { return rendered }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return rendered }
        let looksLiteral =
            first == "{" || first == "[" || trimmed == "true" || trimmed == "false" || trimmed == "null"
            || Double(trimmed) != nil
        guard looksLiteral, let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return rendered
        }
        return parsed
    }

    private static func render(_ template: String?, in context: WorkflowNodeContext) -> String? {
        guard let template else { return nil }
        return BindingRenderer.renderText(template, in: context.bindings).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private static func outcome(_ fields: [String: JSONValue]) -> WorkflowNodeOutcome {
        WorkflowNodeOutcome(output: .object(fields))
    }
}
