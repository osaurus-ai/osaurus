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
                timeouts[request.id] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.resolve(id: request.id, value: nil)
                }
            }
        } onCancel: {
            Task { @MainActor in
                RemoteSecretPromptQueue.shared.resolve(id: request.id, value: nil)
            }
        }
    }

    /// Answers one prompt: a value to store, or nil to cancel. False when
    /// the id is no longer pending.
    @discardableResult
    func resolve(id: UUID, value: String?) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        pending.removeAll { $0.id == id }
        timeouts.removeValue(forKey: id)?.cancel()
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
