//
//  IMessageRPCClientProcessTests.swift
//  osaurusTests
//
//  Live-process coverage for `IMessageProcessRPCClient` against a scripted
//  fake helper: a request timeout must kill the wedged sequential helper so
//  the next call gets a fresh process, shutdown must terminate the child,
//  and helper death must surface as a `__helper_terminated__` notification
//  so the receive runtime can resubscribe from its persisted cursor.
//
//  The client resolves its executable through the DEBUG-only
//  `OSAURUS_IMSG_PATH` dev override; the env var is set only while
//  `AgentChannelConfigurationTestLock` is held so suites that assert on the
//  real helper verification state never observe it.
//

#if os(macOS) && DEBUG

    import Darwin
    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite(.serialized)
    struct IMessageRPCClientProcessTests {

        @Test func timeoutKillsWedgedHelperSoNextCallGetsFreshProcess() async throws {
            try await withScriptedHelper { client in
                let firstPid = try await helperPid(client)

                // `hang` never answers. The helper is strictly sequential, so
                // without the kill every queued call would time out behind it
                // forever (the permanent Retry loop).
                await #expect(throws: IMessageRPCError.timeout(method: "hang")) {
                    _ = try await client.call(method: "hang", params: [:], timeout: 1)
                }

                // The wedged process is gone and the next call spawns a fresh
                // helper instead of queueing behind the stuck request.
                try await waitForProcessExit(pid: firstPid)
                let secondPid = try await helperPid(client)
                #expect(secondPid != firstPid)
                await client.shutdown()
            }
        }

        @Test func shutdownTerminatesTheChildProcess() async throws {
            try await withScriptedHelper { client in
                let pid = try await helperPid(client)
                #expect(kill(pid, 0) == 0)

                await client.shutdown()
                try await waitForProcessExit(pid: pid)

                // Requests after shutdown relaunch cleanly rather than
                // touching the dead handle.
                let relaunched = try await helperPid(client)
                #expect(relaunched != pid)
                await client.shutdown()
            }
        }

        @Test func helperExitEmitsTerminationNotification() async throws {
            try await withScriptedHelper { client in
                let received = NotificationCollector()
                await client.setNotificationHandler { method, _ in
                    received.append(method)
                }

                // `quit` answers, then the script exits: the client must
                // synthesize the local termination notification the watch
                // consumer uses to end its session and resubscribe.
                _ = try await client.call(method: "quit", params: [:], timeout: 5)
                for _ in 0 ..< 100 {
                    if received.methods.contains(IMessageRPCNotification.helperTerminated) {
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                #expect(received.methods.contains(IMessageRPCNotification.helperTerminated))
                await client.shutdown()
            }
        }

        // MARK: - Scripted helper harness

        /// Newline-framed JSON-RPC fake helper. Answers every request with
        /// its own pid, hangs forever on `hang`, and exits after `quit`.
        private static let helperScript = """
            #!/bin/bash
            [ "$1" = "rpc" ] || exit 64
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
              case "$line" in
                *'"method":"hang"'*) sleep 30 ;;
                *'"method":"quit"'*)
                  printf '{"id":%s,"jsonrpc":"2.0","result":{"ok":true}}\\n' "$id"
                  exit 0
                  ;;
                *) printf '{"id":%s,"jsonrpc":"2.0","result":{"pid":%s}}\\n' "$id" "$$" ;;
              esac
            done
            """

        /// Install the scripted helper, point the dev override at it, and run
        /// `body` with a fresh process client. The env override is DEBUG-only
        /// and is cleared before the configuration lock is released.
        private func withScriptedHelper(
            _ body: @Sendable (IMessageProcessRPCClient) async throws -> Void
        ) async throws {
            try await AgentChannelConfigurationTestLock.shared.run {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("osaurus-imsg-rpc-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let script = directory.appendingPathComponent("imsg")
                try Data(Self.helperScript.utf8).write(to: script)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: script.path
                )
                setenv(IMessageRuntimeAssets.executableOverrideEnvKey, script.path, 1)
                defer {
                    unsetenv(IMessageRuntimeAssets.executableOverrideEnvKey)
                    try? FileManager.default.removeItem(at: directory)
                }

                // The override must actually be honored, or the client would
                // try to spawn a real helper.
                guard case .overridden = IMessageRuntimeAssets.verifyBundledExecutable() else {
                    Issue.record("OSAURUS_IMSG_PATH override was not honored in this build")
                    return
                }
                try await body(IMessageProcessRPCClient())
            }
        }

        private func helperPid(_ client: IMessageProcessRPCClient) async throws -> Int32 {
            let response = try await client.call(method: "ping", params: [:], timeout: 10)
            let pid = response.object()["pid"] as? Int
            return Int32(try #require(pid))
        }

        private func waitForProcessExit(pid: Int32) async throws {
            for _ in 0 ..< 100 {
                // kill(0) probes liveness; ESRCH means the process is gone.
                if kill(pid, 0) != 0 { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            Issue.record("helper process \(pid) is still running")
        }
    }

    /// Lock-protected collector for notification methods.
    private final class NotificationCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [String] = []

        var methods: [String] { lock.withLock { collected } }

        func append(_ method: String) {
            lock.withLock { collected.append(method) }
        }
    }

#endif
