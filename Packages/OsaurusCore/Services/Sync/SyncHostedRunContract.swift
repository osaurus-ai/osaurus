//
//  SyncHostedRunContract.swift
//  osaurus
//
//  The app data of hosted runs (osaurus-sync docs/app-data.md, "Hosted
//  runs"): one of the user's Macs runs the agent for a chat on another.
//  Each namespace has one writer, the host or the caller, so neither's
//  write replaces the other's.
//

import Foundation
import OsaurusSync

enum SyncHostedRunContract {
    static let directoryNamespace = "ai.osaurus.directory/1"
    /// Caller: which run to stop.
    static let runNamespace = "ai.osaurus.run/1"
    /// Host: the run it's on.
    static let hostRunNamespace = "ai.osaurus.host-run/1"
    /// Host: tool calls waiting for the user.
    static let approvalNamespace = "ai.osaurus.approval/1"
    /// Caller: the user's answers.
    static let approvalAnswerNamespace = "ai.osaurus.approval-answer/1"
    /// Host: questions only the user can answer, such as a secret's value.
    static let promptNamespace = "ai.osaurus.prompt/1"
    /// Caller: answers to those questions. Secrets are sealed to the host.
    static let promptAnswerNamespace = "ai.osaurus.prompt-answer/1"

    static let directoryKind = "agent-directory"

    /// `terminalStopReason` of the host's answer when it doesn't run agents
    /// for other devices, or can't run this one.
    static let declinedStopReason = "host_declined"
    /// `terminalStopReason` of the host's answer to a run a quit or crash cut off.
    static let interruptedStopReason = "interrupted"

    // MARK: - Records

    struct DirectoryEntry: Codable, Equatable, Hashable, Sendable {
        var id: String
        var address: String?
        var name: String
        var description: String?
        var avatar: String?
        /// The host's own Default agent. Every Mac has one, so only devices
        /// without agents of their own (an iPhone) offer it.
        var isDefault: Bool?
    }

    /// Whether the Mac is running, so another device can tell asleep from
    /// out of reach when it isn't connected. Written as it goes to sleep or
    /// quits, best effort.
    struct Presence: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case awake, sleeping, quitting
        }

        var state: State
        /// `localNetworkOnly` (Same Network) or `anywhere`.
        var networkMode: String
        var updatedMs: Int64
    }

    struct Directory: Codable, Equatable, Sendable {
        var v: Int = 1
        var device: String
        var agents: [DirectoryEntry]
        var updatedMs: Int64
        /// What this Mac's build supports (`SyncDeviceFeedContract.features`).
        var features: [String]?
        /// The app version, as `0.25.31 (1234)`.
        var build: String?
        var presence: Presence?

        init(
            device: String,
            agents: [DirectoryEntry],
            updatedMs: Int64,
            features: [String]? = nil,
            build: String? = nil,
            presence: Presence? = nil
        ) {
            self.device = device
            self.agents = agents
            self.updatedMs = updatedMs
            self.features = features
            self.build = build
            self.presence = presence
        }

        /// The same content, whatever the timestamps say.
        func sameContent(as other: Directory) -> Bool {
            device == other.device && agents == other.agents && features == other.features && build == other.build
                && presence?.state == other.presence?.state && presence?.networkMode == other.presence?.networkMode
        }
    }

    struct RunControl: Codable, Equatable, Sendable {
        var v: Int = 1
        var stop: String?
        var stopMs: Int64?
    }

    struct HostRun: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case running, done
        }

        var v: Int = 1
        var turn: String
        var state: State
        var updatedMs: Int64
    }

    struct PendingApproval: Codable, Equatable, Sendable {
        var id: String
        var turnId: String
        var tool: String
        var description: String
        var arguments: String
        var surface: String?
        var offersRunLease: Bool
        var requestedMs: Int64
    }

    struct Approvals: Codable, Equatable, Sendable {
        var v: Int = 1
        var pending: [PendingApproval]
    }

    enum Answer: String, Codable, Sendable {
        case denied, allowOnce, allowForRun, alwaysAllow

        var resolution: ToolPermissionPromptService.PromptResolution {
            switch self {
            case .denied: return .denied
            case .allowOnce: return .allowOnce
            case .allowForRun: return .allowForRun
            case .alwaysAllow: return .alwaysAllow
            }
        }
    }

    struct ApprovalAnswers: Codable, Equatable, Sendable {
        var v: Int = 1
        var answers: [String: Answer]

        init(answers: [String: Answer]) {
            self.answers = answers
        }

        /// Answers a newer version spells differently are skipped, not fatal.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
            let raw = try container.decodeIfPresent([String: String].self, forKey: .answers) ?? [:]
            answers = raw.compactMapValues(Answer.init(rawValue:))
        }
    }

    /// A question the run is waiting on. For `secret`, the answer is sealed
    /// to `sealKey`, a one-use X25519 public key (base64url) whose private
    /// half never leaves the host's memory.
    struct PendingPrompt: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case secret
        }

        var id: String
        var turnId: String
        var kind: Kind
        var key: String
        var description: String
        var instructions: String
        var sealKey: String
        var requestedMs: Int64
    }

    struct Prompts: Codable, Equatable, Sendable {
        var v: Int = 1
        var pending: [PendingPrompt]
    }

    struct PromptAnswer: Codable, Equatable, Sendable {
        /// The user declined to answer.
        var cancel: Bool?
        /// The value, sealed with `PairingKeyEnvelope` to the prompt's
        /// `sealKey` and `promptSealInfo(id)`.
        var sealed: PairingKeyEnvelope.Sealed?
    }

    struct PromptAnswers: Codable, Equatable, Sendable {
        var v: Int = 1
        var answers: [String: PromptAnswer]

        init(answers: [String: PromptAnswer]) {
            self.answers = answers
        }

        /// Answers a newer version spells differently are skipped, not fatal.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
            let raw = try container.decodeIfPresent([String: SkippingAnswer].self, forKey: .answers) ?? [:]
            answers = raw.compactMapValues(\.answer)
        }

        private struct SkippingAnswer: Decodable {
            let answer: PromptAnswer?
            init(from decoder: Decoder) throws { answer = try? PromptAnswer(from: decoder) }
        }
    }

    /// HPKE info for a prompt's sealed answer, so an answer can't be replayed
    /// against another prompt.
    static func promptSealInfo(_ promptId: String) -> Data {
        Data("osaurus-sync-secret-v1:\(promptId.lowercased())".utf8)
    }

    // MARK: - Reading and writing

    static func read<T: Decodable>(_ type: T.Type, _ namespace: String, from conversation: Conversation) -> T? {
        guard let bytes = conversation.appData(namespace), !bytes.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: bytes)
    }

    /// `read` for a value that steers a run on this Mac: it counts only when
    /// signed by this Mac or another of the user's current devices.
    static func readFromOwnDevice<T: Decodable>(
        _ type: T.Type,
        _ namespace: String,
        from conversation: Conversation,
        me: String,
        devices: [Device]
    ) -> T? {
        guard let entry = conversation.appDataEntry(namespace),
            isTrustedSigner(entry.authorDevice, me: me, devices: devices)
        else { return nil }
        return read(type, namespace, from: conversation)
    }

    /// Values written before 0.1.0-beta.6 carry no signer, so an unsigned
    /// value still counts until every client signs.
    nonisolated static func isTrustedSigner(_ signer: String?, me: String, devices: [Device]) -> Bool {
        guard let signer else { return true }
        return SyncHostRunner.isOwnDevice(signer, me: me, devices: devices)
    }

    /// A per-device namespace names its writer; a signed value from any
    /// other device is someone writing in that device's name.
    nonisolated static func isSigned(_ entry: AppDataEntry, byNamespaceDevice device: String) -> Bool {
        guard let signer = entry.authorDevice else { return true }
        return signer.lowercased() == device.lowercased()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// The latest user turn that asks a host to run it, with its index.
    static func latestRunRequest(in turns: [ChatTurnData]) -> (index: Int, turn: ChatTurnData)? {
        guard let index = turns.lastIndex(where: { $0.role == .user && $0.hostRun != nil }) else { return nil }
        return (index, turns[index])
    }

    /// Whether an assistant turn follows the turn at `index`.
    static func isAnswered(_ index: Int, in turns: [ChatTurnData]) -> Bool {
        turns[(index + 1)...].contains { $0.role == .assistant }
    }
}
