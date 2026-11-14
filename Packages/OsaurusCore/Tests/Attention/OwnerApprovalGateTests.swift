//
//  OwnerApprovalGateTests.swift
//  osaurusTests
//
//  The owner-approval park: the run waits on the owner's answer, a timeout
//  denies, "allow for this conversation" leases only that tool in only that
//  conversation, per-call tools never lease, and the caller's stream sees
//  `waiting` then the outcome.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []
    func append(_ phase: String) { lock.withLock { phases.append(phase) } }
    var all: [String] { lock.withLock { phases } }
}

@MainActor
private func route(
    conversation: String = UUID().uuidString,
    timeout: TimeInterval = 30,
    log: StatusLog = StatusLog()
) -> OwnerApprovalRoute {
    OwnerApprovalRoute(
        agentId: UUID(),
        agentName: "Research Agent",
        agentAddress: "0xab1200000000000000000000000000000000f291",
        caller: Participant(kind: .teammate, handle: "alice", wallet: "0x9c3e0000000000000000000000000000000011aa"),
        workspaceId: nil,
        hostedSessionId: nil,
        conversationKey: conversation,
        timeout: timeout,
        onStatus: { log.append($0.phase) }
    )
}

/// Answers the first pending owner approval for `tool` once it appears.
@MainActor
private func answer(
    _ tool: String, with outcome: AttentionResolution.Outcome, surface: AttentionSurface = .phone
) {
    Task { @MainActor in
        for _ in 0 ..< 200 {
            if let item = AttentionCenter.shared.pending.first(where: {
                $0.kind == .ownerApproval && $0.toolName == tool
            }) {
                AttentionCenter.shared.resolve(id: item.id, with: AttentionResolution(outcome: outcome, surface: surface))
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class GateProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description = "Test-only owner approval probe."
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy
    private(set) var executions = 0

    init(name: String, policy: ToolPermissionPolicy) {
        self.name = name
        self.defaultPermissionPolicy = policy
    }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

@Suite("Owner approval gate", .serialized)
@MainActor
struct OwnerApprovalGateTests {
    private let leasesURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-leases-\(UUID().uuidString).json")

    init() { OwnerApprovalService.shared.resetForTesting(leasesFileURL: leasesURL) }

    /// The tool as a teammate's run on a shared agent set to Ask Me calls it.
    private func runShared(_ tool: GateProbeTool, route: OwnerApprovalRoute) async throws -> String {
        try await ChatExecutionContext.$isExternalSurface.withValue(true) {
            try await ChatExecutionContext.$ownerApprovalRoute.withValue(route) {
                try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
            }
        }
    }

    @Test func denyPolicyIsAFloorTheOwnerIsNeverAsked() async throws {
        try await DynamicToolProbeFixture.run { fixture in
            let tool = GateProbeTool(name: "test_owner_gate_deny_\(UUID().uuidString.prefix(8))", policy: .deny)
            try fixture.register(tool)
            let shared = route()
            await #expect(throws: (any Error).self) {
                _ = try await runShared(tool, route: shared)
            }
            #expect(tool.executions == 0)
            #expect(!AttentionCenter.shared.pending.contains { $0.toolName == tool.name })
        }
    }

    @Test func askPolicyParksThenRuns() async throws {
        try await DynamicToolProbeFixture.run { fixture in
            let tool = GateProbeTool(name: "test_owner_gate_ask_\(UUID().uuidString.prefix(8))", policy: .ask)
            try fixture.register(tool)
            answer(tool.name, with: .approved)
            let result = try await runShared(tool, route: route())
            #expect(tool.executions == 1)
            #expect(!ToolEnvelope.isError(result))
        }
    }

    @Test func askPolicyDeniedNeverRuns() async throws {
        try await DynamicToolProbeFixture.run { fixture in
            let tool = GateProbeTool(name: "test_owner_gate_no_\(UUID().uuidString.prefix(8))", policy: .ask)
            try fixture.register(tool)
            answer(tool.name, with: .denied)
            await #expect(throws: (any Error).self) {
                _ = try await runShared(tool, route: route())
            }
            #expect(tool.executions == 0)
        }
    }

    @Test func fileWritesAreApprovedOneCallAtATime() {
        #expect(OwnerApprovalService.perCallOnSharedRuns == ["file_write", "file_edit"])
    }

    @Test func oneCallerCannotQueueUnboundedApprovals() async throws {
        let caller = Participant(kind: .teammate, handle: "flood", wallet: "0x\(UUID().uuidString.prefix(8))f100d")
        func floodRoute() -> OwnerApprovalRoute {
            OwnerApprovalRoute(
                agentId: UUID(), agentName: "Research Agent", agentAddress: nil, caller: caller,
                workspaceId: nil, hostedSessionId: nil, conversationKey: UUID().uuidString, timeout: 30,
                onStatus: { _ in })
        }
        let prefix = "flood-\(UUID().uuidString)-"
        var waits: [Task<OwnerApprovalDecision, Never>] = []
        for index in 0 ..< OwnerApprovalService.pendingPerCallerLimit {
            let route = floodRoute()
            waits.append(
                Task { @MainActor in
                    await OwnerApprovalService.shared.request(
                        route: route, toolName: "\(prefix)\(index)", callId: nil, perCallApproval: false)
                })
        }
        for _ in 0 ..< 300 {
            let open = AttentionCenter.shared.pending.filter { $0.toolName?.hasPrefix(prefix) == true }.count
            if open == OwnerApprovalService.pendingPerCallerLimit { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let refused = await OwnerApprovalService.shared.request(
            route: floodRoute(), toolName: "\(prefix)extra", callId: nil, perCallApproval: false)
        #expect(refused == .tooManyPending)
        #expect(refused.refusalMessage(toolName: "x", ownerLabel: "@tpae").isEmpty == false)
        let tooManyQuestions = await OwnerApprovalService.shared.ask(route: floodRoute(), question: "?", callId: nil)
        #expect(tooManyQuestions == .tooManyPending)

        for item in AttentionCenter.shared.pending where item.toolName?.hasPrefix(prefix) == true {
            AttentionCenter.shared.resolve(id: item.id, with: AttentionResolution(outcome: .denied, surface: .inline))
        }
        for wait in waits { #expect(await wait.value == .denied) }
    }

    @Test func leasesSurviveARelaunchAndGoWithTheConversation() throws {
        let service = OwnerApprovalService.shared
        let session = UUID()
        service.grantLease(conversationKey: "conv-a", toolName: "web_fetch", sessionId: session)
        service.grantLease(conversationKey: "conv-b", toolName: "web_fetch", sessionId: UUID())

        service.reloadLeasesForTesting()
        #expect(service.hasLease(conversationKey: "conv-a", toolName: "web_fetch"))
        let attributes = try FileManager.default.attributesOfItem(atPath: leasesURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        service.clearLeases(sessionId: session)
        service.reloadLeasesForTesting()
        #expect(!service.hasLease(conversationKey: "conv-a", toolName: "web_fetch"))
        #expect(service.hasLease(conversationKey: "conv-b", toolName: "web_fetch"))

        service.clearLeases(conversationKey: "conv-b")
        #expect(!service.hasLease(conversationKey: "conv-b", toolName: "web_fetch"))
    }

    @Test func aCorruptLeaseFileStartsEmpty() throws {
        try Data("not json".utf8).write(to: leasesURL)
        OwnerApprovalService.shared.reloadLeasesForTesting()
        #expect(!OwnerApprovalService.shared.hasLease(conversationKey: "conv-a", toolName: "web_fetch"))
    }

    @Test func phoneAndNotificationAnswersMustBeOffered() {
        let item = AttentionItem(
            kind: .ownerApproval, requester: nil, agent: nil, sessionId: nil,
            title: "x", toolName: "file_write", actions: [.approve, .deny, .open])
        let lease = AttentionResolution(outcome: .allowedForConversation, surface: .phone)
        #expect(!AttentionCenter.accepts(lease, for: item))
        #expect(!AttentionCenter.accepts(AttentionResolution(outcome: .replied, surface: .desktop), for: item))
        #expect(!AttentionCenter.accepts(AttentionResolution(outcome: .dismissed, surface: .phone), for: item))
        #expect(AttentionCenter.accepts(AttentionResolution(outcome: .approved, surface: .phone), for: item))
        #expect(AttentionCenter.accepts(AttentionResolution(outcome: .allowedForConversation, surface: .inline), for: item))
        #expect(AttentionCenter.accepts(AttentionResolution(outcome: .abandoned, surface: .system), for: item))
    }

    @Test func aRefusedAnswerLeavesTheItemOpen() async throws {
        let tool = "file_write-\(UUID().uuidString)"
        let wait = Task { @MainActor in
            await OwnerApprovalService.shared.request(
                route: route(), toolName: tool, callId: nil, perCallApproval: true)
        }
        var item: AttentionItem?
        for _ in 0 ..< 300 {
            item = AttentionCenter.shared.pending.first { $0.toolName == tool }
            if item != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let open = try #require(item)
        #expect(!open.actions.contains(.allowForConversation))
        #expect(
            !AttentionCenter.shared.resolve(
                id: open.id, with: AttentionResolution(outcome: .allowedForConversation, surface: .phone)))
        #expect(AttentionCenter.shared.pending.contains { $0.id == open.id })
        #expect(AttentionCenter.shared.resolve(id: open.id, with: AttentionResolution(outcome: .denied, surface: .phone)))
        #expect(await wait.value == .denied)
    }

    @Test func approvalResumesTheRun() async {
        let log = StatusLog()
        let tool = "tool-\(UUID().uuidString)"
        answer(tool, with: .approved)
        let decision = await OwnerApprovalService.shared.request(
            route: route(log: log), toolName: tool, callId: "c1", perCallApproval: false
        )
        #expect(decision == .approved)
        #expect(log.all == ["waiting", "approved"])
    }

    @Test func timeoutDenies() async {
        let log = StatusLog()
        let decision = await OwnerApprovalService.shared.request(
            route: route(timeout: 0.05, log: log), toolName: "slow-\(UUID().uuidString)", callId: nil,
            perCallApproval: false
        )
        #expect(decision == .timedOut)
        #expect(!decision.isGranted)
        #expect(log.all == ["waiting", "timed_out"])
        #expect(decision.refusalMessage(toolName: "x", ownerLabel: "@tpae").contains("No answer"))
    }

    @Test func denialIsRefused() async {
        let tool = "tool-\(UUID().uuidString)"
        answer(tool, with: .denied)
        let decision = await OwnerApprovalService.shared.request(
            route: route(), toolName: tool, callId: nil, perCallApproval: false
        )
        #expect(decision == .denied)
    }

    @Test func conversationLeaseCoversOnlyThatToolAndConversation() async {
        let conversation = UUID().uuidString
        let tool = "tool-\(UUID().uuidString)"
        answer(tool, with: .allowedForConversation)
        let first = await OwnerApprovalService.shared.request(
            route: route(conversation: conversation), toolName: tool, callId: nil, perCallApproval: false
        )
        #expect(first == .allowedForConversation)

        let again = await OwnerApprovalService.shared.request(
            route: route(conversation: conversation), toolName: tool, callId: nil, perCallApproval: false
        )
        #expect(again == .leased)
        #expect(!OwnerApprovalService.shared.hasLease(conversationKey: UUID().uuidString, toolName: tool))
        #expect(!OwnerApprovalService.shared.hasLease(conversationKey: conversation, toolName: "other"))
    }

    @Test func perCallToolsNeverLease() async {
        let conversation = UUID().uuidString
        let tool = "tool-\(UUID().uuidString)"
        // The phone and notifications aren't offered the lease for a per-call
        // tool; an in-app answer that still says so counts once.
        answer(tool, with: .allowedForConversation, surface: .inline)
        let decision = await OwnerApprovalService.shared.request(
            route: route(conversation: conversation), toolName: tool, callId: nil, perCallApproval: true
        )
        #expect(decision == .approved)
        #expect(!OwnerApprovalService.shared.hasLease(conversationKey: conversation, toolName: tool))
    }

    @Test func policyDefaultsToDenyAndClampsTimeout() {
        #expect(SharedToolApprovalPolicy.deny.mode == .deny)
        #expect(SharedToolApprovalPolicy(mode: .askOwner, timeoutSeconds: 1).effectiveTimeout == 30)
        #expect(SharedToolApprovalPolicy(mode: .askOwner).effectiveTimeout == 600)
    }
}
