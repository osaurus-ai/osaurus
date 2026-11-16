//
//  ConfigSnapshot.swift
//  osaurus
//
//  One row of configuration history: the whole declarative document after a
//  landed apply (or after a change noticed outside any apply), stored as
//  canonical YAML. The state before a snapshot is the previous snapshot;
//  diffs are computed, never stored. Immutable except for `label`.
//

import CryptoKit
import Foundation
import Yams

/// Who changed the configuration. Stored as `caller_kind` / `caller_detail`.
public enum ConfigChangeCaller: Sendable, Equatable {
    /// Where a change made outside any apply was noticed. The store records
    /// only this; the History view is what calls it "Changed in Settings".
    public enum NoticedAt: String, Sendable, CaseIterable {
        case beforeApply = "before_apply"
        case launch
        case historyOpened = "history_opened"
    }

    /// The Configurator, from a chat (`osaurus_config` apply or revert).
    case configurator(sessionId: String)
    /// The document no longer matched the latest snapshot: edited in
    /// Settings (or on disk) since. Never carries request text.
    case observed(noticedAt: NoticedAt)
    case templateInstall(templateId: String)
    /// `osaurus import` bundles and the Automations import.
    case fileImport
    /// An apply the owner's paired phone approved.
    case pairedPhone(deviceKey: String)
    /// `POST /admin/config/apply` (the CLI and direct HTTP callers).
    case adminAPI
    case other(String)

    public var kind: String {
        switch self {
        case .configurator: return "configurator"
        case .observed: return "observed"
        case .templateInstall: return "template_install"
        case .fileImport: return "file_import"
        case .pairedPhone: return "paired_phone"
        case .adminAPI: return "admin_api"
        case .other: return "other"
        }
    }

    public var detail: String? {
        switch self {
        case .configurator(let sessionId): return sessionId
        case .observed(let noticedAt): return noticedAt.rawValue
        case .templateInstall(let templateId): return templateId
        case .pairedPhone(let deviceKey): return deviceKey
        case .other(let text): return text
        case .fileImport, .adminAPI: return nil
        }
    }

    public init(kind: String, detail: String?) {
        switch kind {
        case "configurator": self = .configurator(sessionId: detail ?? "")
        case "observed": self = .observed(noticedAt: detail.flatMap(NoticedAt.init(rawValue:)) ?? .launch)
        case "template_install": self = .templateInstall(templateId: detail ?? "")
        case "file_import": self = .fileImport
        case "paired_phone": self = .pairedPhone(deviceKey: detail ?? "")
        case "admin_api": self = .adminAPI
        default: self = .other(detail ?? kind)
        }
    }

    public var isObserved: Bool {
        if case .observed = self { return true }
        return false
    }
}

public struct ConfigSnapshot: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Monotonic per Mac. Sequence 0 is the document as found the first
    /// time history ran; it is never pruned.
    public let sequence: Int
    public let takenAt: Date
    /// Canonical YAML (`ConfigYAML.canonical`) of the document after the change.
    public let yaml: String
    public let documentHash: String
    public let sectionsChanged: [ConfigSectionID]
    public let caller: ConfigChangeCaller
    /// The approval card that gated the change, when one did.
    public let approvalId: UUID?
    /// The user's verbatim message when a chat asked; nil on observed rows.
    public let requestText: String?
    public var label: String?

    public init(
        id: UUID = UUID(), sequence: Int, takenAt: Date = Date(), yaml: String,
        sectionsChanged: [ConfigSectionID], caller: ConfigChangeCaller, approvalId: UUID? = nil,
        requestText: String? = nil, label: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.takenAt = takenAt
        self.yaml = yaml
        self.documentHash = Self.hash(yaml)
        self.sectionsChanged = sectionsChanged
        self.caller = caller
        self.approvalId = approvalId
        self.requestText = caller.isObserved ? nil : requestText
        self.label = label
    }

    /// The stored document, decoded.
    public func document() throws -> OsaurusConfigDocument { try ConfigYAML.decode(yaml) }

    public static func hash(_ yaml: String) -> String {
        SHA256.hash(data: Data(yaml.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Top-level sections whose content differs between two canonical
    /// documents (`nil` before: every section present in `after`).
    public static func sectionsChanged(from before: String?, to after: String) -> [ConfigSectionID] {
        let new = topLevel(after)
        guard let before else {
            return ConfigSectionID.allCases.filter { new[$0.rawValue] != nil }
        }
        let old = topLevel(before)
        return ConfigSectionID.allCases.filter { old[$0.rawValue] != new[$0.rawValue] }
    }

    /// Each top-level key's subtree, re-serialized with sorted keys.
    static func topLevel(_ yaml: String) -> [String: String] {
        guard let root = (try? Yams.load(yaml: yaml)) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in root {
            out[key] = (try? Yams.dump(object: value, sortKeys: true)) ?? String(describing: value)
        }
        return out
    }
}
