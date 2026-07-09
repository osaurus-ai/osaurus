//
//  SandboxEvalFixtureTests.swift
//  OsaurusEvalsKitTests
//
//  VM-free unit coverage for the SandboxFrontier harness pieces:
//  fixture decoding, the AutonomousExecConfig mapping, skip gating,
//  and sandboxFiles scoring. Live-VM behaviour stays behind the
//  existing OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS pattern.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct SandboxEvalFixtureTests {

    // MARK: - Fixture decoding

    @Test func sandboxFixtureDecodesAllFields() throws {
        let json = """
            {
              "id": "sandbox.example",
              "domain": "agent_loop",
              "query": "do the thing",
              "fixtures": {
                "sandbox": {
                  "pluginCreate": false,
                  "backgroundProcessEnabled": true,
                  "networkEnabled": false,
                  "allowHostSecretReads": true,
                  "maxCommandsPerTurn": 4,
                  "hostFolder": true,
                  "seedFiles": [
                    { "path": "data/info.txt", "contents": "token\\n" }
                  ],
                  "seedSecrets": [
                    { "key": "EVAL_API_TOKEN", "value": "tok-123" }
                  ]
                }
              },
              "expect": {
                "agentLoop": {
                  "sandboxFiles": [
                    { "path": "out.txt", "contains": "ok" },
                    { "path": "gone.txt", "exists": false }
                  ]
                }
              }
            }
            """
        let testCase = try JSONDecoder().decode(EvalCase.self, from: Data(json.utf8))

        let sandbox = try #require(testCase.fixtures.sandbox)
        #expect(sandbox.pluginCreate == false)
        #expect(sandbox.backgroundProcessEnabled == true)
        #expect(sandbox.networkEnabled == false)
        #expect(sandbox.allowHostSecretReads == true)
        #expect(sandbox.maxCommandsPerTurn == 4)
        #expect(sandbox.hostFolder == true)
        #expect(sandbox.seedFiles?.first?.path == "data/info.txt")
        #expect(sandbox.seedSecrets?.first?.key == "EVAL_API_TOKEN")
        #expect(sandbox.seedSecrets?.first?.value == "tok-123")

        let sandboxFiles = try #require(testCase.expect.agentLoop?.sandboxFiles)
        #expect(sandboxFiles.count == 2)
        #expect(sandboxFiles[0].contains == "ok")
        #expect(sandboxFiles[1].exists == false)
    }

    @Test func nonSandboxCaseDecodesWithNilFixture() throws {
        let json = """
            {
              "id": "frontier.example",
              "domain": "agent_loop",
              "query": "host folder task",
              "fixtures": {},
              "expect": { "agentLoop": {} }
            }
            """
        let testCase = try JSONDecoder().decode(EvalCase.self, from: Data(json.utf8))
        #expect(testCase.fixtures.sandbox == nil)
        #expect(testCase.expect.agentLoop?.sandboxFiles == nil)
    }

    // MARK: - AutonomousExecConfig mapping

    @Test @MainActor func execConfigUsesProductionDefaultsWhenOmitted() {
        let config = EvalRunner.autonomousExecConfig(from: .init())
        #expect(config.enabled)
        #expect(config.maxCommandsPerTurn == 10)
        #expect(config.pluginCreate)
        #expect(!config.allowHostSecretReads)
        #expect(config.sandboxNetworkEnabled)
        #expect(!config.backgroundProcessEnabled)
    }

    @Test @MainActor func execConfigHonorsFixtureOverrides() {
        let config = EvalRunner.autonomousExecConfig(
            from: .init(
                pluginCreate: false,
                backgroundProcessEnabled: true,
                networkEnabled: false,
                allowHostSecretReads: true,
                maxCommandsPerTurn: 3
            )
        )
        #expect(config.enabled)
        #expect(config.maxCommandsPerTurn == 3)
        #expect(!config.pluginCreate)
        #expect(config.allowHostSecretReads)
        #expect(!config.sandboxNetworkEnabled)
        #expect(config.backgroundProcessEnabled)
    }

    // MARK: - Skip gating

    @Test @MainActor func skipGatingSkipsUnavailableAndIncompleteHosts() {
        #expect(
            EvalRunner.sandboxSkipReason(
                availability: .unavailable(reason: "no Containerization"),
                setupComplete: true
            )?.contains("no Containerization") == true
        )
        #expect(
            EvalRunner.sandboxSkipReason(
                availability: .available,
                setupComplete: false
            )?.contains("setup incomplete") == true
        )
        #expect(
            EvalRunner.sandboxSkipReason(availability: .available, setupComplete: true) == nil
        )
    }

    @Test @MainActor func hostCapabilityKindsSkipButProvisioningErrors() {
        // Host can't provide a sandbox at all -> SKIP (same as a missing
        // plugin), so grok/qwen stop ERRORing on a host where Apple
        // Containerization can't boot or is in failure cool-down.
        #expect(EvalRunner.sandboxKindIsHostCapability(.containerUnavailable))
        #expect(EvalRunner.sandboxKindIsHostCapability(.startupFailed))
        // A per-agent provisioning failure is a real setup bug and must
        // still surface as ERROR, not be masked as a skip.
        #expect(!EvalRunner.sandboxKindIsHostCapability(.provisioningFailed))
    }

    // MARK: - sandboxFiles scoring

    @Test @MainActor func sandboxFileScoringResolvesAgainstProvidedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-score-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "RESULT: ok-alpha42\n".write(
            to: root.appendingPathComponent("result.txt"),
            atomically: true,
            encoding: .utf8
        )

        let pass = EvalRunner.scoreFileAssertion(
            .init(path: "result.txt", contains: "ok-alpha42"),
            workspace: root,
            labelPrefix: "sandbox file"
        )
        #expect(pass.passed)
        #expect(pass.note.hasPrefix("sandbox file"))

        let missing = EvalRunner.scoreFileAssertion(
            .init(path: "absent.txt"),
            workspace: root,
            labelPrefix: "sandbox file"
        )
        #expect(!missing.passed)
        #expect(missing.note.contains("missing"))

        let absentOk = EvalRunner.scoreFileAssertion(
            .init(path: "absent.txt", exists: false),
            workspace: root,
            labelPrefix: "sandbox file"
        )
        #expect(absentOk.passed)

        let exact = EvalRunner.scoreFileAssertion(
            .init(path: "result.txt", equals: "RESULT: ok-alpha42\n"),
            workspace: root,
            labelPrefix: "sandbox file"
        )
        #expect(exact.passed)
    }

    // MARK: - Suite decode smoke

    @Test func sandboxFrontierSuiteDecodesCleanly() throws {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/SandboxFrontier", isDirectory: true)

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        // Floor, not exact: new cases must not break this smoke — only
        // deletions or decode drift should.
        #expect(suite.cases.count >= 17, "SandboxFrontier suite shrank; got \(suite.cases.count)")
        for testCase in suite.cases {
            #expect(testCase.domain == "agent_loop")
            #expect(testCase.fixtures.sandbox != nil, "\(testCase.id) missing fixtures.sandbox")
        }
        // Combined-mode cases must carry a host workspace to read from.
        for testCase in suite.cases where testCase.fixtures.sandbox?.hostFolder == true {
            #expect(
                !(testCase.fixtures.workspaceFiles ?? []).isEmpty,
                "\(testCase.id) is combined-mode but seeds no host workspaceFiles"
            )
        }
    }
}
