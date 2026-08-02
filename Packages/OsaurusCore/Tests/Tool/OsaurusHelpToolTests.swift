//
//  OsaurusHelpToolTests.swift
//  OsaurusCoreTests
//
//  Pins the bundled Osaurus guide corpus and the `osaurus_help` read tool:
//
//   * The guide loads from `Resources/Guide/guide-*.md`, every topic has a
//     title/summary/body, and the core topic ids the prompt and quick
//     actions rely on all exist.
//   * `osaurus_help` serves the topic index and individual topic bodies,
//     fails typed on unknown topics (naming the known ids so the model can
//     self-correct), and is gated to the Default agent like the other
//     configure reads.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Guide corpus

struct OsaurusGuideTests {

    @Test
    func topics_loadFromBundleWithFrontMatter() {
        let topics = OsaurusGuide.topics
        #expect(!topics.isEmpty, "Guide corpus missing from OsaurusCore bundle")
        for topic in topics {
            #expect(!topic.id.isEmpty)
            #expect(!topic.title.isEmpty, "\(topic.id): missing title")
            #expect(!topic.summary.isEmpty, "\(topic.id): missing summary")
            #expect(!topic.body.isEmpty, "\(topic.id): missing body")
        }
        // Ids are unique.
        #expect(Set(topics.map { $0.id }).count == topics.count)
    }

    @Test
    func topics_coverTheCoreFeatureAreas() {
        let ids = Set(OsaurusGuide.topics.map { $0.id })
        // The prompt and onboarding rely on these existing. Adding topics is
        // free; renaming/removing one of these must be a deliberate review.
        for required in [
            "getting-started", "local-models", "cloud-providers", "agents",
            "chat", "skills", "plugins", "mcp", "schedules", "memory",
            "server-api", "settings", "voice", "themes", "channels",
            "automation", "privacy-storage", "troubleshooting",
            "commands", "images", "watchers", "agent-db", "knowledge",
            "identity",
        ] {
            #expect(ids.contains(required), "guide topic `\(required)` missing")
        }
    }

    @Test
    func topics_areSortedByOrderThenId() {
        let topics = OsaurusGuide.topics
        let resorted = topics.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        #expect(topics.map { $0.id } == resorted.map { $0.id })
        #expect(topics.first?.id == "getting-started")
    }

    @Test
    func topicLookup_isCaseAndPrefixTolerant() {
        #expect(OsaurusGuide.topic(id: "getting-started") != nil)
        #expect(OsaurusGuide.topic(id: "Getting-Started") != nil)
        #expect(OsaurusGuide.topic(id: "guide-getting-started") != nil)
        #expect(OsaurusGuide.topic(id: "getting-started.md") != nil)
        #expect(OsaurusGuide.topic(id: " getting-started ") != nil)
        #expect(OsaurusGuide.topic(id: "no-such-topic") == nil)
    }

    @Test
    func parseTopic_handlesFrontMatterAndMalformedInput() {
        let valid = """
            ---
            title: Test Topic
            summary: A one-liner.
            order: 42
            ---

            Body text here.
            """
        let parsed = OsaurusGuide.parseTopic(id: "test", contents: valid)
        #expect(parsed?.title == "Test Topic")
        #expect(parsed?.summary == "A one-liner.")
        #expect(parsed?.order == 42)
        #expect(parsed?.body == "Body text here.")

        // Missing front matter → dropped.
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "Just body text") == nil)
        // Unterminated front matter → dropped.
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "---\ntitle: T\nbody") == nil)
        // Missing title → dropped.
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "---\nsummary: s\n---\nbody") == nil)
        // Empty body → dropped.
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "---\ntitle: T\n---\n\n") == nil)
    }
}

// MARK: - osaurus_help tool

struct OsaurusHelpToolTests {

    private func parse(_ envelope: String) throws -> [String: Any] {
        let data = try #require(envelope.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func topics_returnsIndexWithSummaries() async throws {
        let tool = OsaurusHelpTool()
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: #"{"action": "topics"}"#)
        }
        let dict = try parse(envelope)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let topics = try #require(result["topics"] as? [[String: Any]])
        #expect(!topics.isEmpty)
        for row in topics {
            #expect(row["id"] as? String != nil)
            #expect(row["title"] as? String != nil)
            #expect(row["summary"] as? String != nil)
            // The index deliberately omits bodies — reads are per-topic.
            #expect(row["content"] == nil)
        }
    }

    @Test
    func read_returnsOneTopicBody() async throws {
        let tool = OsaurusHelpTool()
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: #"{"action": "read", "topic": "getting-started"}"#)
        }
        let dict = try parse(envelope)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["id"] as? String == "getting-started")
        let content = try #require(result["content"] as? String)
        #expect(content.contains("Osaurus"))
    }

    @Test
    func read_unknownTopicFailsTypedAndNamesKnownTopics() async throws {
        let tool = OsaurusHelpTool()
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: #"{"action": "read", "topic": "flux-capacitor"}"#)
        }
        let dict = try parse(envelope)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        let message = try #require(dict["message"] as? String)
        // The failure names the known topic ids so the model self-corrects
        // in one round-trip.
        #expect(message.contains("getting-started"))
    }

    @Test
    func read_missingTopicArgumentFailsTyped() async throws {
        let tool = OsaurusHelpTool()
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: #"{"action": "read"}"#)
        }
        let dict = try parse(envelope)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "topic")
    }

    @Test
    func execute_isGatedToTheDefaultAgent() async throws {
        let tool = OsaurusHelpTool()
        // Non-default agent → unavailable.
        let asCustom = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: #"{"action": "topics"}"#)
        }
        let customDict = try parse(asCustom)
        #expect(customDict["ok"] as? Bool == false)
        #expect(customDict["kind"] as? String == "unavailable")

        // No chat context at all → unavailable.
        let noContext = try await tool.execute(argumentsJSON: #"{"action": "topics"}"#)
        let noContextDict = try parse(noContext)
        #expect(noContextDict["ok"] as? Bool == false)
        #expect(noContextDict["kind"] as? String == "unavailable")
    }
}
