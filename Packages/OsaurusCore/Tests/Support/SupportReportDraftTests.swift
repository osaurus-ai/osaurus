//
//  SupportReportDraftTests.swift
//  osaurusTests
//
//  The "Report a Problem" draft: what the user's picks turn into on the wire
//  (`details`), that switching the kind of report drops the old picks, and
//  that "Share extra details" stays metadata only.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Help report draft")
struct SupportReportDraftTests {

    // MARK: - Categories

    /// Raw values are the router's `category` check constraint.
    @Test func categoriesMatchTheRouter() {
        #expect(
            SupportCategory.allCases.map(\.rawValue)
                == ["bug", "cloud", "agent", "workflow", "ios", "store", "model"])
        for category in SupportCategory.allCases {
            #expect(!category.problems.isEmpty)
            #expect(category.problems.last?.id == "other")
            #expect(Set(category.problems.map(\.id)).count == category.problems.count)
        }
        #expect(SupportCategory.bug.extrasTitle == nil)
        #expect(SupportCategory.allCases.filter { $0.extrasTitle != nil }.count == 6)
    }

    /// The router's cloud alert names `problem` and `model` only when they
    /// are short ids, so both stay ids rather than display text.
    @Test func cloudDetailsSendTheModelIdAndProblemId() {
        var draft = SupportReportDraft()
        draft.select(category: .cloud)
        #expect(draft.details == nil)
        draft.cloudModel = SupportPick(id: "openai/gpt-5.1", name: "openai/gpt-5.1")
        draft.problemId = "cannot_connect"
        #expect(
            draft.details
                == .object(["model": .string("openai/gpt-5.1"), "problem": .string("cannot_connect")]))
        #expect(draft.detailRows.map(\.id) == ["model", "problem"])

        draft.select(category: .model)
        #expect(draft.cloudModel == nil)
    }

    // MARK: - Details

    @Test func noCategory_noDetailsAndCannotSend() {
        var draft = SupportReportDraft()
        draft.description = "It broke"
        #expect(draft.details == nil)
        #expect(draft.detailRows.isEmpty)
        #expect(!draft.canSend)
    }

    /// Enum picks go by stable id, names by name; untouched fields are left
    /// out rather than sent empty.
    @Test func detailsUseStableKeysAndSkipEmptyFields() {
        var draft = SupportReportDraft()
        draft.select(category: .bug)
        draft.area = .workflows
        #expect(draft.details == .object(["area": .string("workflows")]))

        draft.select(category: .ios)
        draft.phoneModel = "  iPhone 16 Pro "
        draft.problemId = "pairing"
        #expect(
            draft.details
                == .object(["phone_model": .string("iPhone 16 Pro"), "problem": .string("pairing")]))
        #expect(draft.detailRows.map(\.id) == ["phone_model", "problem"])

        draft.select(category: .store)
        draft.storeDirection = .installing
        draft.storeLink = "https://osaurus.ai/store/x"
        draft.storeListing = SupportPick(id: "ignored", name: "Not sent while installing")
        #expect(
            draft.details
                == .object(["direction": .string("installing"), "link": .string("https://osaurus.ai/store/x")]))
    }

    /// The model pick is sent by id (what the team can look up); the review
    /// shows its name.
    @Test func modelDetailsSendTheIdAndReviewShowsTheName() {
        var draft = SupportReportDraft()
        draft.select(category: .model)
        draft.model = SupportPick(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B")
        #expect(draft.details == .object(["model": .string("mlx-community/Qwen3-8B-4bit")]))
        #expect(draft.detailRows.first?.value == "Qwen3 8B")
    }

    @Test func longValuesAreCappedUnderTheRouterLimit() throws {
        var draft = SupportReportDraft()
        draft.select(category: .store)
        draft.storeDirection = .installing
        draft.storeLink = String(repeating: "x", count: 5000)
        let encoded = try JSONEncoder().encode(try #require(draft.details))
        #expect(encoded.count < 4096)
    }

    /// Switching kind drops the old kind's picks (a hidden agent never rides
    /// along on a model report) but keeps what the user wrote and attached.
    @Test func switchingCategoryKeepsTextAndImagesOnly() {
        var draft = SupportReportDraft()
        draft.select(category: .agent)
        draft.agent = SupportPick(id: "a", name: "Research")
        draft.problemId = "stuck"
        draft.shareExtras = false
        draft.description = "It loops"
        let image = SupportImageAttachment(id: UUID(), data: Data([1]), mimeType: "image/png", width: 1, height: 1)
        draft.images = [image]

        draft.select(category: .model)
        #expect(draft.category == .model)
        #expect(draft.agent == nil)
        #expect(draft.problemId == nil)
        #expect(draft.shareExtras)
        #expect(draft.description == "It loops")
        #expect(draft.images == [image])

        // Re-picking the same kind changes nothing.
        draft.problemId = "load"
        draft.select(category: .model)
        #expect(draft.problemId == "load")
    }

    @Test func sendsExtrasOnlyWithTheSwitchOnAndSomethingToSend() {
        var draft = SupportReportDraft()
        draft.select(category: .bug)
        #expect(!draft.sendsExtras)
        draft.select(category: .workflow)
        #expect(draft.sendsExtras)
        draft.shareExtras = false
        #expect(!draft.sendsExtras)
    }

    // MARK: - Extras

    /// The agent's setup, never its instructions.
    @Test func agentExtrasAreMetadataOnly() throws {
        let agent = Agent(
            name: "Research", systemPrompt: "private instructions", defaultModel: "provider/model",
            modelLocked: true, temperature: 0.4)
        let text = try json(SupportReportExtras.agent(agent))
        #expect(text.contains(#""default_model":"provider/model""#))
        #expect(text.contains(#""model_locked":true"#))
        #expect(text.contains(#""has_instructions":true"#))
        #expect(!text.contains("private instructions"))
    }

    /// Run outcomes and the failed step, never inputs, outputs or error text.
    @Test func workflowExtrasKeepOutcomesAndDropContent() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var failed = WorkflowRun(
            workflowID: UUID(), workflowName: "Invoices", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: .object(["secret": .string("private input")]),
            nodeIDs: ["fetch", "summarize"], startedAt: started)
        failed.status = .failed
        failed.finishedAt = started.addingTimeInterval(12.34)
        failed.output = .string("private output")
        failed.error = WorkflowRunError(
            nodeID: "fetch", reason: "token sk-private leaked in error",
            failure: NodeRunFailure(
                kind: "http_404", retryable: false, errorType: "HTTPError.notFound", fixIn: .workflow,
                hint: "private hint", tool: "fetch_url"))
        let runs = (0 ..< 7).map { _ in failed }

        let value = SupportReportExtras.workflow(runs: runs)
        let text = try json(value)
        guard case .object(let root) = value, case .array(let rows)? = root["workflow_runs"] else {
            Issue.record("unexpected shape")
            return
        }
        #expect(rows.count == SupportReportExtras.workflowRunLimit)
        #expect(
            rows.first
                == .object([
                    "status": .string("failed"), "started_at": .string("2027-01-15T08:00:00Z"),
                    "steps": .number(2), "duration_seconds": .number(12.3), "failed_step": .string("fetch"),
                    "failure_kind": .string("http_404"), "failure_type": .string("HTTPError.notFound"),
                    "fix_in": .string("workflow"), "tool": .string("fetch_url"),
                ]))
        for forbidden in ["private input", "private output", "sk-private", "private hint"] {
            #expect(!text.contains(forbidden), "workflow extras leaked: \(forbidden)")
        }
    }

    /// Connection state, never the error's text.
    @MainActor
    @Test func cloudExtrasKeepTheConnectionStateAndDropErrorText() throws {
        var state = RemoteProviderState(providerId: RemoteProviderManager.osaurusRouterProviderId)
        state.lastError = "401 for wallet 0xprivate"
        state.lastFailureWasTransient = false
        state.discoveredModels = ["openai/gpt-5.1", "anthropic/claude-sonnet-4.5"]
        state.lastConnectedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let text = try json(
            SupportReportExtras.cloud(
                enabled: true, offline: false, hasAccount: true, state: state, pickedModel: "openai/gpt-5.1"))
        #expect(text.contains(#""connected":false"#))
        #expect(text.contains(#""last_attempt_failed":true"#))
        #expect(text.contains(#""failure_transient":false"#))
        #expect(text.contains(#""model_count":2"#))
        #expect(text.contains(#""picked_model_listed":true"#))
        #expect(text.contains(#""last_connected_at":"2027-01-15T08:00:00Z""#))
        #expect(!text.contains("0xprivate"))

        let off = try json(
            SupportReportExtras.cloud(enabled: false, offline: true, hasAccount: false, state: nil, pickedModel: nil))
        #expect(off.contains(#""enabled":false"#))
        #expect(off.contains(#""offline":true"#))
        #expect(!off.contains("picked_model_listed"))
        #expect(!off.contains("failure_transient"))
    }

    /// Pairing state, never the phone's name.
    @Test func pairingExtrasLeaveOutTheDeviceName() throws {
        let device = PairedMobileDevice(
            deviceId: "device-private-id", name: "Alice's iPhone", keyId: UUID(),
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000), keyExpiresAt: nil)
        let text = try json(
            SupportReportExtras.pairing(device: device, reachFromAnywhere: true, keepMacAwake: false))
        #expect(text.contains(#""paired":true"#))
        #expect(text.contains(#""reach_from_anywhere":true"#))
        #expect(text.contains(#""paired_at":"2027-01-15T08:00:00Z""#))
        #expect(!text.contains("Alice"))
        #expect(!text.contains("device-private-id"))

        let unpaired = try json(SupportReportExtras.pairing(device: nil, reachFromAnywhere: false, keepMacAwake: false))
        #expect(unpaired.contains(#""paired":false"#))
        #expect(!unpaired.contains("paired_at"))
    }

    private func json(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder.osaurusCanonical().encode(value), as: UTF8.self)
    }
}
