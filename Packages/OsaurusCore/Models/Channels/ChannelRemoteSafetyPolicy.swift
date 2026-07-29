//
//  ChannelRemoteSafetyPolicy.swift
//  osaurus
//
//  Provider-neutral safety policy for remote Agent Channel actions.
//

import Foundation

enum ChannelRemoteActionClass: String, Codable, CaseIterable, Sendable {
    case receive
    case dispatch
    case reply
    case write
    case dangerousApproval = "dangerous_approval"
    case computerUseStart = "computer_use_start"
    case computerUseStatus = "computer_use_status"
    case computerUseResult = "computer_use_result"

    var startsRemoteTask: Bool {
        switch self {
        case .dispatch, .computerUseStart:
            return true
        case .receive, .reply, .write, .dangerousApproval, .computerUseStatus, .computerUseResult:
            return false
        }
    }

    var requiredReplyTokenAction: ChannelSecurityAction {
        switch self {
        case .receive, .dispatch, .computerUseStatus, .computerUseResult:
            return .read
        case .reply:
            return .reply
        case .write, .dangerousApproval, .computerUseStart:
            return .write
        }
    }
}

enum ChannelRemoteSafetyDecisionReason: String, Codable, Equatable, Sendable {
    case allowed
    case disabled
    case invalidIdentity = "invalid_identity"
    case replyTokenRequired = "reply_token_required"
    case replyTokenRejected = "reply_token_rejected"
    case rateLimited = "rate_limited"
    case activeTaskLimitExceeded = "active_task_limit_exceeded"
    case taskIdRequired = "task_id_required"
}

enum ChannelRemoteContentRisk: String, Codable, Equatable, Sendable {
    case ordinary
    case suspicious
}

enum ChannelRemoteContentSignal: String, Codable, CaseIterable, Sendable {
    case systemInstructionOverride = "system_instruction_override"
    case toolPolicyOverride = "tool_policy_override"
    case computerUseApproval = "computer_use_approval"
    case credentialExfiltration = "credential_exfiltration"
    case channelPolicyMutation = "channel_policy_mutation"
    case hiddenPromptMarker = "hidden_prompt_marker"
}

struct ChannelRemoteContentAssessment: Codable, Equatable, Sendable {
    var risk: ChannelRemoteContentRisk
    var signals: [ChannelRemoteContentSignal]
    var inspectedCharacterCount: Int
    var originalCharacterCount: Int
    var truncated: Bool

    init(
        risk: ChannelRemoteContentRisk = .ordinary,
        signals: [ChannelRemoteContentSignal] = [],
        inspectedCharacterCount: Int = 0,
        originalCharacterCount: Int? = nil,
        truncated: Bool = false
    ) {
        self.risk = risk
        self.signals = Self.uniqueSignals(signals)
        self.inspectedCharacterCount = max(0, inspectedCharacterCount)
        self.originalCharacterCount = max(0, originalCharacterCount ?? inspectedCharacterCount)
        self.truncated = truncated
    }

    var isSuspicious: Bool {
        risk == .suspicious
    }

    var dictionary: [String: Any] {
        [
            "risk": risk.rawValue,
            "signals": signals.map(\.rawValue),
            "inspected_character_count": inspectedCharacterCount,
            "original_character_count": originalCharacterCount,
            "truncated": truncated,
        ]
    }

    private static func uniqueSignals(_ signals: [ChannelRemoteContentSignal]) -> [ChannelRemoteContentSignal] {
        var seen = Set<ChannelRemoteContentSignal>()
        return signals.filter { seen.insert($0).inserted }
    }
}

struct ChannelRemoteSafetyPolicy: Codable, Equatable, Sendable {
    var enabled: Bool
    var replyTokenRequiredActions: [ChannelRemoteActionClass]
    var replyTokenPurpose: String
    var replyTokenClockSkewSeconds: TimeInterval
    var maxRequestsPerWindow: Int
    var rateLimitWindowSeconds: TimeInterval
    var maxActiveTasksPerIdentity: Int
    var remoteTaskLeaseSeconds: TimeInterval
    var maxInboundContentCharacters: Int
    var maxResultCharacters: Int

    init(
        enabled: Bool = true,
        replyTokenRequiredActions: [ChannelRemoteActionClass] = [.dangerousApproval, .computerUseStart],
        replyTokenPurpose: String = "remote_channel_action",
        replyTokenClockSkewSeconds: TimeInterval = 60,
        maxRequestsPerWindow: Int = 20,
        rateLimitWindowSeconds: TimeInterval = 60,
        maxActiveTasksPerIdentity: Int = 1,
        remoteTaskLeaseSeconds: TimeInterval = 900,
        maxInboundContentCharacters: Int = 8_000,
        maxResultCharacters: Int = 4_000
    ) {
        self.enabled = enabled
        self.replyTokenRequiredActions = Self.uniqueActions(replyTokenRequiredActions)
        let normalizedPurpose = replyTokenPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        self.replyTokenPurpose = normalizedPurpose.isEmpty ? "remote_channel_action" : normalizedPurpose
        self.replyTokenClockSkewSeconds = max(0, replyTokenClockSkewSeconds)
        self.maxRequestsPerWindow = max(1, maxRequestsPerWindow)
        self.rateLimitWindowSeconds = max(1, rateLimitWindowSeconds)
        self.maxActiveTasksPerIdentity = max(1, maxActiveTasksPerIdentity)
        self.remoteTaskLeaseSeconds = max(1, remoteTaskLeaseSeconds)
        self.maxInboundContentCharacters = max(256, maxInboundContentCharacters)
        self.maxResultCharacters = max(256, maxResultCharacters)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case replyTokenRequiredActions
        case replyTokenPurpose
        case replyTokenClockSkewSeconds
        case maxRequestsPerWindow
        case rateLimitWindowSeconds
        case maxActiveTasksPerIdentity
        case remoteTaskLeaseSeconds
        case maxInboundContentCharacters
        case maxResultCharacters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            replyTokenRequiredActions: try container.decodeIfPresent(
                [ChannelRemoteActionClass].self,
                forKey: .replyTokenRequiredActions
            ) ?? [.dangerousApproval, .computerUseStart],
            replyTokenPurpose: try container.decodeIfPresent(String.self, forKey: .replyTokenPurpose)
                ?? "remote_channel_action",
            replyTokenClockSkewSeconds: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .replyTokenClockSkewSeconds
            ) ?? 60,
            maxRequestsPerWindow: try container.decodeIfPresent(Int.self, forKey: .maxRequestsPerWindow) ?? 20,
            rateLimitWindowSeconds: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .rateLimitWindowSeconds
            ) ?? 60,
            maxActiveTasksPerIdentity: try container.decodeIfPresent(
                Int.self,
                forKey: .maxActiveTasksPerIdentity
            ) ?? 1,
            remoteTaskLeaseSeconds: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .remoteTaskLeaseSeconds
            ) ?? 900,
            maxInboundContentCharacters: try container.decodeIfPresent(
                Int.self,
                forKey: .maxInboundContentCharacters
            ) ?? 8_000,
            maxResultCharacters: try container.decodeIfPresent(Int.self, forKey: .maxResultCharacters) ?? 4_000
        )
    }

    func requiresReplyToken(for action: ChannelRemoteActionClass) -> Bool {
        replyTokenRequiredActions.contains(action)
    }

    var dictionary: [String: Any] {
        [
            "enabled": enabled,
            "reply_token_required_actions": replyTokenRequiredActions.map(\.rawValue),
            "reply_token_purpose": replyTokenPurpose,
            "reply_token_clock_skew_seconds": replyTokenClockSkewSeconds,
            "max_requests_per_window": maxRequestsPerWindow,
            "rate_limit_window_seconds": rateLimitWindowSeconds,
            "max_active_tasks_per_identity": maxActiveTasksPerIdentity,
            "remote_task_lease_seconds": remoteTaskLeaseSeconds,
            "max_inbound_content_characters": maxInboundContentCharacters,
            "max_result_characters": maxResultCharacters,
        ]
    }

    private static func uniqueActions(_ actions: [ChannelRemoteActionClass]) -> [ChannelRemoteActionClass] {
        var seen = Set<ChannelRemoteActionClass>()
        return actions.filter { seen.insert($0).inserted }
    }
}

struct ChannelRemoteSafetyRequest: Equatable, Sendable {
    var identity: ChannelIdentity
    var action: ChannelRemoteActionClass
    var content: String?
    var replyTokenValidation: ChannelVerifiedReplyTokenValidation?
    var taskId: String?

    init(
        identity: ChannelIdentity,
        action: ChannelRemoteActionClass,
        content: String? = nil,
        replyTokenValidation: ChannelVerifiedReplyTokenValidation? = nil,
        taskId: String? = nil
    ) {
        self.identity = identity
        self.action = action
        self.content = content
        self.replyTokenValidation = replyTokenValidation
        self.taskId = taskId.flatMap(Self.normalizedOptionalId)
    }

    private static func normalizedOptionalId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ChannelRemoteSafetyDecision: Equatable, Sendable {
    var allowed: Bool
    var reason: ChannelRemoteSafetyDecisionReason
    var message: String
    var retryAfterSeconds: TimeInterval?
    var contentAssessment: ChannelRemoteContentAssessment?
    var details: [String: String]

    static func allow(
        contentAssessment: ChannelRemoteContentAssessment? = nil,
        details: [String: String] = [:]
    ) -> ChannelRemoteSafetyDecision {
        ChannelRemoteSafetyDecision(
            allowed: true,
            reason: .allowed,
            message: Self.message(for: .allowed),
            contentAssessment: contentAssessment,
            details: details
        )
    }

    static func deny(
        _ reason: ChannelRemoteSafetyDecisionReason,
        retryAfterSeconds: TimeInterval? = nil,
        contentAssessment: ChannelRemoteContentAssessment? = nil,
        details: [String: String] = [:]
    ) -> ChannelRemoteSafetyDecision {
        ChannelRemoteSafetyDecision(
            allowed: false,
            reason: reason,
            message: Self.message(for: reason),
            retryAfterSeconds: retryAfterSeconds,
            contentAssessment: contentAssessment,
            details: details
        )
    }

    var dictionary: [String: Any] {
        var row: [String: Any] = [
            "allowed": allowed,
            "reason": reason.rawValue,
            "message": message,
        ]
        if let retryAfterSeconds {
            row["retry_after_seconds"] = retryAfterSeconds
        }
        if let contentAssessment {
            row["content_assessment"] = contentAssessment.dictionary
        }
        if !details.isEmpty {
            row["details"] = details
        }
        return row
    }

    private static func message(for reason: ChannelRemoteSafetyDecisionReason) -> String {
        switch reason {
        case .allowed:
            return "Allowed by remote channel safety policy."
        case .disabled:
            return "Denied: remote channel safety policy is disabled."
        case .invalidIdentity:
            return "Denied: remote channel identity is missing a required installation or sender id."
        case .replyTokenRequired:
            return "Denied: this remote channel action requires a fresh accepted reply token."
        case .replyTokenRejected:
            return "Denied: the supplied reply token was not accepted."
        case .rateLimited:
            return "Denied: remote channel action rate limit exceeded for this identity."
        case .activeTaskLimitExceeded:
            return "Denied: this identity already has the maximum number of active remote tasks."
        case .taskIdRequired:
            return "Denied: remote task actions require a stable task id."
        }
    }
}

struct ChannelRemoteResultPayload: Equatable, Sendable {
    var text: String
    var credentials: [String]
    var replyTokens: [String]

    init(text: String, credentials: [String] = [], replyTokens: [String] = []) {
        self.text = text
        self.credentials = credentials
        self.replyTokens = replyTokens
    }
}

struct ChannelRemoteSanitizedResult: Equatable, Sendable {
    var text: String
    var redacted: Bool
    var truncated: Bool
    var originalCharacterCount: Int
    var emittedCharacterCount: Int

    var dictionary: [String: Any] {
        [
            "text": text,
            "redacted": redacted,
            "truncated": truncated,
            "original_character_count": originalCharacterCount,
            "emitted_character_count": emittedCharacterCount,
        ]
    }
}
