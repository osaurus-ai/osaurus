//
//  VMBootLog.swift
//  osaurus
//
//  Observable log model for VM boot and provisioning events.
//  Publishes per-agent log entries and provisioning phase so the UI
//  can show live progress. Persists logs to disk for later debugging.
//

import Foundation
import SwiftUI

public enum VMProvisionPhase: String, Codable, Sendable {
    case booting
    case installingOS
    case rebooting
    case configuringSystem
    case deployingShim
    case ready
    case failed

    public var displayLabel: String {
        switch self {
        case .booting: return "Booting VM..."
        case .installingOS: return "Installing Alpine Linux..."
        case .rebooting: return "Rebooting into installed system..."
        case .configuringSystem: return "Configuring system..."
        case .deployingShim: return "Deploying runtime shim..."
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

public struct VMLogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let phase: VMProvisionPhase
    public let message: String

    public init(phase: VMProvisionPhase, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.phase = phase
        self.message = message
    }
}

@MainActor
public final class VMBootLog: ObservableObject {
    public static let shared = VMBootLog()

    @Published public private(set) var entries: [UUID: [VMLogEntry]] = [:]
    @Published public private(set) var phase: [UUID: VMProvisionPhase] = [:]

    private init() {}

    // MARK: - Append / Phase

    public func append(agentId: UUID, phase: VMProvisionPhase, message: String) {
        let entry = VMLogEntry(phase: phase, message: message)
        entries[agentId, default: []].append(entry)
        NSLog("[VMBootLog] [%@] %@", phase.rawValue, message)
    }

    public func setPhase(agentId: UUID, _ newPhase: VMProvisionPhase) {
        phase[agentId] = newPhase
        append(agentId: agentId, phase: newPhase, message: "Phase: \(newPhase.rawValue)")
    }

    // MARK: - Persistence

    public func persist(agentId: UUID) {
        guard let agentEntries = entries[agentId], !agentEntries.isEmpty else { return }
        let url = OsaurusPaths.agentBootLog(agentId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(agentEntries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func load(agentId: UUID) {
        let url = OsaurusPaths.agentBootLog(agentId)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([VMLogEntry].self, from: data) else { return }
        entries[agentId] = loaded
        if let last = loaded.last {
            phase[agentId] = last.phase
        }
    }

    public func clear(agentId: UUID) {
        entries.removeValue(forKey: agentId)
        phase.removeValue(forKey: agentId)
        let url = OsaurusPaths.agentBootLog(agentId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Export

    public func exportText(agentId: UUID) -> String {
        guard let agentEntries = entries[agentId] else { return "" }
        let formatter = ISO8601DateFormatter()
        return agentEntries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.phase.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
