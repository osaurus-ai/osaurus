//
//  PeerInferenceSharing.swift
//  osaurus
//
//  Host-side, user-level switch: may agents paired with mine — workspace
//  teammates, local-network peers, and invite-link shares — list my models
//  and run plain inference through my Osaurus?
//
//  Off (the default) keeps every paired peer on the agent surface only:
//  `GET /agents/{id}` and `POST /agents/{id}/run` (Mode 2) keep working,
//  while `GET /models` / `GET /tags` return an empty catalog and the
//  inference routes (`/chat/completions`, `/completions`, `/responses`,
//  `/messages`, `/embeddings`, media generation, …) are refused with 403.
//  On, paired peers see the same catalog the owner exposes in
//  Server → Models and may call those routes with their agent-scoped key.
//
//  The owner's own callers are never affected: loopback-trusted requests
//  and master-scoped access keys bypass this switch entirely.
//

import Foundation

enum PeerInferenceSharing {
    /// UserDefaults key. Absent = off, so a fresh install (and every existing
    /// install upgrading to this build) shares nothing until the owner opts in.
    nonisolated static let defaultsKey = "ai.osaurus.server.sharePeerInference"

    /// Live read — UserDefaults is thread-safe, so the NIO request gate can
    /// consult this per request without a server restart after a toggle.
    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    nonisolated static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        if enabled {
            defaults.set(true, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
