//
//  SandboxBridgeMigrationFlag.swift
//  osaurus
//
//  Cheap, synchronous check used by the Sandbox settings banner to decide
//  whether to show the "Restart sandbox to apply security update" call to
//  action. The actual token migration is automatic on the next container
//  start — this flag just tells the user that one is needed.
//

import Foundation

public enum SandboxBridgeMigrationFlag {
    /// `true` when the user has a provisioned sandbox whose
    /// `lastProvisionedAppVersion` is older than the running binary.
    /// Implies the new shim and per-agent bridge tokens are not yet
    /// installed inside the running guest, and a container restart is
    /// required for sandboxed plugins to authenticate.
    public static var needsRestart: Bool {
        let cfg = SandboxConfigurationStore.load()
        guard cfg.setupComplete else { return false }
        guard let lastVersion = cfg.lastProvisionedAppVersion else {
            // Pre-existing field-less config: treat as "needs restart" so
            // the migration banner is visible until the user restarts.
            return true
        }
        return lastVersion != currentAppVersion
    }

    /// Convenience accessor mirroring `SandboxManager.currentAppVersion`
    /// so SwiftUI views don't have to reach into the actor.
    public static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}
