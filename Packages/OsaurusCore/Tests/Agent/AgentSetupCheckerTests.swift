//
//  AgentSetupCheckerTests.swift
//  OsaurusCoreTests
//
//  The first-run gate must catch exactly the things a creator cannot grant
//  on someone else's Mac, and nothing else: a clean agent must never be
//  prompted, and a folder path without a bookmark must always block.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentSetupCheckerTests {

    private func env(
        tools: Set<String> = ["fetch", "time"],
        locals: [String] = ["mlx-community/Qwen3-4bit"],
        granted: Set<SystemPermission> = [.accessibility, .automation],
        bookmarkOK: Bool = true,
        collections: Set<UUID> = []
    ) -> AgentSetupChecker.Environment {
        AgentSetupChecker.Environment(
            registeredToolNames: tools,
            modelCatalog: ConfigModelReference.Catalog(localModelIds: locals, providers: []),
            isPermissionGranted: { granted.contains($0) },
            bookmarkResolves: { _ in bookmarkOK },
            knowledgeCollectionExists: { collections.contains($0) })
    }

    private func agent() -> Agent {
        AgentManager.newCustomAgentRecord(name: "Probe")
    }

    @Test
    func cleanAgent_hasNoItems() {
        var a = agent()
        a.defaultModel = "mlx-community/Qwen3-4bit"
        a.toolSelectionMode = .manual
        a.manualToolNames = ["fetch"]
        #expect(AgentSetupChecker.check(a, environment: env()).isClean)
    }

    @Test
    func folderPathWithoutBookmark_blocks() {
        var a = agent()
        a.workingFolderPath = "/Users/someone/Downloads/Medical Stuff"
        a.workingFolderBookmark = nil
        let report = AgentSetupChecker.check(a, environment: env())
        #expect(report.hasBlockers)
        #expect(report.blocking.first?.kind == .workingFolder)
    }

    @Test
    func staleBookmark_blocks_andResolvingBookmarkDoesNot() {
        var a = agent()
        a.workingFolderPath = "/tmp/x"
        a.workingFolderBookmark = Data([1, 2, 3])
        #expect(AgentSetupChecker.check(a, environment: env(bookmarkOK: false)).hasBlockers)
        #expect(AgentSetupChecker.check(a, environment: env(bookmarkOK: true)).isClean)
    }

    @Test
    func missingModel_blocks() {
        var a = agent()
        a.defaultModel = "qwen3-coder-next-mlx"
        let report = AgentSetupChecker.check(a, environment: env())
        #expect(report.blocking.map(\.kind) == [.model])
    }

    @Test
    func knowledgeOnWithoutCollections_isAdvisory() {
        var a = agent()
        a.settings.knowledgeEnabled = true
        a.settings.knowledgeCollectionIds = [UUID()]  // exists nowhere here
        let report = AgentSetupChecker.check(a, environment: env())
        #expect(!report.hasBlockers)
        #expect(report.items.map(\.kind) == [.knowledgeCollection])
    }

    @Test
    func computerUseWithoutAccessibility_blocks_automationIsAdvisory() {
        var a = agent()
        a.settings.computerUseEnabled = true
        a.settings.appleScriptEnabled = true
        let report = AgentSetupChecker.check(a, environment: env(granted: []))
        #expect(report.blocking.map(\.value) == [SystemPermission.accessibility.rawValue])
        #expect(report.items.contains { $0.value == SystemPermission.automation.rawValue && !$0.isBlocking })
    }

    @Test
    func unknownManualTools_areAdvisory_autoModeIgnored() {
        var a = agent()
        a.toolSelectionMode = .manual
        a.manualToolNames = ["fetch", "linear_search", "notes_create"]
        let report = AgentSetupChecker.check(a, environment: env())
        #expect(!report.hasBlockers)
        #expect(report.items.first?.value == "linear_search, notes_create")
        a.toolSelectionMode = .auto
        #expect(AgentSetupChecker.check(a, environment: env()).isClean)
    }
}

@MainActor
struct AgentSetupStateStoreTests {

    @Test
    func markClearPrune_persistAcrossReads() throws {
        let previous = OsaurusPaths.overrideRoot
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-setup-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        let store = AgentSetupStateStore.shared
        store.resetForTesting()
        let a = UUID(), b = UUID()
        store.markNeedsSetup(a)
        store.markNeedsSetup(b)
        store.markNeedsSetup(a)  // idempotent
        #expect(store.pending == [a, b])
        let onDisk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: AgentSetupStateStore.fileURL)) as? [String: Any]
        #expect((onDisk?["pending"] as? [String])?.count == 2)
        store.clear(a)
        #expect(store.pending == [b])
        store.prune(existing: [])
        #expect(store.pending.isEmpty)
    }
}

/// Source pins in the repo's wiring-guard style: a gate nobody calls is how
/// the first-run check silently regresses.
struct AgentSetupWiringGuardTests {
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Agent/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test
    func creationHook_marksNeedsSetup() throws {
        let manager = try source("Managers/AgentManager.swift")
        #expect(manager.contains("AgentSetupStateStore.shared.markNeedsSetup(agent.id)"))
        #expect(manager.contains("AgentSetupStateStore.shared.clear(id)"))
    }

    @Test
    func spawnAgent_runsTheSetupGate() throws {
        let tool = try source("Tools/SpawnAgentTool.swift")
        #expect(tool.contains("Self.setupRefusal(agentID: agentID, tool: name)"))
    }

    @Test
    func chatAdoption_promptsForSetup() throws {
        let state = try source("Managers/Chat/ChatWindowState.swift")
        #expect(state.contains("AgentSetupPromptCoordinator.shared.agentShown(newAgentId, windowId: windowId)"))
    }
}
