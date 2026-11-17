//
//  PrivacyConversationPolicyTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Pins when the outbound pipeline asks: the model's own text is
//  redacted without a sheet, tool results follow their setting, a
//  conversation policy (ask / autoRedact / off) and category answers
//  override the default, Never Redact entries skip detection and the
//  leak check, subagents share the root conversation's map, and two
//  passes in one conversation never open two sheets for one value.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Privacy conversation policy", .serialized)
@MainActor
struct PrivacyConversationPolicyTests {
    private static let phone = "949-238-0232"
    private static let feed = "https://feeds.example.com/rss"

    private static func config(_ edit: (inout PrivacyFilterConfiguration) -> Void = { _ in }) -> PrivacyFilterConfiguration {
        var config = PrivacyFilterConfiguration()
        config.enabled = true
        config.aiDetectionEnabled = false
        edit(&config)
        return config
    }

    private static func scope() -> String { "policy-\(UUID().uuidString)" }

    /// A tool loop turn: the user asks, the model calls a tool with a
    /// URL argument and says a phone number, and the tool returns text.
    private static func toolLoop(toolOutput: String) -> [ChatMessage] {
        [
            ChatMessage(role: "user", content: "Summarize the feed"),
            ChatMessage(
                role: "assistant",
                content: "Fetching it now.",
                tool_calls: [
                    ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(name: "web_fetch", arguments: #"{"url":"\#(feed)"}"#)
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "tool", content: toolOutput, tool_calls: nil, tool_call_id: "call_1"),
        ]
    }

    private static func allText(_ messages: [ChatMessage]) -> String {
        messages.map { message in
            (message.content ?? "") + (message.tool_calls?.map(\.function.arguments).joined() ?? "")
        }.joined(separator: "\n")
    }

    // MARK: - Origins

    @Test func modelOwnToolArguments_redactWithoutReview() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-model")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { _ in presentations += 1 }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: Self.toolLoop(toolOutput: "No personal data here."),
            sessionId: Self.scope(),
            providerId: UUID(),
            requestSource: .chatUI
        )
        #expect(presentations == 0, "the model's own tool arguments must not open the sheet")
        let text = Self.allText(scrubbed)
        #expect(!text.contains(Self.feed))
        #expect(text.contains("[URL_1]"))
    }

    @Test func toolResult_asksAndShowsOnlyToolItems() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-tool")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())

        var seen: RedactionReviewState?
        let token = PrivacyReviewService.shared.registerPresenter { state in
            seen = state
            state.confirm()
        }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: Self.toolLoop(toolOutput: "Host phone: \(Self.phone)"),
            sessionId: Self.scope(),
            providerId: UUID(),
            requestSource: .chatUI
        )
        let state = try #require(seen)
        #expect(state.entities.map(\.original) == [Self.phone])
        #expect(state.entities.first?.origin == .toolResult("web_fetch"))
        let text = Self.allText(scrubbed)
        #expect(!text.contains(Self.phone))
        #expect(!text.contains(Self.feed))
    }

    @Test func toolResultPolicyAuto_redactsWithoutReview() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-toolAuto")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config { $0.toolResultPolicy = .autoRedact })

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { _ in presentations += 1 }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: Self.toolLoop(toolOutput: "Host phone: \(Self.phone)"),
            sessionId: Self.scope(),
            providerId: UUID(),
            requestSource: .chatUI
        )
        #expect(presentations == 0)
        #expect(!Self.allText(scrubbed).contains(Self.phone))
    }

    // MARK: - Conversation policy

    @Test func autoRedactPolicy_redactsUserTextWithoutReview() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-auto")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())
        let scope = Self.scope()
        await SessionRedactionStore.shared.setPolicy(scope, .autoRedact)
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { _ in presentations += 1 }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: [ChatMessage(role: "user", content: "Call \(Self.phone)")],
            sessionId: scope,
            providerId: UUID(),
            requestSource: .chatUI
        )
        #expect(presentations == 0)
        #expect(scrubbed.first?.content?.contains("[PHONE_1]") == true)
    }

    @Test func offPolicy_sendsAsWrittenAndKeepsMap() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-off")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())
        let scope = Self.scope()
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }

        // Earlier turn redacted a value under autoRedact.
        await SessionRedactionStore.shared.setPolicy(scope, .autoRedact)
        _ = try await PrivacyFilterPipeline.applyOutbound(
            messages: [ChatMessage(role: "user", content: "Email alice@example.com")],
            sessionId: scope,
            providerId: UUID(),
            requestSource: .chatUI
        )

        await SessionRedactionStore.shared.setPolicy(scope, .off)
        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { _ in presentations += 1 }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let result = try await PrivacyFilterPipeline.applyOutboundDetailed(
            messages: [ChatMessage(role: "user", content: "Call \(Self.phone)")],
            sessionId: scope,
            providerId: UUID(),
            requestSource: .chatUI
        )
        #expect(presentations == 0)
        #expect(result.filterApplied == false)
        #expect(result.messages.first?.content?.contains(Self.phone) == true)
        // Replies may still echo the earlier placeholder.
        let map = try #require(result.map)
        #expect(await map.resolve(token: "[EMAIL_1]") == "alice@example.com")
    }

    @Test func categoryAnswers_skipTheSheet() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-category")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())
        let scope = Self.scope()
        await SessionRedactionStore.shared.setCategoryDecision(scope, .phone, .alwaysRedact)
        await SessionRedactionStore.shared.setCategoryDecision(scope, .email, .neverRedact)
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { _ in presentations += 1 }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: [ChatMessage(role: "user", content: "Call \(Self.phone) or mail alice@example.com")],
            sessionId: scope,
            providerId: UUID(),
            requestSource: .chatUI
        )
        #expect(presentations == 0)
        let content = scrubbed.first?.content ?? ""
        #expect(!content.contains(Self.phone))
        #expect(content.contains("alice@example.com"))
    }

    // MARK: - Never Redact

    @Test func neverRedact_skipsDetectionAndLeakCheck() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-never")
        defer { guard_.release() }
        PrivacyFilterStore.save(
            Self.config {
                $0.neverRedact = [
                    NeverRedactEntry(kind: .value, text: Self.phone),
                    NeverRedactEntry(kind: .domain, text: "example.com"),
                ]
            })

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { _ in presentations += 1 }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: [ChatMessage(role: "user", content: "Call \(Self.phone), read \(Self.feed)")],
            sessionId: Self.scope(),
            providerId: UUID(),
            requestSource: .chatUI
        )
        #expect(presentations == 0)
        #expect(scrubbed.first?.content == "Call \(Self.phone), read \(Self.feed)")
    }

    // MARK: - Shared scope

    @Test func subagent_sharesRootConversationMap() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-scope")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())
        let root = Self.scope()
        await SessionRedactionStore.shared.setPolicy(root, .autoRedact)
        defer { Task { await SessionRedactionStore.shared.invalidate(root) } }

        let (scrubbed, _) = try await ChatExecutionContext.$privacyScopeId.withValue(root) {
            try await PrivacyFilterPipeline.applyOutbound(
                messages: [ChatMessage(role: "user", content: "Call \(Self.phone)")],
                sessionId: "subagent-\(UUID().uuidString)",
                providerId: UUID(),
                requestSource: .chatUI
            )
        }
        #expect(scrubbed.first?.content?.contains("[PHONE_1]") == true)
        let map = try #require(await SessionRedactionStore.shared.get(root))
        #expect(await map.resolve(token: "[PHONE_1]") == Self.phone)
    }

    /// Two passes in one conversation find the same value at once. The
    /// scope lock runs them one after the other, so the second sees the
    /// first one's approval and never opens a second sheet.
    @Test func concurrentPasses_reviewSharedValueOnce() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-concurrent")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())
        let scope = Self.scope()
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }

        var presentations = 0
        let token = PrivacyReviewService.shared.registerPresenter { state in
            presentations += 1
            state.confirm()
        }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let messages = [ChatMessage(role: "user", content: "Call \(Self.phone)")]
        async let first = PrivacyFilterPipeline.applyOutbound(
            messages: messages, sessionId: scope, providerId: UUID(), requestSource: .chatUI)
        async let second = PrivacyFilterPipeline.applyOutbound(
            messages: messages, sessionId: scope, providerId: UUID(), requestSource: .chatUI)
        let results = try await [first, second]

        #expect(presentations == 1)
        for result in results {
            #expect(result.messages.first?.content?.contains("[PHONE_1]") == true)
        }
    }

    // MARK: - History the map has not seen

    /// A reopened chat (relaunch, reload, evicted map) has history the
    /// conversation's map never scanned. Those values go out again with
    /// the next message, so they are reviewed with it.
    @Test func unseenHistory_isReviewedWithTheNextMessage() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-history")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())
        let scope = Self.scope()
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }

        var seen: [String] = []
        let token = PrivacyReviewService.shared.registerPresenter { state in
            seen = state.entities.map(\.original)
            state.confirm()
        }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: [
                ChatMessage(role: "user", content: "Mail alice@example.com"),
                ChatMessage(role: "assistant", content: "Sent to alice@example.com."),
                ChatMessage(role: "user", content: "Now call \(Self.phone)"),
            ],
            sessionId: scope,
            providerId: UUID(),
            requestSource: .chatUI
        )
        #expect(Set(seen) == ["alice@example.com", Self.phone])
        let text = Self.allText(scrubbed)
        #expect(!text.contains("alice@example.com"))
        #expect(!text.contains(Self.phone))
    }

    @Test func forget_reviewsEarlierHistoryAgain() async throws {
        let guard_ = await acquirePrivacyStoreSandbox("PrivacyConversationPolicy-forget")
        defer { guard_.release() }
        PrivacyFilterStore.save(Self.config())
        let scope = Self.scope()
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }

        var presentations: [[String]] = []
        let token = PrivacyReviewService.shared.registerPresenter { state in
            presentations.append(state.entities.map(\.original))
            state.confirm()
        }
        defer { PrivacyReviewService.shared.unregisterPresenter(token) }

        let first = [ChatMessage(role: "user", content: "Mail alice@example.com")]
        _ = try await PrivacyFilterPipeline.applyOutbound(
            messages: first, sessionId: scope, providerId: UUID(), requestSource: .chatUI)
        let followUp = first + [
            ChatMessage(role: "assistant", content: "Done."),
            ChatMessage(role: "user", content: "Thanks"),
        ]
        _ = try await PrivacyFilterPipeline.applyOutbound(
            messages: followUp, sessionId: scope, providerId: UUID(), requestSource: .chatUI)
        #expect(presentations == [["alice@example.com"]], "scanned history is not asked about twice")

        await SessionRedactionStore.shared.forget(scope)
        let (scrubbed, _) = try await PrivacyFilterPipeline.applyOutbound(
            messages: followUp, sessionId: scope, providerId: UUID(), requestSource: .chatUI)
        #expect(presentations == [["alice@example.com"], ["alice@example.com"]])
        #expect(!Self.allText(scrubbed).contains("alice@example.com"))
    }

    // MARK: - Review state

    @Test func reviewState_cancelDiscardsAndSendCommitsChoices() async throws {
        let scope = Self.scope()
        defer { Task { await SessionRedactionStore.shared.invalidate(scope) } }
        let text = "Call \(Self.phone)"
        let entity = DetectedEntity(
            category: .phone,
            original: Self.phone,
            range: text.range(of: Self.phone)!,
            placeholder: Placeholder(category: .phone, index: 1),
            containingText: text
        )

        let canceled = RedactionReviewState(detections: [entity], sessionId: scope)
        canceled.onResolve = { _ in }
        canceled.setPolicy(.off)
        #expect(canceled.approvedCount == 0)
        canceled.cancel()
        #expect(await SessionRedactionStore.shared.explicitPolicy(scope) == nil)

        let sent = RedactionReviewState(detections: [entity], sessionId: scope)
        var outcome: PrivacyReviewOutcome?
        sent.onResolve = { outcome = $0 }
        sent.setCategoryAnswer(.phone, .alwaysRedact)
        sent.setPolicy(.autoRedact)
        sent.confirm()
        for _ in 0 ..< 50 where outcome == nil { await Task.yield() }

        #expect(outcome != nil)
        #expect(await SessionRedactionStore.shared.explicitPolicy(scope) == .autoRedact)
        #expect(await SessionRedactionStore.shared.categoryDecision(scope, .phone) == .alwaysRedact)
    }

    @Test func reviewState_neverRedactUnapprovesMatchingRows() {
        let text = "Read \(Self.feed) and https://example.com/about"
        let entities = [Self.feed, "https://example.com/about"].enumerated().map { index, url in
            DetectedEntity(
                category: .url,
                original: url,
                range: text.range(of: url)!,
                placeholder: Placeholder(category: .url, index: index + 1),
                containingText: text
            )
        }
        let state = RedactionReviewState(detections: entities, sessionId: "never-\(UUID().uuidString)")
        state.addNeverRedact(.domain, for: entities[0])
        #expect(state.neverRedactEntry(for: entities[0])?.text == "feeds.example.com")
        #expect(state.entities.first?.approved == false)
        #expect(state.entities.last?.approved == true, "feeds.example.com does not cover example.com")

        state.removeNeverRedact(for: entities[0])
        #expect(state.neverRedactEntry(for: entities[0]) == nil)
        #expect(state.entities.first?.approved == true)
    }
}
