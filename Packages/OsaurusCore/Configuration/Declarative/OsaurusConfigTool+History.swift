//
//  OsaurusConfigTool+History.swift
//  osaurus
//
//  `osaurus_config` history, diff, and revert over configuration history
//  (`ConfigHistoryDatabase`). History and diff read; revert is an ordinary
//  apply of a stored document through the planner, the approval card, and
//  the applier, so every apply rule holds.
//

import Foundation

extension OsaurusConfigTool {
    static let historyDefaultLimit = 10
    static let historyMaxLimit = 50

    /// What configuration history does not version, so an answer never
    /// implies otherwise.
    static let historyNotCovered = [
        "Orchestrator and agent working folders",
        "Server runtime settings (Settings → Server)",
        "API keys, tokens, and connection credentials (kept in the Keychain)",
        "Themes, voice, and telemetry switches",
        "Workflow definitions (versioned with each workflow)",
    ]

    // MARK: - history

    func handleHistory(_ args: [String: Any]) async -> String {
        let limit = min(max(Self.intArgument(args["limit"]) ?? Self.historyDefaultLimit, 1), Self.historyMaxLimit)
        var section: ConfigSectionID?
        if let raw = args["section"] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = ConfigSectionID.parse(raw) else {
                var message = "Unknown section `\(raw)`."
                if let suggestion = Self.closestSectionName(to: raw) { message += " Did you mean `\(suggestion)`?" }
                return ToolEnvelope.failure(kind: .invalidArgs, message: message, field: "section", tool: name)
            }
            section = parsed
        }
        var since: Date?
        if let raw = args["since"] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = Self.parseDate(raw) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`since` must be a date like 2026-11-04 or 2026-11-04T09:30:00Z.",
                    field: "since", tool: name)
            }
            since = parsed
        }

        await ConfigApplier.noticeConfigDrift(.historyOpened)
        let rows: [ConfigSnapshot]
        do {
            rows = try await Self.onHistoryQueue { [section, since] in
                try ConfigHistoryRecorder.database.list(limit: limit, section: section, since: since)
            }
        } catch {
            return ToolEnvelope.failure(kind: .executionError, message: error.localizedDescription, tool: name)
        }
        var result: [String: Any] = [
            "versions": rows.map(Self.historyRow),
            "not_covered": Self.historyNotCovered,
        ]
        if let latest = rows.first?.sequence, section == nil, since == nil {
            result["configuration_version"] = latest
        }
        result["next_step"] =
            rows.isEmpty
            ? "No recorded configuration changes match. Say so; do not guess at past changes."
            : "Answer from these rows. For exactly what changed, call action `diff` with `from` set to the "
                + "version before and `to` set to the version (or `current`)."
        return ToolEnvelope.success(tool: name, result: result)
    }

    static func historyRow(_ snapshot: ConfigSnapshot) -> [String: Any] {
        var row: [String: Any] = [
            "version": snapshot.sequence,
            "time": ISO8601DateFormatter().string(from: snapshot.takenAt),
            "changed_by": snapshot.caller.displayName,
            "sections_changed": snapshot.sectionsChanged.map(\.rawValue),
        ]
        if let request = snapshot.requestText { row["request"] = request }
        if let label = snapshot.label { row["label"] = label }
        if snapshot.sequence == 0 { row["note"] = "The configuration as first found; not a change." }
        return row
    }

    // MARK: - diff

    func handleDiff(_ args: [String: Any]) async -> String {
        guard let fromRef = Self.versionReference(args["from"]) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`from` is required: a version number or a version's name.",
                field: "from", tool: name)
        }
        let toRef = Self.versionReference(args["to"]) ?? "current"
        await ConfigApplier.noticeConfigDrift(.historyOpened)

        let from: (yaml: String, label: String)
        let to: (yaml: String, label: String)
        do {
            guard let resolved = try await resolveVersion(fromRef) else {
                return Self.unknownVersion(fromRef, field: "from", tool: name)
            }
            from = resolved
            guard let resolvedTo = try await resolveVersion(toRef) else {
                return Self.unknownVersion(toRef, field: "to", tool: name)
            }
            to = resolvedTo
        } catch {
            return ToolEnvelope.failure(kind: .executionError, message: error.localizedDescription, tool: name)
        }
        let diff = ConfigDiff.compute(before: from.yaml, after: to.yaml, fromLabel: from.label, toLabel: to.label)
        var result: [String: Any] = ["from": from.label, "to": to.label]
        if diff.isEmpty {
            result["diff"] = "no differences"
            result["changes"] = [[String: String]]()
        } else {
            result["diff"] = diff.unified
            result["changes"] = diff.changes.map(\.row)
        }
        result["not_covered"] = Self.historyNotCovered
        return ToolEnvelope.success(tool: name, result: result)
    }

    /// A version's canonical document and display label; `current` is the
    /// live document.
    private func resolveVersion(_ reference: String) async throws -> (yaml: String, label: String)? {
        if reference.lowercased() == "current" {
            let yaml = try await MainActor.run { try ConfigYAML.canonical(ConfigExporter.export()) }
            return (yaml, "current")
        }
        guard let snapshot = try await Self.snapshot(for: reference) else { return nil }
        return (snapshot.yaml, Self.versionLabel(snapshot))
    }

    // MARK: - revert

    func handleRevert(_ args: [String: Any]) async -> String {
        if ChatExecutionContext.hasRemoteReviewer {
            return ToolEnvelope.failure(
                kind: .permissionDenied,
                message: "Reverting configuration is started from Osaurus on the Mac. Nothing was changed.",
                tool: name, retryable: false)
        }
        guard let reference = Self.versionReference(args["to"]), reference.lowercased() != "current" else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`to` is required: the version number or name to go back to.",
                field: "to", tool: name)
        }
        var sections: Set<ConfigSectionID>?
        if args["sections"] != nil {
            let names: [String] =
                (args["sections"] as? [Any])?.compactMap { $0 as? String }
                ?? (args["sections"] as? String)?.split(whereSeparator: { ", ".contains($0) }).map(String.init) ?? []
            var resolved = Set<ConfigSectionID>()
            for raw in names {
                guard let id = ConfigSectionID.parse(raw) else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs, message: "Unknown section `\(raw)`.", field: "sections", tool: name)
                }
                resolved.insert(id)
            }
            sections = resolved.isEmpty ? nil : resolved
        }
        let prune = coerceBool(args["prune"]) ?? false

        let snapshot: ConfigSnapshot
        let document: OsaurusConfigDocument
        do {
            guard let found = try await Self.snapshot(for: reference) else {
                return Self.unknownVersion(reference, field: "to", tool: name)
            }
            snapshot = found
            let stored = try found.document()
            document = sections.map { stored.filtered(to: $0) } ?? stored
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError, message: "Version \(reference) could not be read: \(error.localizedDescription)",
                tool: name)
        }

        let target = Self.versionLabel(snapshot)
        let scope = sections.map { " (" + $0.map(\.rawValue).sorted().joined(separator: ", ") + " only)" } ?? ""
        return await applyDocument(
            document, prune: prune, basedOn: nil, autoNamed: nil,
            caller: .configurator(sessionId: ChatExecutionContext.currentSessionId ?? ""),
            requestText: "Revert to \(target)\(scope)",
            leadingNotes: ["Reverting to \(target)\(scope)."])
    }

    // MARK: - Helpers

    static func versionLabel(_ snapshot: ConfigSnapshot) -> String {
        snapshot.label.map { "version \(snapshot.sequence) “\($0)”" } ?? "version \(snapshot.sequence)"
    }

    private static func snapshot(for reference: String) async throws -> ConfigSnapshot? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.lowercased().replacingOccurrences(of: "version", with: "")
            .trimmingCharacters(in: .whitespaces)
        return try await onHistoryQueue {
            let database = ConfigHistoryRecorder.database
            if let sequence = Int(digits), let found = try database.snapshot(sequence: sequence) { return found }
            return try database.snapshot(label: trimmed)
        }
    }

    private static func unknownVersion(_ reference: String, field: String, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "No configuration version `\(reference)`. Call action `history` to list versions.",
            field: field, tool: tool)
    }

    /// `"12"`, `12`, `"version 12"`, a label, or `current`.
    static func versionReference(_ raw: Any?) -> String? {
        if let number = raw as? Int { return String(number) }
        if let number = raw as? Double, number.rounded() == number { return String(Int(number)) }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    static func intArgument(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        dateOnly.timeZone = .current
        return dateOnly.date(from: text)
    }

    private static func onHistoryQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let database = ConfigHistoryRecorder.database
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try ConfigHistoryRecorder.$databaseOverride.withValue(database) { try work() }
                    })
            }
        }
    }
}

extension ConfigChangeCaller {
    /// How History and the Configurator name who made a change. An observed
    /// change is one made outside any apply, which in practice is Settings.
    public var displayName: String {
        switch self {
        case .configurator: return L("Configurator (chat)")
        case .observed: return L("Changed in Settings")
        case .templateInstall(let templateId): return L("Template install: \(templateId)")
        case .fileImport: return L("File import")
        case .pairedPhone: return L("iPhone")
        case .adminAPI: return L("Command line or admin API")
        case .other(let text): return text
        }
    }
}
