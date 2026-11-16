//
//  CapabilityClaimsWorkingFolderTests.swift
//  OsaurusCoreTests
//
//  An Orchestrator eval turn with a working folder composes the prompt the
//  app sends once the Folder chip has attached one; without it, the
//  no-folder variant.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct CapabilityClaimsWorkingFolderTests {
    private actor Engine: ResponsesEngineProtocol {
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            AsyncThrowingStream { c in
                c.yield(.outputTextDelta("answer"))
                c.yield(
                    .responseCompleted(
                        .init(
                            responseID: "resp_folder", status: .completed, functionCalls: [],
                            tokenCount: 1, tokensPerSecond: 1, unclosedReasoning: false,
                            stopReason: "stop", promptTokensPerSecond: nil, mtp: nil)))
                c.yield(.drained)
                c.finish()
            }
        }
    }

    private func orchestratorPrompt(workingFolder: URL?) async -> String {
        await CapabilityClaimsEvaluator.runConversation(
            query: "Add a Usage section to the README.", agentId: Agent.defaultId, maxIterations: 1,
            model: "fixture-model", workingFolder: workingFolder, engine: Engine()
        ).systemPrompt
    }

    @Test
    func aWorkingFolderComposesTheFolderAttachedPrompt() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("claims-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let attached = await orchestratorPrompt(workingFolder: folder)
        #expect(attached.contains("A working folder is attached"))
        #expect(!attached.contains("No working folder is attached"))

        let bare = await orchestratorPrompt(workingFolder: nil)
        #expect(bare.contains("No working folder is attached"))
    }
}
