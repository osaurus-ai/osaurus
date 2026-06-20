//
//  SandboxProvisioningDiagnosticsTests.swift
//  OsaurusCoreTests
//

#if os(macOS)

    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite("Sandbox Provisioning Diagnostics")
    struct SandboxProvisioningDiagnosticsTests {
        private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

        @Test
        func freshRootReportsMissingSetupWithRepairSuggestions() async throws {
            try await Self.withTemporaryRoot { root in
                let report = SandboxProvisioningDiagnostics.makeReport(
                    generatedAt: Self.fixedDate,
                    minimumColdProvisionFreeBytes: 0,
                    operatingSystemMajorVersion: 26,
                    isAppleSilicon: true,
                    environment: [:]
                )

                #expect(report.rootSource == .testOverride)
                #expect(report.configuration.source == .missingUsingDefaults)
                #expect(report.overallReadiness == .needsSetup)

                let workspace = try #require(
                    report.locations.first { $0.id == .containerWorkspace }
                )
                #expect(workspace.status == .missing)
                #expect(workspace.repairSuggestion?.contains("mkdir -p") == true)
                #expect(workspace.path.hasPrefix(root.path))

                let setupFinding = try #require(
                    report.findings.first { $0.code == .setupIncomplete }
                )
                #expect(setupFinding.severity == .warning)
                #expect(setupFinding.repairSuggestion.contains("Set Up Sandbox"))
            }
        }

        @Test
        func wrongTypeWorkspaceBlocksProvisioning() async throws {
            try await Self.withTemporaryRoot { _ in
                try Self.createBaseRoot(setupComplete: true)
                try OsaurusPaths.ensureExists(OsaurusPaths.container())
                try Data("not a directory".utf8).write(to: OsaurusPaths.containerWorkspace())

                let report = SandboxProvisioningDiagnostics.makeReport(
                    generatedAt: Self.fixedDate,
                    minimumColdProvisionFreeBytes: 0,
                    operatingSystemMajorVersion: 26,
                    isAppleSilicon: true,
                    environment: [:]
                )

                #expect(report.overallReadiness == .blocked)
                let workspace = try #require(
                    report.locations.first { $0.id == .containerWorkspace }
                )
                #expect(workspace.status == .wrongType)

                let finding = try #require(
                    report.findings.first {
                        $0.code == .locationWrongType && $0.locationID == .containerWorkspace
                    }
                )
                #expect(finding.severity == .blocked)
                #expect(finding.status == .failed)
                #expect(finding.repairSuggestion.contains("Move or remove"))
            }
        }

        @Test
        func provisionedHostTreeCanReportReadyEvenWhenRuntimeSocketIsAbsent() async throws {
            try await Self.withTemporaryRoot { _ in
                try Self.createReadyProvisioningTree()

                let report = SandboxProvisioningDiagnostics.makeReport(
                    generatedAt: Self.fixedDate,
                    minimumColdProvisionFreeBytes: 0,
                    operatingSystemMajorVersion: 26,
                    isAppleSilicon: true,
                    environment: [:]
                )

                #expect(report.overallReadiness == .ready)
                #expect(!report.findings.contains { $0.severity == .blocked })
                #expect(!report.findings.contains { $0.severity == .warning })

                let bridge = try #require(report.locations.first { $0.id == .bridgeSocket })
                #expect(bridge.status == .missing)
                let rootfs = try #require(
                    report.locations.first { $0.id == .containerRootFSFile }
                )
                #expect(rootfs.status == .ready)
            }
        }

        @Test
        func reportOutputUsesSnakeCaseJSONAndPlainTextFindings() async throws {
            try await Self.withTemporaryRoot { _ in
                let report = SandboxProvisioningDiagnostics.makeReport(
                    generatedAt: Self.fixedDate,
                    minimumColdProvisionFreeBytes: 0,
                    operatingSystemMajorVersion: 26,
                    isAppleSilicon: true,
                    environment: [:]
                )

                let json = try report.jsonString()
                #expect(json.contains(#""overall_readiness" : "needs_setup""#))
                #expect(json.contains(#""root_source" : "test_override""#))
                #expect(json.contains(#""minimum_cold_provision_free_bytes" : 0"#))
                #expect(json.contains(#""setup_complete" : false"#))

                let text = report.plainTextReport
                #expect(text.contains("Sandbox Provisioning Diagnostics"))
                #expect(text.contains("setup_incomplete"))
                #expect(text.contains("repair:"))
            }
        }

        private static func withTemporaryRoot(
            _ body: @Sendable (URL) throws -> Void
        ) async throws {
            try await StoragePathsTestLock.shared.run {
                let fm = FileManager.default
                let root = fm.temporaryDirectory
                    .appendingPathComponent("osaurus-sandbox-diag-\(UUID().uuidString)", isDirectory: true)
                let previousRoot = OsaurusPaths.overrideRoot
                OsaurusPaths.overrideRoot = root
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    try? fm.removeItem(at: root)
                }
                try body(root)
            }
        }

        private static func createBaseRoot(setupComplete: Bool) throws {
            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            try OsaurusPaths.ensureExists(OsaurusPaths.cache())
            let config = SandboxConfiguration(setupComplete: setupComplete)
            try JSONEncoder().encode(config).write(to: OsaurusPaths.sandboxConfigFile(), options: .atomic)
        }

        private static func createReadyProvisioningTree() throws {
            try createBaseRoot(setupComplete: true)
            try OsaurusPaths.ensureExists(OsaurusPaths.container())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerWorkspace())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerAgentsDir())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerSharedDir())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerKernelDir())
            try Data("kernel".utf8).write(to: OsaurusPaths.containerKernelFile(), options: .atomic)
            try Data("initfs".utf8).write(to: OsaurusPaths.containerInitFSFile(), options: .atomic)

            let state = OsaurusPaths.container()
                .appendingPathComponent("containers/osaurus-sandbox", isDirectory: true)
            try OsaurusPaths.ensureExists(state)
            try Data("rootfs".utf8).write(
                to: state.appendingPathComponent("rootfs.ext4"),
                options: .atomic
            )
        }
    }

#endif
