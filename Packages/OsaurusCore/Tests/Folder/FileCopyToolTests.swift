//
//  FileCopyToolTests.swift
//  osaurusTests
//
//  Verifies the combined-mode `file_copy` bridge: the four-direction
//  routing matrix (workspace/sandbox on each endpoint), the write-grant
//  gate on host-bound destinations, secret source/destination refusal,
//  overwrite and size-cap envelopes, and the combined-mode-only guard.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileCopyToolTests {

    private static let agent = "copy-test-agent"

    private struct Env: Sendable {
        let tmp: URL
        let hostRoot: URL
        /// Host-side directory backing the sandbox agent home
        /// (`/workspace/agents/<agent>` in VM terms).
        let agentDir: URL
        let bridge: SandboxReadBridge
        let previousOverrideRoot: URL?

        func cleanup() {
            OsaurusPaths.overrideRoot = previousOverrideRoot
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func makeEnv() throws -> Env {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("osu-file-copy-\(UUID().uuidString)", isDirectory: true)
        let hostRoot = tmp.appendingPathComponent("host", isDirectory: true)
        try fm.createDirectory(at: hostRoot, withIntermediateDirectories: true)

        let previousOverrideRoot = OsaurusPaths.overrideRoot
        OsaurusPaths.overrideRoot = tmp.appendingPathComponent("osaurus-root", isDirectory: true)
        let agentDir = OsaurusPaths.containerAgentDir(Self.agent)
        try fm.createDirectory(at: agentDir, withIntermediateDirectories: true)

        return Env(
            tmp: tmp,
            hostRoot: hostRoot,
            agentDir: agentDir,
            bridge: SandboxReadBridge(
                agentName: Self.agent,
                home: OsaurusPaths.inContainerAgentHome(Self.agent)
            ),
            previousOverrideRoot: previousOverrideRoot
        )
    }

    /// Build an isolated environment under the process-wide storage-path
    /// lock (`OsaurusPaths.overrideRoot` is a global other suites also
    /// rewrite), run `body`, then restore + delete.
    private func withEnv(
        _ body: @MainActor @Sendable (Env) async throws -> Void
    ) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let env = try makeEnv()
            defer { env.cleanup() }
            try await body(env)
        }
    }

    /// Execute the tool with the task-locals `ToolRegistry.execute` binds
    /// in combined mode: the sandbox bridge, the read-only host scope, and
    /// the folder-write grant.
    private func run(
        _ env: Env,
        args: String,
        bridge: Bool = true,
        allowWrites: Bool = false,
        maxCopyBytes: Int = FileCopyTool.defaultMaxCopyBytes
    ) async throws -> String {
        let tool = FileCopyTool(rootPath: env.hostRoot, maxCopyBytes: maxCopyBytes)
        return try await ChatExecutionContext.$sandboxReadBridge.withValue(
            bridge ? env.bridge : nil
        ) {
            try await ChatExecutionContext.$hostReadOnlyScope.withValue(env.hostRoot) {
                try await ChatExecutionContext.$allowHostFolderWrites.withValue(allowWrites) {
                    try await tool.execute(argumentsJSON: args)
                }
            }
        }
    }

    private func payload(_ output: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
    }

    private func successResult(_ output: String) throws -> [String: Any] {
        let dict = try payload(output)
        #expect(dict["ok"] as? Bool == true, "expected success envelope, got: \(output)")
        return try #require(dict["result"] as? [String: Any])
    }

    private func write(_ url: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// Binary payload (NUL byte, invalid UTF-8) that `file_read` /
    /// `file_write` could never carry — the whole point of the byte bridge.
    private let binaryBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0xFF])

    // MARK: - Routing matrix

    @Test
    func workspaceToSandbox_copiesBytes_withoutWriteGrant() async throws {
        try await withEnv { env in
            try self.write(env.hostRoot.appendingPathComponent("assets/logo.png"), self.binaryBytes)

            let output = try await self.run(
                env,
                args: #"{"source":"assets/logo.png","destination":"/workspace/agents/copy-test-agent/logo.png"}"#
            )

            let result = try self.successResult(output)
            #expect(result["source_area"] as? String == "workspace")
            #expect(result["destination_area"] as? String == "sandbox")
            #expect(result["bytes"] as? Int == self.binaryBytes.count)
            #expect(result["overwrote"] as? Bool == false)

            let copied = try Data(contentsOf: env.agentDir.appendingPathComponent("logo.png"))
            #expect(copied == self.binaryBytes, "byte-exact copy expected on the sandbox side")
        }
    }

    @Test
    func sandboxToWorkspace_requiresWriteGrant() async throws {
        try await withEnv { env in
            try self.write(env.agentDir.appendingPathComponent("out.png"), self.binaryBytes)
            let args =
                #"{"source":"/workspace/agents/copy-test-agent/out.png","destination":"results/out.png"}"#

            // Read-only combined mode: refused, pointing at the setting.
            let refused = try await self.run(env, args: args, allowWrites: false)
            let refusedPayload = try self.payload(refused)
            #expect(refusedPayload["ok"] as? Bool == false)
            #expect(refusedPayload["kind"] as? String == "rejected")
            let message = refusedPayload["message"] as? String ?? ""
            #expect(message.contains("read-only"))
            #expect(message.contains("folder writes"))

            // Writable combined mode: the copy lands in the workspace.
            let output = try await self.run(env, args: args, allowWrites: true)
            let result = try self.successResult(output)
            #expect(result["source_area"] as? String == "sandbox")
            #expect(result["destination_area"] as? String == "workspace")
            let copied = try Data(
                contentsOf: env.hostRoot.appendingPathComponent("results/out.png")
            )
            #expect(copied == self.binaryBytes)
        }
    }

    @Test
    func workspaceToWorkspace_requiresWriteGrant() async throws {
        try await withEnv { env in
            try self.write(env.hostRoot.appendingPathComponent("a.bin"), self.binaryBytes)
            let args = #"{"source":"a.bin","destination":"backup/a.bin"}"#

            let refused = try await self.run(env, args: args, allowWrites: false)
            #expect(try self.payload(refused)["kind"] as? String == "rejected")

            let output = try await self.run(env, args: args, allowWrites: true)
            let result = try self.successResult(output)
            #expect(result["source_area"] as? String == "workspace")
            #expect(result["destination_area"] as? String == "workspace")
            #expect(
                FileManager.default.fileExists(
                    atPath: env.hostRoot.appendingPathComponent("backup/a.bin").path
                )
            )
        }
    }

    @Test
    func sandboxToSandbox_allowedWithoutWriteGrant() async throws {
        try await withEnv { env in
            try self.write(env.agentDir.appendingPathComponent("in.dat"), self.binaryBytes)

            let output = try await self.run(
                env,
                args:
                    #"{"source":"/workspace/agents/copy-test-agent/in.dat","destination":"/workspace/agents/copy-test-agent/copies/in.dat"}"#
            )

            let result = try self.successResult(output)
            #expect(result["source_area"] as? String == "sandbox")
            #expect(result["destination_area"] as? String == "sandbox")
            #expect(
                FileManager.default.fileExists(
                    atPath: env.agentDir.appendingPathComponent("copies/in.dat").path
                )
            )
        }
    }

    // MARK: - Gates

    @Test
    func withoutSandboxBridge_refusedAsCombinedModeOnly() async throws {
        try await withEnv { env in
            try self.write(env.hostRoot.appendingPathComponent("a.bin"), self.binaryBytes)

            let output = try await self.run(
                env,
                args: #"{"source":"a.bin","destination":"/workspace/agents/copy-test-agent/a.bin"}"#,
                bridge: false
            )

            let dict = try self.payload(output)
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["kind"] as? String == "rejected")
            #expect((dict["message"] as? String ?? "").contains("combined"))
        }
    }

    @Test
    func secretSource_refused() async throws {
        try await withEnv { env in
            try self.write(env.hostRoot.appendingPathComponent(".env"), Data("API_KEY=x\n".utf8))

            let output = try await self.run(
                env,
                args: #"{"source":".env","destination":"/workspace/agents/copy-test-agent/.env"}"#
            )

            let dict = try self.payload(output)
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["kind"] as? String == "rejected")
            #expect((dict["message"] as? String ?? "").contains("secret"))
            #expect(
                !FileManager.default.fileExists(
                    atPath: env.agentDir.appendingPathComponent(".env").path
                ),
                "the secret must never reach the sandbox side"
            )
        }
    }

    @Test
    func secretDestination_refused_evenWithWriteGrant() async throws {
        try await withEnv { env in
            try self.write(env.agentDir.appendingPathComponent("payload.txt"), Data("X=1\n".utf8))

            let output = try await self.run(
                env,
                args: #"{"source":"/workspace/agents/copy-test-agent/payload.txt","destination":".env"}"#,
                allowWrites: true
            )

            let dict = try self.payload(output)
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["kind"] as? String == "rejected")
            #expect((dict["message"] as? String ?? "").contains("secret"))
            #expect(
                !FileManager.default.fileExists(
                    atPath: env.hostRoot.appendingPathComponent(".env").path
                )
            )
        }
    }

    // MARK: - Overwrite / size / shape envelopes

    @Test
    func existingDestination_requiresOverwriteTrue() async throws {
        try await withEnv { env in
            try self.write(env.hostRoot.appendingPathComponent("src.bin"), self.binaryBytes)
            try self.write(env.agentDir.appendingPathComponent("dst.bin"), Data("old".utf8))
            let base =
                #"{"source":"src.bin","destination":"/workspace/agents/copy-test-agent/dst.bin"#

            let refused = try await self.run(env, args: base + "\"}")
            let refusedPayload = try self.payload(refused)
            #expect(refusedPayload["ok"] as? Bool == false)
            #expect(refusedPayload["kind"] as? String == "invalid_args")
            #expect(refusedPayload["field"] as? String == "overwrite")

            let output = try await self.run(env, args: base + "\",\"overwrite\":true}")
            let result = try self.successResult(output)
            #expect(result["overwrote"] as? Bool == true)
            let copied = try Data(contentsOf: env.agentDir.appendingPathComponent("dst.bin"))
            #expect(copied == self.binaryBytes)
        }
    }

    @Test
    func oversizedSource_refusedWithCapEnvelope() async throws {
        try await withEnv { env in
            try self.write(env.hostRoot.appendingPathComponent("big.bin"), Data(count: 64))

            let output = try await self.run(
                env,
                args: #"{"source":"big.bin","destination":"/workspace/agents/copy-test-agent/big.bin"}"#,
                maxCopyBytes: 16
            )

            let dict = try self.payload(output)
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["kind"] as? String == "execution_error")
            #expect(dict["retryable"] as? Bool == false)
            #expect((dict["message"] as? String ?? "").contains("copy limit"))
        }
    }

    @Test
    func directorySource_refused() async throws {
        try await withEnv { env in
            try FileManager.default.createDirectory(
                at: env.hostRoot.appendingPathComponent("folder"),
                withIntermediateDirectories: true
            )

            let output = try await self.run(
                env,
                args: #"{"source":"folder","destination":"/workspace/agents/copy-test-agent/folder"}"#
            )

            let dict = try self.payload(output)
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["kind"] as? String == "invalid_args")
            #expect(dict["field"] as? String == "source")
        }
    }

    @Test
    func missingSource_throwsFileNotFound() async throws {
        try await withEnv { env in
            await #expect(throws: FolderToolError.self) {
                _ = try await self.run(
                    env,
                    args: #"{"source":"nope.bin","destination":"/workspace/agents/copy-test-agent/nope.bin"}"#
                )
            }
        }
    }

    @Test
    func workspaceEscapePath_rejected() async throws {
        try await withEnv { env in
            try self.write(env.hostRoot.appendingPathComponent("a.bin"), self.binaryBytes)

            // `/workspace/../...` routes to the sandbox resolver, whose
            // containment check must refuse the traversal.
            await #expect(throws: FolderToolError.self) {
                _ = try await self.run(
                    env,
                    args: #"{"source":"a.bin","destination":"/workspace/../escape.bin"}"#
                )
            }
        }
    }
}
