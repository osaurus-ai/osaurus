//
//  SandboxScalingTests.swift
//
//  Pod membership with many agents and workflows: restarts never stop
//  running work, MCP servers count as busy only with a request open.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox scaling")
struct SandboxScalingTests {

    // MARK: - Interactive activity

    @Test func openRequestIsBusyUntilAnswered() {
        let activity = SandboxInteractiveActivity()
        #expect(!activity.isBusy)
        activity.noteSent(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}"#.utf8))
        #expect(activity.isBusy)
        activity.noteReceived(Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8))
        #expect(!activity.isBusy)
    }

    @Test func notificationsDoNotCountAsWork() {
        let activity = SandboxInteractiveActivity()
        activity.noteSent(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(!activity.isBusy)
        activity.noteSent(Data(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#.utf8))
        // A server-initiated request with the same id is not the answer.
        activity.noteReceived(Data(#"{"jsonrpc":"2.0","id":"a","method":"roots/list"}"#.utf8))
        #expect(activity.isBusy)
        activity.noteReceived(Data(#"{"jsonrpc":"2.0","id":"a","error":{"code":1}}"#.utf8))
        #expect(!activity.isBusy)
    }

    @Test func stringAndNumericIdsAreDistinct() {
        let activity = SandboxInteractiveActivity()
        activity.noteSent(Data(#"{"id":1,"method":"x"}"#.utf8))
        activity.noteReceived(Data(#"{"id":"1","result":{}}"#.utf8))
        #expect(activity.isBusy)
        activity.reset()
        #expect(!activity.isBusy)
    }

    // MARK: - Pod size

    private func decode(_ json: String) throws -> SandboxConfiguration {
        try JSONDecoder().decode(SandboxConfiguration.self, from: Data(json.utf8))
    }

    private let base = #""cpus":2,"memoryGB":2,"network":"outbound","autoStart":true"#

    @Test func containersPerBootScalesWithMemory() {
        let gib: UInt64 = 1 << 30
        #expect(SandboxConfiguration.defaultContainersPerBoot(physicalMemory: 8 * gib) == 4)
        #expect(SandboxConfiguration.defaultContainersPerBoot(physicalMemory: 16 * gib) == 6)
        #expect(SandboxConfiguration.defaultContainersPerBoot(physicalMemory: 64 * gib) == 8)
    }

    @Test func untouchedLegacyDefaultMovesToScaledDefault() throws {
        let config = try decode("{\(base),\"maxAgentEnvironments\":3}")
        #expect(config.maxAgentEnvironments == SandboxConfiguration.defaultContainersPerBoot())
        #expect(config.maxRetainedEnvironments == SandboxConfiguration.defaultRetainedEnvironments)
        #expect(config.idleShutdownMinutes == 0)
    }

    @Test func userChosenValuesSurvive() throws {
        let legacy = try decode("{\(base),\"maxAgentEnvironments\":5}")
        #expect(legacy.maxAgentEnvironments == 5)
        let split = try decode(
            "{\(base),\"maxAgentEnvironments\":3,\"maxRetainedEnvironments\":2,\"idleShutdownMinutes\":15}")
        #expect(split.maxAgentEnvironments == 3)
        #expect(split.maxRetainedEnvironments == 2)
        #expect(split.idleShutdownMinutes == 15)
    }

    @Test func retainedNeverBelowContainersPerBoot() {
        var config = SandboxConfiguration.default
        config.maxAgentEnvironments = 6
        config.maxRetainedEnvironments = 2
        #expect(config.effectiveRetainedEnvironments == 6)
    }

    @Test func roundTripKeepsSplitFields() throws {
        var config = SandboxConfiguration.default
        config.maxAgentEnvironments = 3
        config.maxRetainedEnvironments = 9
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SandboxConfiguration.self, from: data)
        #expect(decoded.maxAgentEnvironments == 3)
        #expect(decoded.maxRetainedEnvironments == 9)
    }

    // MARK: - Busy error

    @Test func memberNameStripsContainerPrefix() {
        #expect(SandboxManager.memberName(forContainerID: "agent-wf-abc") == "wf-abc")
        #expect(SandboxManager.memberName(forContainerID: "agent-1234") == "1234")
        #expect(SandboxManager.memberName(forContainerID: "osaurus-system") == "osaurus-system")
    }

    @Test func busyErrorNamesHolders() {
        let error = SandboxError.busy(holders: ["wf-abc", "agent-one"])
        let text = error.errorDescription ?? ""
        #expect(text.contains("wf-abc"))
        #expect(text.contains("agent-one"))
        #expect(SandboxToolRegistrar.failureErrorClass(for: error) == "sandbox_busy")
    }

    // MARK: - Fan-out and idle

    @Test func execLimitScalesWithCPUsWithAFloor() {
        #expect(SandboxManager.userExecLimit(cpus: 1) == 4)
        #expect(SandboxManager.userExecLimit(cpus: 2) == 6)
        #expect(SandboxManager.userExecLimit(cpus: 8) == 24)
    }

    @Test func idleStopNeedsTheSettingQuietAndNothingConnected() {
        let now = Date()
        let longAgo = now.addingTimeInterval(-31 * 60)
        func stop(_ minutes: Int, _ last: Date, execs: Int = 0, interactive: Int = 0, holders: Int = 0) -> Bool {
            SandboxManager.shouldStopWhenIdle(
                idleMinutes: minutes, lastActivity: last, now: now,
                runningExecs: execs, interactiveProcesses: interactive, workHolders: holders)
        }
        #expect(stop(30, longAgo))
        #expect(!stop(0, longAgo))
        #expect(!stop(30, now.addingTimeInterval(-60)))
        #expect(!stop(30, longAgo, execs: 1))
        #expect(!stop(30, longAgo, interactive: 1))
        #expect(!stop(30, longAgo, holders: 1))
    }

    // MARK: - Storage and buffers

    @Test func execCaptureStopsAtItsCap() {
        var capture = ExecOutputCapture(cap: 8)
        capture.append(Data("hello".utf8))
        #expect(!capture.truncated)
        capture.append(Data(" world".utf8))
        #expect(capture.truncated)
        #expect(capture.string == "hello wo")
        capture.append(Data("more".utf8))
        #expect(capture.buffer.count == 8)
    }

    @Test func truncatedCaptureDecodesASplitCharacter() {
        var capture = ExecOutputCapture(cap: 4)
        capture.append(Data("abcé".utf8))  // é is two bytes; the cut splits it
        #expect(capture.truncated)
        #expect(capture.string.hasPrefix("abc"))
    }

    @Test func cloneCountsOnlyItsOwnBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("template.img")
        let clone = dir.appendingPathComponent("clone.img")
        try Data(repeating: 7, count: 4 << 20).write(to: source)
        guard clonefile(source.path, clone.path, 0) == 0 else { return }  // not APFS
        let fresh = try #require(SandboxRootfsTemplateStore.privateBytes(at: clone))
        #expect(fresh < 1 << 20)
        let handle = try FileHandle(forWritingTo: clone)
        try handle.write(contentsOf: Data(repeating: 9, count: 1 << 20))
        try handle.synchronize()
        try handle.close()
        let diverged = try #require(SandboxRootfsTemplateStore.privateBytes(at: clone))
        #expect(diverged >= 1 << 20)
        #expect(diverged < 4 << 20)
    }

    @MainActor @Test func oldRunWorkspacesArePrunedButInUseOnesStay() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        var ids: [UUID] = []
        for index in 0 ..< 5 {
            let id = UUID()
            ids.append(id)
            let folder = parent.appendingPathComponent(id.uuidString.lowercased())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))], ofItemAtPath: folder.path)
        }
        let oldest = ids[0].uuidString.lowercased()
        let stale = WorkflowRunStore.staleWorkspaces(in: parent, keep: 2, inUse: [oldest])
        let names = Set(stale.map(\.lastPathComponent))
        #expect(names == Set([ids[1], ids[2]].map { $0.uuidString.lowercased() }))
        #expect(WorkflowRunStore.staleWorkspaces(in: parent, keep: 5, inUse: []).isEmpty)
    }
}
