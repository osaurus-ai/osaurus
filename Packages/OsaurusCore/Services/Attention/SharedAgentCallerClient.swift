//
//  SharedAgentCallerClient.swift
//  osaurus
//
//  The calling side of a shared-agent conversation (Mode 2,
//  `/agents/{address}/run` on a teammate's Mac):
//
//  - `RemotePeerFeatures` remembers what a peer said it supports
//    (`features` on `GET /agents/{id}`).
//  - `RemoteAgentHostHistory` decides when a run may send only its new
//    message (`"osaurus_history": "host"`): the host already holds every
//    earlier turn, and its transcript also has what the owner said.
//  - `RemoteAgentCallerSigner` signs `osaurus_caller` v2 for a run one of
//    this Mac's agents sends, so the host shows that agent by name.
//

import CryptoKit
import Foundation
import LocalAuthentication

/// What each paired Osaurus peer advertised, by provider id. In memory: a
/// fresh `GET /agents/{id}` after launch fills it again.
enum RemotePeerFeatures {
    static let hostHistory = "host_history"
    static let conversationEvents = "conversation_events"
    static let callerV2 = "caller_v2"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byProvider: [UUID: Set<String>] = [:]

    static func record(_ features: Set<String>, providerId: UUID) {
        lock.withLock { byProvider[providerId] = features }
    }

    static func supports(_ feature: String, providerId: UUID) -> Bool {
        lock.withLock { byProvider[providerId]?.contains(feature) ?? false }
    }

    static func resetForTesting() {
        lock.withLock { byProvider.removeAll() }
    }
}

/// Per caller conversation, what was last sent to the host, so a run sends
/// only its new message when the host is known to hold the rest. Anything
/// unexpected (an edited or regenerated turn, a retry, a first run after
/// relaunch) sends the whole conversation, which the host reconciles.
enum RemoteAgentHostHistory {
    static let capacity = 200

    private struct Sent {
        let count: Int
        let digest: String
        let at: Date
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent: [String: Sent] = [:]

    /// The messages to send and whether they are in host-history form.
    static func outbound(_ messages: [ChatMessage], sessionId: String) -> (messages: [ChatMessage], host: Bool) {
        let systemCount = messages.prefix(while: { $0.role == "system" }).count
        let conversation = Array(messages.dropFirst(systemCount))
        return lock.withLock {
            let prior = sent[sessionId]
            record(conversation, sessionId: sessionId)
            guard let last = conversation.last, last.role == "user" else { return (messages, false) }
            let hostHolds: Bool
            if let prior {
                hostHolds =
                    conversation.count > prior.count
                    && digest(Array(conversation.prefix(prior.count))) == prior.digest
            } else {
                hostHolds = conversation.count == 1
            }
            guard hostHolds else { return (messages, false) }
            return (Array(messages.prefix(systemCount)) + [last], true)
        }
    }

    /// Drops what was sent for a conversation (its run failed before the
    /// host could store it).
    static func forget(sessionId: String) {
        _ = lock.withLock { sent.removeValue(forKey: sessionId) }
    }

    static func resetForTesting() {
        lock.withLock { sent.removeAll() }
    }

    private static func record(_ conversation: [ChatMessage], sessionId: String) {
        sent[sessionId] = Sent(count: conversation.count, digest: digest(conversation), at: Date())
        if sent.count > capacity, let oldest = sent.min(by: { $0.value.at < $1.value.at })?.key {
            sent.removeValue(forKey: oldest)
        }
    }

    private static func digest(_ messages: [ChatMessage]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(messages)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Signs `osaurus_caller` for runs one of this Mac's agents sends to a
/// teammate's agent. One signature per agent, target and conversation is
/// kept, so the key is read once per conversation.
enum RemoteAgentCallerSigner {
    struct Signer: Sendable {
        let address: String
        let name: String
        let ownerHandle: String?
        let keyPath: AgentKeyPath
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: OsaurusCallerDeclaration] = [:]
    static let capacity = 200

    /// The calling agent's identity, or nil when it has no key of its own.
    @MainActor
    static func signer(for agentId: UUID) -> Signer? {
        guard let agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn,
            let address = agent.agentAddress, !address.isEmpty, let keyPath = agent.agentKeyPath
        else { return nil }
        return Signer(
            address: address, name: agent.name, ownerHandle: OsaurusIDService.shared.claimedHandle, keyPath: keyPath)
    }

    static func declaration(
        agentId: UUID, targetAgentAddress: String, sessionId: String
    ) async -> OsaurusCallerDeclaration? {
        guard let signer = await signer(for: agentId) else { return nil }
        let key = [agentId.uuidString, targetAgentAddress.lowercased(), sessionId, signer.name, signer.ownerHandle ?? ""]
            .joined(separator: "|")
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let declaration: OsaurusCallerDeclaration? = await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = 300
            guard var master = try? MasterKey.getPrivateKey(context: context) else { return nil }
            defer { master.zeroOut() }
            var child = AgentKey.derive(masterKey: master, path: signer.keyPath)
            defer { child.zeroOut() }
            return try? OsaurusCallerDeclaration.signed(
                agentAddress: signer.address,
                agentName: signer.name,
                ownerHandle: signer.ownerHandle,
                targetAgentAddress: targetAgentAddress,
                sessionId: sessionId,
                agentPrivateKey: child
            )
        }.value
        guard let declaration else { return nil }
        lock.withLock {
            if cache.count >= capacity { cache.removeAll() }
            cache[key] = declaration
        }
        return declaration
    }
}
