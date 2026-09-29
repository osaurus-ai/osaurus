import Foundation
import Testing
@testable import OsaurusCore

/// Establishes real global grants for plain test probes without changing the
/// live authorization contract. Locks serialize catalog and storage overrides.
@MainActor
final class DynamicToolProbeFixture {
    private struct Previous {
        let enabled: Bool
        let policy: ToolPermissionPolicy?
    }
    private enum FixtureError: Error { case existingRegistration(String) }
    private var previous: [String: Previous] = [:]

    func register(_ tool: OsaurusTool, enabled: Bool? = true) throws {
        let registry = ToolRegistry.shared
        guard !registry.isRegistered(tool.name), previous[tool.name] == nil else {
            throw FixtureError.existingRegistration(tool.name)
        }
        previous[tool.name] = Previous(
            enabled: registry.isGlobalEnabled(tool.name),
            policy: registry.configuredPolicy(for: tool.name)
        )
        registry.register(tool)
        if let enabled { registry.setEnabled(enabled, for: tool.name) }
    }

    private func restore() {
        let registry = ToolRegistry.shared
        for (name, state) in previous {
            registry.setEnabled(state.enabled, for: name)
            if let policy = state.policy {
                registry.setPolicy(policy, for: name)
            } else {
                registry.clearPolicy(for: name)
            }
            registry.unregister(names: [name])
            #expect(registry.isGlobalEnabled(name) == state.enabled)
            #expect(registry.configuredPolicy(for: name) == state.policy)
        }
        // Missing enabled entries may remain explicit false in the process's
        // registry snapshot. Effective grants are restored; no dictionary-identity
        // claim is made, and these unregistered names are absent from catalogs.
    }

    static func run(_ body: @MainActor @Sendable (DynamicToolProbeFixture) async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            try await withCatalogLock(body)
        }
    }

    /// For probes that also touch sandbox/host-folder state, preserve the
    /// canonical Storage → Sandbox → Dynamic ordering without recursive locks.
    static func runWithSandbox(
        _ body: @MainActor @Sendable (DynamicToolProbeFixture) async throws -> Void
    ) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            try await withCatalogLock(body)
        }
    }

    private static func withCatalogLock(
        _ body: @MainActor @Sendable (DynamicToolProbeFixture) async throws -> Void
    ) async throws {
        try await DynamicCatalogTestLock.shared.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let previousDirectory = ToolConfigurationStore.overrideDirectory
            let approvalKey = ToolApprovalSettings.autoAllowAllDefaultsKey
            let previousApproval = UserDefaults.standard.object(forKey: approvalKey)
            ToolConfigurationStore.flushPendingWrites()
            ToolConfigurationStore.overrideDirectory = directory
            let fixture = DynamicToolProbeFixture()
            defer {
                fixture.restore()
                if let previousApproval {
                    UserDefaults.standard.set(previousApproval, forKey: approvalKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: approvalKey)
                }
                ToolConfigurationStore.flushPendingWrites()
                ToolConfigurationStore.overrideDirectory = previousDirectory
                try? FileManager.default.removeItem(at: directory)
            }
            try await body(fixture)
        }
    }
}
