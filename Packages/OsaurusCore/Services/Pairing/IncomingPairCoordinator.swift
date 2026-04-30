//
//  IncomingPairCoordinator.swift
//  osaurus
//
//  Bridges the URL-scheme dispatcher (`PairingDeepLinkRouter`) to whatever
//  window/sheet is responsible for presenting `IncomingPairSheet`. Single
//  source of truth so the UI doesn't have to listen on a custom notification.
//

import Combine
import Foundation

@MainActor
public final class IncomingPairCoordinator: ObservableObject {
    public static let shared = IncomingPairCoordinator()

    /// Set by `PairingDeepLinkRouter` when an `osaurus://...?pair=...` URL is
    /// opened. Cleared by the presenter once the sheet is dismissed (approve
    /// OR decline). Observed views should treat a non-nil value as a request
    /// to surface the approval UI immediately.
    @Published public var pendingInvite: AgentInvite?

    private init() {}
}
