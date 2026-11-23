//
//  EvalUnrunnableSpawnTargetTests.swift
//  OsaurusCoreTests
//
//  The eval runner skips a delegation case whose worker is pinned to a model
//  the host has not installed: chat withholds `spawn_agent` for it, so the
//  case would otherwise score the missing install as a delegation failure.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct EvalUnrunnableSpawnTargetTests {
    @MainActor
    @Test("a worker pinned to an uninstalled model is reported unrunnable")
    func uninstalledWorkerModelIsUnrunnable() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-eval-spawn-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let worker = Agent(
                name: "Eval Worker", description: "returns a token", systemPrompt: "x",
                defaultModel: "JANGQ-AI/Not-Installed-Worker-JANG_4M")
            AgentStore.save(worker)
            AgentManager.shared.refresh()
            let missing = UUID()

            let unrunnable = await EvalHostBootstrap.unrunnableSpawnTargets([worker.id, missing])
            #expect(unrunnable == [worker.id, missing])
        }
    }
}
