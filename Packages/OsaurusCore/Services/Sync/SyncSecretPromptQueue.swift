//
//  SyncSecretPromptQueue.swift
//  osaurus
//
//  `sandbox_secret_set` without a value asks the user for the secret. In a
//  Mac chat the chat view intercepts the tool's prompt marker and shows
//  SecretPromptOverlay; a hosted run (the user chatting from their iPhone or
//  another Mac) never passes through that view, so the tool parks the
//  request here. `SyncHostRunner` publishes it in the conversation's
//  `ai.osaurus.prompt/1` and opens the device's answer.
//
//  Each prompt carries a one-use X25519 public key. The device seals the
//  value to it, so the secret is never written as plain synced data; the
//  private half lives only in this object's memory and dies with the prompt.
//

import CryptoKit
import Foundation

@MainActor
final class SyncSecretPromptQueue {
    static let shared = SyncSecretPromptQueue()

    /// Posted when a scope's pending prompts change. `userInfo["scope"]`.
    static let didChangeNotification = Notification.Name("ai.osaurus.sync.secretPromptsDidChange")

    struct Request: Sendable {
        let id: UUID
        let scope: String
        let key: String
        let description: String
        let instructions: String
        let sealKey: String
        let requestedAt: Date
    }

    private(set) var pending: [Request] = []
    private var privateKeys: [UUID: Curve25519.KeyAgreement.PrivateKey] = [:]
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func pending(scope: String) -> [Request] {
        pending.filter { $0.scope == scope }
    }

    /// Suspends until the device in `scope` sends the value (returned) or
    /// cancels, the run is cancelled, or `timeout` passes (nil).
    func request(
        scope: String,
        key: String,
        description: String,
        instructions: String,
        timeout: Duration = .seconds(300)
    ) async -> String? {
        let recipient = PairingKeyEnvelope.generateRecipientKey()
        let request = Request(
            id: UUID(),
            scope: scope,
            key: key,
            description: description,
            instructions: instructions,
            sealKey: recipient.publicKeyBase64url,
            requestedAt: Date()
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                continuations[request.id] = continuation
                privateKeys[request.id] = recipient.privateKey
                pending.append(request)
                let id = request.id
                AttentionProducers.beginWaiting(itemId: id, step: L("Waiting for a secret"))
                AttentionCenter.shared.raise(
                    AttentionProducers.item(
                        id: id,
                        kind: .secretRequest,
                        title: L("An agent needs \(key)"),
                        body: description,
                        hasInlineCard: false
                    )
                ) { [weak self] resolution in
                    self?.settle(id: id, value: nil, attention: resolution)
                }
                timeouts[request.id] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.settle(
                        id: request.id,
                        value: nil,
                        attention: AttentionResolution(outcome: .timedOut, surface: .system)
                    )
                }
                Self.post(scope: scope)
            }
        } onCancel: {
            Task { @MainActor in
                SyncSecretPromptQueue.shared.settle(id: request.id, value: nil, attention: AttentionProducers.abandoned)
            }
        }
    }

    /// Applies a device's answer to a prompt in `scope`. False when the
    /// prompt is no longer pending there or the sealed value doesn't open.
    @discardableResult
    func resolve(
        id: UUID,
        scope: String,
        answer: SyncHostedRunContract.PromptAnswer,
        deviceLabel: String
    ) -> Bool {
        guard let request = pending.first(where: { $0.id == id }), request.scope == scope else { return false }
        let surface: AttentionSurface = .phone
        let decidedBy = Participant.ownerDevice(deviceLabel)
        if answer.cancel == true {
            return settle(
                id: id,
                value: nil,
                attention: AttentionResolution(outcome: .dismissed, surface: surface, decidedBy: decidedBy)
            )
        }
        guard let sealed = answer.sealed, let key = privateKeys[id],
            let value = try? PairingKeyEnvelope.open(
                sealed,
                privateKey: key,
                info: SyncHostedRunContract.promptSealInfo(id.uuidString)
            )
        else { return false }
        // The value is a secret: the resolution records only that it was sent.
        return settle(
            id: id,
            value: value,
            attention: AttentionResolution(outcome: .replied, surface: surface, decidedBy: decidedBy)
        )
    }

    /// Cancels every prompt in `scope`, when its run ends.
    func cancelAll(scope: String) {
        for request in pending where request.scope == scope {
            settle(id: request.id, value: nil, attention: AttentionProducers.abandoned)
        }
    }

    @discardableResult
    fileprivate func settle(id: UUID, value: String?, attention: AttentionResolution) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        let scope = pending.first { $0.id == id }?.scope
        pending.removeAll { $0.id == id }
        privateKeys[id] = nil
        timeouts.removeValue(forKey: id)?.cancel()
        AttentionCenter.shared.settleFromProducer(id: id, with: attention)
        AttentionProducers.endWaiting(itemId: id)
        continuation.resume(returning: value)
        if let scope { Self.post(scope: scope) }
        return true
    }

    private static func post(scope: String) {
        NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: ["scope": scope])
    }
}
