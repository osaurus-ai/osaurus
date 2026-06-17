//
//  ComputerUsePromptQueue.swift
//  OsaurusCore — Computer Use
//
//  The local-first consent surface. When the gate returns `.confirm`, the
//  loop awaits `ComputerUsePromptQueue.shared.requestConfirmation(...)`,
//  which parks a `ConfirmRequest` the chat view renders as an inline
//  approve/deny overlay. The user's tap resolves the suspended call. A run
//  that is interrupted or torn down resolves any of its pending prompts as
//  denied so the loop never hangs on a card nobody will answer.
//

import Combine
import Foundation

/// One pending confirmation, surfaced to the user before a gated action runs.
public struct ConfirmRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolCallId: String
    public let preview: ActionPreview

    public init(id: UUID = UUID(), toolCallId: String, preview: ActionPreview) {
        self.id = id
        self.toolCallId = toolCallId
        self.preview = preview
    }
}

/// MainActor-confined queue of pending confirmations. SwiftUI observes
/// `pending` and renders the overlay; `requestConfirmation` is the async
/// seam the loop's confirm closure calls.
@MainActor
public final class ComputerUsePromptQueue: ObservableObject {
    public static let shared = ComputerUsePromptQueue()

    @Published public private(set) var pending: [ConfirmRequest] = []

    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    private init() {}

    /// Park a confirmation and suspend until the user (or a teardown)
    /// resolves it. Returns whether the action was approved.
    public func requestConfirmation(_ preview: ActionPreview, toolCallId: String) async -> Bool {
        let request = ConfirmRequest(toolCallId: toolCallId, preview: preview)
        return await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            pending.append(request)
        }
    }

    /// Resolve a specific pending request (user tapped approve/deny).
    public func resolve(id: UUID, approved: Bool) {
        pending.removeAll { $0.id == id }
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: approved)
    }

    /// Deny + clear every pending request for a run (interrupt / teardown).
    public func cancelAll(forToolCallId toolCallId: String) {
        let affected = pending.filter { $0.toolCallId == toolCallId }
        pending.removeAll { $0.toolCallId == toolCallId }
        for request in affected {
            continuations.removeValue(forKey: request.id)?.resume(returning: false)
        }
    }
}
