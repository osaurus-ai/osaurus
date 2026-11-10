//
//  ConfiguratorHandoffTests.swift
//  OsaurusCoreTests
//
//  `configurator_handoff`: the user's words reach the Configurator verbatim,
//  every handoff starts from a fresh context, the spawn-pool permission is
//  the only check skipped, and an `osaurus_config` apply inside the handoff
//  still waits on the approval card.
//

import Foundation
import Testing

@testable import OsaurusCore

private actor ScriptedConfiguratorModel {
    private(set) var requests: [ChatCompletionRequest] = []
    private let toolArguments: String

    init(toolArguments: String) { self.toolArguments = toolArguments }

    func stream(for request: ResponsesInferenceRequest) throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        let chat = request.chatCompletionsCompatibilityRequest()
        requests.append(chat)
        let step = requests.count
        let arguments = toolArguments
        return ResponsesGenerationStream.compatibility(
            AsyncThrowingStream { continuation in
                if step == 1 {
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: "osaurus_config", jsonArguments: arguments, toolCallId: "call_apply"))
                } else {
                    continuation.yield("Done for now.")
                    continuation.finish()
                }
            })
    }
}

private actor PositionLimits {
    private(set) var values: [Int?] = []
    func append(_ value: Int?) { values.append(value) }
}

@Suite(.serialized)
@MainActor
struct ConfiguratorHandoffTests {

    private static func makeKind(
        _ arguments: String,
        turnText: String?,
        sessionId: String = "handoff-\(UUID().uuidString)",
        stream: AgentSubagentRunner.ResponsesStreamProvider? = nil
    ) async -> HiddenAgentHandoffKind? {
        await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                await ChatExecutionContext.$currentUserRequest.withValue(turnText) {
                    await ConfiguratorHandoffTool(evalModel: "scripted-configurator", streamProvider: stream)
                        .makeKind(argumentsJSON: arguments)
                }
            }
        }
    }

    // MARK: - Verbatim

    @Test
    func theTurnsTextOverwritesTheModelsParaphrase() async throws {
        let exact = "ugh, can u make the web search thing use brave?? thx"
        let kind = try #require(
            await Self.makeKind(
                #"{"user_message":"Switch the web search provider to Brave.","brief":"set provider\nsecond line"}"#,
                turnText: exact))
        #expect(kind.seedUserContent.contains("user_message: \(exact)"))
        #expect(!kind.seedUserContent.contains("Switch the web search provider to Brave."))
        #expect(kind.seedUserContent.contains("brief: set provider"))
        #expect(!kind.seedUserContent.contains("second line"), "the brief is one line")
    }

    @Test
    func withoutTurnTextTheModelsMessageIsUsedAndEmptyIsRefused() async throws {
        let kind = try #require(
            await Self.makeKind(#"{"user_message":"What is the Configurator?","brief":"explain"}"#, turnText: nil))
        #expect(kind.seedUserContent.contains("user_message: What is the Configurator?"))
        #expect(await Self.makeKind(#"{"brief":"x"}"#, turnText: "  ") == nil)
    }

    @Test
    func onlyTheOrchestratorMayHandOff() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await ConfiguratorHandoffTool().execute(argumentsJSON: #"{"user_message":"hi","brief":"x"}"#)
        }
        #expect(ToolEnvelope.isError(result))
    }

    /// The seed carries the session state and the catalog rows that match,
    /// so the Configurator quotes real breadcrumbs.
    @Test
    func theSeedCarriesStateAndCatalogRows() async throws {
        let sid = "handoff-seed-\(UUID().uuidString)"
        SessionStateRegistry.shared.seed(sessionId: sid, state: SessionState(goal: "tune the settings helper"))
        let kind = try #require(
            await Self.makeKind(
                #"{"user_message":"x","brief":"configurator temperature"}"#,
                turnText: "Where do I change the Configurator Model?", sessionId: sid))
        #expect(kind.seedUserContent.contains("goal: tune the settings helper"))
        #expect(kind.seedUserContent.contains("[Settings catalog: rows matching the request]"))
        #expect(kind.seedUserContent.contains("settings.configurator.model"))
    }

    // MARK: - Fresh context and permission

    @Test
    func everyHandoffStartsFromAFreshContext() async throws {
        let scope = SubagentScope(sessionId: "s", toolCallId: "call", agentId: Agent.defaultId)
        let first = try #require(await Self.makeKind(#"{"brief":"a"}"#, turnText: "first request"))
        let second = try #require(await Self.makeKind(#"{"brief":"b"}"#, turnText: "second request"))
        _ = try await first.resolveModel(scope)
        let resolved = try await second.resolveModel(scope)
        #expect(resolved.name == "scripted-configurator")

        let messages = second.seedMessages
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.first?.content?.hasPrefix("# Osaurus Settings") == true)
        #expect(messages.last?.content?.contains("second request") == true)
        #expect(!messages.contains { ($0.content ?? "").contains("first request") })
    }

    /// Admission prices the run's own ceiling, not the model's whole window,
    /// and every request the run makes carries that same ceiling.
    @Test
    func aHandoffPricesAndEnforcesItsRunContract() async throws {
        let limits = PositionLimits()
        let kind = try #require(
            await Self.makeKind(
                #"{"brief":"a"}"#, turnText: "what port does the server use",
                stream: { request in
                    await limits.append(request.context.admissionPositionLimit)
                    return ResponsesGenerationStream.compatibility(
                        AsyncThrowingStream { continuation in
                            continuation.yield("Settings → Server.")
                            continuation.finish()
                        })
                }))
        #expect(kind.admissionRequestEstimate() == nil, "unresolved runs price the whole window")
        let scope = SubagentScope(sessionId: "s-\(UUID().uuidString)", toolCallId: "call", agentId: Agent.defaultId)
        let resolved = try await kind.resolveModel(scope)
        let contract = try #require(kind.runContract)
        let window = await AgentLoopBudget.resolveContextWindow(modelId: resolved.name)
        #expect(contract.contextPositions <= window)
        #expect(kind.admissionRequestEstimate()?.enforcedPositionCeiling == contract.contextPositions)
        let minimum = try #require(kind.minimumAdmissionContextPositions)
        #expect(minimum <= contract.contextPositions)

        #expect(!kind.tightenAdmissionContextPositions(to: contract.contextPositions))
        #expect(!kind.tightenAdmissionContextPositions(to: minimum - 1))
        var enforced = contract.contextPositions
        if minimum < contract.contextPositions {
            #expect(kind.tightenAdmissionContextPositions(to: minimum))
            #expect(kind.admissionContextWasMemoryFitted)
            #expect(kind.admissionRequestEstimate()?.enforcedPositionCeiling == minimum)
            enforced = minimum
        }

        let feed = SubagentFeed(toolCallId: "call", kindId: "configurator", title: "Osaurus settings")
        _ = try await kind.run(scope, resolved, feed: feed, interrupt: InterruptToken())
        let seen = await limits.values
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0 == enforced })
    }

    /// The pool permission is skipped; nothing else is.
    @Test
    func theSpawnPoolPermissionIsTheOnlyCheckSkipped() async throws {
        let kind = try #require(await Self.makeKind(#"{"brief":"a"}"#, turnText: "hi"))
        let scope = SubagentScope(sessionId: "s", toolCallId: "call", agentId: Agent.defaultId)
        let decision = await kind.permission(scope, ResolvedModel(name: "m", isLocal: false))
        #expect(decision == .allow)
        #expect(!ChatExecutionContext.autoApproveToolPrompts)
    }

    // MARK: - Apply waits on the approval card

    @Test(arguments: [false, true])
    func anApplyInsideTheHandoffWaitsOnTheApprovalCard(approve: Bool) async throws {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let before = ConfiguratorConfigurationStore.load()
        defer { ConfiguratorConfigurationStore.save(before) }
        let target: Double = before.temperature.map { Double($0) } == 1.7 ? 1.6 : 1.7

        let model = ScriptedConfiguratorModel(
            toolArguments: #"{"action":"apply","yaml":"configurator:\n  temperature: \#(target)\n"}"#)
        let kind = try #require(
            await Self.makeKind(
                #"{"brief":"set temperature"}"#, turnText: "set the settings helper temperature to \(target)",
                stream: { request in try await model.stream(for: request) }))
        let scope = SubagentScope(sessionId: "s-\(UUID().uuidString)", toolCallId: "call", agentId: Agent.defaultId)
        let resolved = try await kind.resolveModel(scope)
        let feed = SubagentFeed(toolCallId: "call", kindId: "configurator", title: "Osaurus settings")

        ConfigApprovalQueue.shared.surfaceDidMount()
        defer { ConfigApprovalQueue.shared.surfaceDidUnmount() }
        let run = Task { try await kind.run(scope, resolved, feed: feed, interrupt: InterruptToken()) }

        var request: ConfigApprovalRequest?
        for _ in 0..<200 {
            request = ConfigApprovalQueue.shared.pending.first
            if request != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let card = try #require(request, "the apply never parked an approval card")
        #expect(card.plan.actions.contains { $0.section == "configurator" })
        #expect(ConfiguratorConfigurationStore.load().temperature == before.temperature, "nothing applies before the tap")

        ConfigApprovalQueue.shared.resolve(id: card.id, outcome: approve ? .approved : .denied)
        let result = try await run.value
        let kindName = result.payload["handoff_result"] as? String
        if approve {
            #expect(kindName == "applied")
            #expect(ConfiguratorConfigurationStore.load().temperature == Float(target))
        } else {
            #expect(kindName == "declined")
            #expect(ConfiguratorConfigurationStore.load().temperature == before.temperature)
        }
        let requests = await model.requests
        #expect(requests.first?.messages.map(\.role) == ["system", "user"], "the run starts from a fresh context")
    }

    /// Stop during the handoff: the parked `osaurus_config` call ends with
    /// the turn. Its card goes away and nothing applies afterwards.
    @Test
    func aCancelMidHandoffEndsTheConfiguratorsToolCallWithTheTurn() async throws {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let before = ConfiguratorConfigurationStore.load()
        defer { ConfiguratorConfigurationStore.save(before) }
        let target: Double = before.temperature.map { Double($0) } == 1.7 ? 1.6 : 1.7

        let model = ScriptedConfiguratorModel(
            toolArguments: #"{"action":"apply","yaml":"configurator:\n  temperature: \#(target)\n"}"#)
        let kind = try #require(
            await Self.makeKind(
                #"{"brief":"set temperature"}"#, turnText: "set the settings helper temperature to \(target)",
                stream: { request in try await model.stream(for: request) }))
        let scope = SubagentScope(sessionId: "s-\(UUID().uuidString)", toolCallId: "call", agentId: Agent.defaultId)
        let resolved = try await kind.resolveModel(scope)
        let feed = SubagentFeed(toolCallId: "call", kindId: "configurator", title: "Osaurus settings")

        ConfigApprovalQueue.shared.surfaceDidMount()
        defer { ConfigApprovalQueue.shared.surfaceDidUnmount() }
        let interrupt = InterruptToken()
        let run = Task { try await kind.run(scope, resolved, feed: feed, interrupt: interrupt) }

        var request: ConfigApprovalRequest?
        for _ in 0..<200 {
            request = ConfigApprovalQueue.shared.pending.first
            if request != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let card = try #require(request, "the apply never parked an approval card")

        let stoppedAt = ContinuousClock.now
        interrupt.interrupt()
        _ = try? await run.value
        let elapsed = ContinuousClock.now - stoppedAt
        #expect(elapsed < .seconds(ToolRegistry.defaultBodyGraceSeconds), "the run waited out the grace window: \(elapsed)")
        #expect(!ConfigApprovalQueue.shared.pending.contains { $0.id == card.id }, "the card outlived the turn")
        // A late tap on the stale card changes nothing.
        ConfigApprovalQueue.shared.resolve(id: card.id, outcome: .approved)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ConfiguratorConfigurationStore.load().temperature == before.temperature)
        #expect(await model.requests.count == 1, "no step ran after Stop")
    }

    // MARK: - Outcome

    @Test
    func theOutcomeComesFromWhatTheRunDidNotItsProse() {
        let apply = #"{"action":"apply","yaml":"x"}"#
        func call(_ result: String) -> HandoffToolCall {
            HandoffToolCall(name: "osaurus_config", argumentsJSON: apply, result: result)
        }
        let applied = ToolEnvelope.success(tool: "osaurus_config", result: ["status": "applied"])
        let setup = ToolEnvelope.success(
            tool: "osaurus_config", result: ["status": "applied", "results": [["status": "needs_user_action"]]])
        let denied = ToolEnvelope.failure(kind: .userDenied, message: "no", tool: "osaurus_config")
        let read = HandoffToolCall(
            name: "osaurus_help", argumentsJSON: #"{"action":"find"}"#,
            result: ToolEnvelope.success(tool: "osaurus_help", text: "x"))

        #expect(ConfiguratorHandoffTool.classify([call(applied)], digest: "Done.") == .applied("Done."))
        #expect(ConfiguratorHandoffTool.classify([call(setup)], digest: "Sign in.") == .needsSetup("Sign in."))
        #expect(ConfiguratorHandoffTool.classify([call(denied)], digest: "Not changed.") == .declined("Not changed."))
        #expect(ConfiguratorHandoffTool.classify([read], digest: "It's here.") == .answer("It's here."))
        #expect(ConfiguratorHandoffTool.classify([], digest: "I changed it!") == .answer("I changed it!"))
    }

    @Test
    func aChangeThatLandedBeforeTheStepCapIsNeverReportedBlank() {
        #expect(HiddenAgentHandoffKind.cappedOutcome(.applied(""))
            == .applied(HiddenAgentHandoffKind.cappedAppliedText))
        #expect(HiddenAgentHandoffKind.cappedOutcome(.applied("Done.")) == .applied("Done."))
        #expect(HiddenAgentHandoffKind.cappedOutcome(.answer("It's here.")) == nil)
    }

    @Test
    func aFinishedImportEndsTheRunAndItsSummaryIsTheReply() {
        func call(_ name: String, _ result: String) -> HandoffToolCall {
            HandoffToolCall(name: name, argumentsJSON: "{}", result: result)
        }
        let summary = "Installed 3 skills: Tempo, Wallet, Tempo Docs."
        let installed = call(
            OsaurusImportTool.toolName,
            ToolEnvelope.success(tool: "osaurus_import", result: ["status": "installed", "summary": summary]))
        let denied = call(
            OsaurusImportTool.toolName,
            ToolEnvelope.failure(kind: .userDenied, message: "The user didn't install it.", tool: "osaurus_import"))
        let wrongTool = call(
            OsaurusImportTool.toolName,
            ToolEnvelope.failure(kind: .invalidArgs, message: "Call osaurus_config.", tool: "osaurus_import"))

        #expect(ConfiguratorHandoffTool.importFinished(installed))
        #expect(ConfiguratorHandoffTool.importFinished(denied))
        #expect(!ConfiguratorHandoffTool.importFinished(wrongTool))
        #expect(!ConfiguratorHandoffTool.importFinished(call("osaurus_config", installed.result)))
        #expect(ConfiguratorHandoffTool.target.endsRun?(installed) == true)

        #expect(ConfiguratorHandoffTool.classify([installed], digest: "") == .applied(summary))
        #expect(ConfiguratorHandoffTool.classify([installed], digest: "Done.") == .applied("Done."))
        #expect(ConfiguratorHandoffTool.classify([denied], digest: "") == .declined("The user didn't install it."))
    }

    @Test
    func aRunOutOfTimeStillReportsAChangeThatLandedBeforeALaterCall() {
        func call(_ name: String, _ result: String) -> HandoffToolCall {
            HandoffToolCall(name: name, argumentsJSON: "{}", result: result)
        }
        let target = ConfiguratorHandoffTool.target
        let installed = call(
            OsaurusImportTool.toolName, ToolEnvelope.success(tool: "osaurus_import", result: ["status": "installed"]))
        let cutOff = call(
            OsaurusImportTool.toolName,
            ToolEnvelope.failure(kind: .timeout, message: "The review timed out.", tool: "osaurus_import"))
        let read = call("osaurus_inspect", ToolEnvelope.success(tool: "osaurus_inspect", result: ["agents": []]))

        #expect(HiddenAgentHandoffKind.landedOutcome([installed, cutOff], target: target, exposed: [])
            == .applied(HiddenAgentHandoffKind.deadlineAppliedText))
        #expect(HiddenAgentHandoffKind.landedOutcome([read, cutOff], target: target, exposed: []) == nil)
    }

    @Test
    func theEvalHarnessGivesTheHandoffItsOwnWallClock() {
        let handoff = ConfiguratorHandoffTool.toolName
        #expect(CapabilityClaimsEvaluator.harnessTimeout(for: handoff, default: 25)
            == ConfiguratorHandoffTool.wallClockSeconds)
        #expect(CapabilityClaimsEvaluator.harnessTimeout(for: "osaurus_config", default: 25) == 25)
        #expect(CapabilityClaimsEvaluator.harnessTimeout(for: handoff, default: nil) == nil)
    }

    @Test
    func resultsRoundTripThroughTheEnvelope() {
        let results: [HandoffResult] = [
            .answer("a"), .applied("b"), .needsSetup("c"), .declined("d"),
            .needsChoice(question: "Which?", options: ["One", "Two"]),
            .awaitingUser(RunRef(runId: "r", workflow: "w", status: "awaiting_user"), question: "q"),
        ]
        for result in results {
            #expect(HandoffResult.parse(envelope: result.envelope(tool: "configurator_handoff")) == result)
        }
    }
}
