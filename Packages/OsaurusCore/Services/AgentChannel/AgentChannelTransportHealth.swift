//
//  AgentChannelTransportHealth.swift
//  osaurus
//
//  Shared health state for Agent Channel receive transports.
//

import Foundation

enum AgentChannelTransportHealthSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
}

enum AgentChannelTransportHealthStatus: String, Codable, CaseIterable, Sendable {
    case disabled
    case idle
    case healthy
    case degraded
    case conflict
    case failed
}

struct AgentChannelTransportHealthState: Codable, Equatable, Sendable {
    var connectionId: String
    var transportId: String
    var provider: AgentChannelKind
    var status: AgentChannelTransportHealthStatus
    var severity: AgentChannelTransportHealthSeverity
    var summary: String
    var detail: String?
    var isRunning: Bool
    var receiveEnabled: Bool
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var nextRetryAt: Date?
    var consecutiveFailures: Int
    var lastReceivedCount: Int
    var lastStoredCount: Int
    var dispatchSuppressedCount: Int
    var updatedAt: Date

    init(
        connectionId: String,
        transportId: String,
        provider: AgentChannelKind,
        status: AgentChannelTransportHealthStatus,
        severity: AgentChannelTransportHealthSeverity,
        summary: String,
        detail: String? = nil,
        isRunning: Bool,
        receiveEnabled: Bool,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        nextRetryAt: Date? = nil,
        consecutiveFailures: Int = 0,
        lastReceivedCount: Int = 0,
        lastStoredCount: Int = 0,
        dispatchSuppressedCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.connectionId = AgentChannelConnection.normalizedId(connectionId)
        self.transportId = AgentChannelConnection.normalizedId(transportId)
        self.provider = provider
        self.status = status
        self.severity = severity
        self.summary = summary
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isRunning = isRunning
        self.receiveEnabled = receiveEnabled
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.nextRetryAt = nextRetryAt
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.lastReceivedCount = max(0, lastReceivedCount)
        self.lastStoredCount = max(0, lastStoredCount)
        self.dispatchSuppressedCount = max(0, dispatchSuppressedCount)
        self.updatedAt = updatedAt
    }

    var notificationIdentifier: String {
        "\(connectionId).\(transportId).\(status.rawValue)"
    }

    var shouldNotify: Bool {
        switch severity {
        case .info:
            return false
        case .warning, .error:
            return status != .disabled
        }
    }

    var dictionary: [String: Any] {
        var row: [String: Any] = [
            "connection_id": connectionId,
            "transport_id": transportId,
            "provider": provider.rawValue,
            "status": status.rawValue,
            "severity": severity.rawValue,
            "summary": summary,
            "is_running": isRunning,
            "receive_enabled": receiveEnabled,
            "consecutive_failures": consecutiveFailures,
            "last_received_count": lastReceivedCount,
            "last_stored_count": lastStoredCount,
            "dispatch_suppressed_count": dispatchSuppressedCount,
            "notification_identifier": notificationIdentifier,
            "should_notify": shouldNotify,
            "updated_at": Self.iso8601(updatedAt),
        ]
        if let detail, !detail.isEmpty {
            row["detail"] = detail
        }
        if let lastSuccessAt {
            row["last_success_at"] = Self.iso8601(lastSuccessAt)
        }
        if let lastFailureAt {
            row["last_failure_at"] = Self.iso8601(lastFailureAt)
        }
        if let nextRetryAt {
            row["next_retry_at"] = Self.iso8601(nextRetryAt)
        }
        return row
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

actor AgentChannelTransportHealthCenter {
    static let shared = AgentChannelTransportHealthCenter()

    private var states: [String: AgentChannelTransportHealthState] = [:]

    @discardableResult
    func update(_ state: AgentChannelTransportHealthState) -> AgentChannelTransportHealthState {
        states[Self.key(connectionId: state.connectionId, transportId: state.transportId)] = state
        return state
    }

    func state(connectionId: String, transportId: String) -> AgentChannelTransportHealthState? {
        states[
            Self.key(
                connectionId: AgentChannelConnection.normalizedId(connectionId),
                transportId: AgentChannelConnection.normalizedId(transportId)
            )
        ]
    }

    func allStates(connectionId: String? = nil) -> [AgentChannelTransportHealthState] {
        let normalizedConnectionId = connectionId.map(AgentChannelConnection.normalizedId)
        return states.values
            .filter { state in
                guard let normalizedConnectionId else { return true }
                return state.connectionId == normalizedConnectionId
            }
            .sorted {
                if $0.connectionId == $1.connectionId {
                    return $0.transportId < $1.transportId
                }
                return $0.connectionId < $1.connectionId
            }
    }

    func clear(connectionId: String, transportId: String? = nil) {
        let normalizedConnectionId = AgentChannelConnection.normalizedId(connectionId)
        if let transportId {
            states.removeValue(
                forKey: Self.key(
                    connectionId: normalizedConnectionId,
                    transportId: AgentChannelConnection.normalizedId(transportId)
                )
            )
            return
        }
        states = states.filter { _, state in state.connectionId != normalizedConnectionId }
    }

    private static func key(connectionId: String, transportId: String) -> String {
        "\(connectionId)\u{1F}\(transportId)"
    }
}
