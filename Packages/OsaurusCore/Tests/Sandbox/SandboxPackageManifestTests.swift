//
//  SandboxPackageManifestTests.swift
//
//  Pin the host-side installed-package manifest (record / reconcile /
//  clear) and the compact, capped prompt line it feeds into the static
//  sandbox system-prompt prefix.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SandboxPackageManifestTests {
    private func freshAgentId() -> String { UUID().uuidString }

    @Test func recordMergesDedupesAndSorts() {
        let id = freshAgentId()
        defer { SandboxPackageManifest.shared.clear(agentId: id) }

        SandboxPackageManifest.shared.record(agentId: id, manager: .pip, packages: ["flask", "numpy"])
        // Re-record with overlap + different case + whitespace; the store
        // de-duplicates case-insensitively and keeps a sorted list.
        SandboxPackageManifest.shared.record(agentId: id, manager: .pip, packages: ["NumPy", " pandas "])

        let installed = SandboxPackageManifest.shared.installed(agentId: id)
        #expect(installed.pip == ["flask", "numpy", "pandas"])
        #expect(installed.apk.isEmpty)
        #expect(installed.npm.isEmpty)
    }

    @Test func recordIgnoresMalformedIdAndEmptyPackages() {
        // A non-UUID agent id (the unit-test sandbox uses "test-agent")
        // must no-op rather than write a stray file.
        SandboxPackageManifest.shared.record(agentId: "not-a-uuid", manager: .apk, packages: ["ffmpeg"])
        #expect(SandboxPackageManifest.shared.installed(agentId: "not-a-uuid").isEmpty)

        let id = freshAgentId()
        defer { SandboxPackageManifest.shared.clear(agentId: id) }
        SandboxPackageManifest.shared.record(agentId: id, manager: .apk, packages: ["", "  "])
        #expect(SandboxPackageManifest.shared.installed(agentId: id).isEmpty)
    }

    @Test func reconcileReplacesNamedManagersAndLeavesNilUntouched() {
        let id = freshAgentId()
        defer { SandboxPackageManifest.shared.clear(agentId: id) }

        SandboxPackageManifest.shared.record(agentId: id, manager: .apk, packages: ["ffmpeg"])
        SandboxPackageManifest.shared.record(agentId: id, manager: .pip, packages: ["oldpkg"])

        // Reconcile pip from observed truth, leave apk alone (nil).
        SandboxPackageManifest.shared.reconcile(agentId: id, apk: nil, pip: ["flask"], npm: [])

        let installed = SandboxPackageManifest.shared.installed(agentId: id)
        #expect(installed.apk == ["ffmpeg"], "nil manager must be left untouched")
        #expect(installed.pip == ["flask"], "named manager is replaced with reconciled truth")
        #expect(installed.npm.isEmpty)
    }

    @Test func clearRemovesManifest() {
        let id = freshAgentId()
        SandboxPackageManifest.shared.record(agentId: id, manager: .npm, packages: ["express"])
        #expect(!SandboxPackageManifest.shared.installed(agentId: id).isEmpty)

        SandboxPackageManifest.shared.clear(agentId: id)
        #expect(SandboxPackageManifest.shared.installed(agentId: id).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: OsaurusPaths.agentPackageManifestFile(for: UUID(uuidString: id)!).path
            )
        )
    }

    @Test func recordPersistsAcrossInstances() throws {
        let id = freshAgentId()
        defer { SandboxPackageManifest.shared.clear(agentId: id) }
        SandboxPackageManifest.shared.record(agentId: id, manager: .pip, packages: ["flask"])

        // Decode the on-disk file directly to prove persistence (the shared
        // singleton's in-memory cache is not the only source of truth).
        let url = OsaurusPaths.agentPackageManifestFile(for: try #require(UUID(uuidString: id)))
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(SandboxPackageManifest.Installed.self, from: data)
        #expect(decoded.pip == ["flask"])
    }

    // MARK: - Prompt rendering

    @Test func promptBlockIsEmptyWhenNothingInstalled() {
        #expect(SystemPromptTemplates.installedPackagesPromptBlock(.init()).isEmpty)
    }

    @Test func promptBlockGroupsByManagerAndOmitsEmptyManagers() {
        let block = SystemPromptTemplates.installedPackagesPromptBlock(
            .init(apk: ["ffmpeg"], pip: ["flask", "numpy"], npm: [])
        )
        #expect(block.contains("Already installed"))
        #expect(block.contains("System (apk): ffmpeg"))
        #expect(block.contains("Python (pip): flask, numpy"))
        // npm is empty -> its line is omitted entirely.
        #expect(!block.contains("Node (npm)"))
    }

    @Test func promptBlockCapsLongListsWithOverflowTail() {
        let cap = SystemPromptTemplates.installedPackagesPromptCap
        let many = (1 ... (cap + 5)).map { "pkg\($0)" }
        let block = SystemPromptTemplates.installedPackagesPromptBlock(.init(pip: many))
        #expect(block.contains("+5 more"))
    }

    @Test func sandboxStateIncludesInstalledLineWhenManifestNonEmpty() {
        let section = SystemPromptTemplates.sandboxState(
            installedPackages: .init(pip: ["flask"])
        )
        #expect(section.contains("Already installed"))
        #expect(section.contains("flask"))
    }

    @Test func sandboxStateOmitsInstalledLineWhenManifestEmpty() {
        // Relocated out of the static `sandbox` framing: the framing never
        // carries package state now, and an empty manifest yields an empty
        // `sandboxState` section (dropped by the composer).
        #expect(!SystemPromptTemplates.sandbox().contains("Already installed"))
        #expect(SystemPromptTemplates.sandboxState().isEmpty)
    }
}
