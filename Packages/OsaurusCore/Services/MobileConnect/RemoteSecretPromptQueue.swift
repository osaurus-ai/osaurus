//
//  RemoteSecretPromptQueue.swift
//  osaurus
//
//  `sandbox_secret_set` without a value asks the user for the secret. In a
//  Mac chat the chat view intercepts the tool's prompt marker and shows
//  SecretPromptOverlay; a run from the paired phone never passes through
//  that view, so the tool parks the request here instead and the phone
//  answers it (`GET/POST /secrets/prompts`, docs/MOBILE_PROTOCOL.md §16.5).
//
//  The value travels once, inside the Secure Channel, straight into the
//  Keychain. It is never logged and never listed back.
//

import Foundation

@MainActor
final class RemoteSecretPromptQueue {
    static let shared = RemoteSecretPromptQueue()

    struct Request: Sendable {
        let id: UUID
        let key: String
        let description: String
        let instructions: String
    }

    private(set) var pending: [Request] = []
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// Suspends until the phone sends the value (returned) or cancels, the
    /// run is cancelled, or `timeout` passes (nil).
    func request(
        key: String,
        description: String,
        instructions: String,
        timeout: Duration = .seconds(300)
    ) async -> String? {
        let request = Request(id: UUID(), key: key, description: description, instructions: instructions)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                continuations[request.id] = continuation
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
            }
        } onCancel: {
            Task { @MainActor in
                RemoteSecretPromptQueue.shared.settle(id: request.id, value: nil, attention: AttentionProducers.abandoned)
            }
        }
    }

    /// Answers one prompt: a value to store, or nil to cancel. False when
    /// the id is no longer pending.
    @discardableResult
    func resolve(id: UUID, value: String?) -> Bool {
        settle(
            id: id,
            value: value,
            attention: value == nil
                ? AttentionResolution(outcome: .dismissed, surface: .phone, decidedBy: .ownerDevice(L("iPhone")))
                // The value is a secret: the resolution records only that it was sent.
                : AttentionResolution(outcome: .replied, surface: .phone, decidedBy: .ownerDevice(L("iPhone")))
        )
    }

    @discardableResult
    fileprivate func settle(id: UUID, value: String?, attention: AttentionResolution) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        pending.removeAll { $0.id == id }
        timeouts.removeValue(forKey: id)?.cancel()
        AttentionCenter.shared.settleFromProducer(id: id, with: attention)
        AttentionProducers.endWaiting(itemId: id)
        continuation.resume(returning: value)
        return true
    }

    /// `GET /secrets/prompts` JSON. Describes what is asked for; there is no
    /// value to list.
    func listJSON() -> Data {
        let rows: [[String: Any]] = pending.map {
            ["id": $0.id.uuidString, "key": $0.key, "description": $0.description, "instructions": $0.instructions]
        }
        return (try? JSONSerialization.data(withJSONObject: ["prompts": rows], options: [.sortedKeys]))
            ?? Data(#"{"prompts":[]}"#.utf8)
    }
}
