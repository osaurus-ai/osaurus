//
//  FirstRunEvalCoverageTests.swift
//  OsaurusCoreTests
//
//  Every walkthrough ask has a case in OsaurusEvals' FirstRun suite that
//  runs what the ask runs, so an ask added to OnboardingPaths cannot ship
//  without `make evals-firstrun` covering it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("FirstRun eval coverage")
@MainActor
struct FirstRunEvalCoverageTests {

    /// The typed first questions the suite must keep, besides the asks.
    static let typedQuestions = [
        "What's on my calendar today?",
        "What's due today?",
        "Any unread mail?",
    ]

    static func cases() throws -> [String: [String: Any]] {
        let suite = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OsaurusEvals/Suites/FirstRun", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: suite, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var byId: [String: [String: Any]] = [:]
        for url in urls {
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                "\(url.lastPathComponent)"
            )
            let id = try #require(object["id"] as? String, "\(url.lastPathComponent)")
            byId[id] = object
        }
        return byId
    }

    static func caseId(for ask: OnboardingAsk) -> String {
        "firstrun.ask-" + ask.id.replacingOccurrences(of: ".", with: "-")
    }

    @Test func everyAskHasACaseThatRunsWhatTheAskRuns() throws {
        let cases = try Self.cases()
        for ask in OnboardingPaths.all.flatMap(\.asks) {
            let id = Self.caseId(for: ask)
            guard let testCase = cases[id] else {
                Issue.record("\(ask.id) has no FirstRun case \(id)")
                continue
            }
            if let workflowId = ask.workflowId {
                #expect(testCase["domain"] as? String == "workflow", "\(id)")
                let workflow = (testCase["expect"] as? [String: Any])?["workflow"] as? [String: Any]
                let bundled = try #require(workflow?["bundled"] as? String, "\(id) names no bundled workflow")
                let template = try #require(TeamSeeder.loadBundled(bundled), "\(id): \(bundled)")
                #expect(template.id == workflowId, "\(id) runs \(bundled), not the ask's workflow")
                let input = workflow?["input"] as? [String: String] ?? [:]
                #expect(input == ask.input, "\(id) sends a different input than the ask")
            } else {
                #expect(testCase["domain"] as? String == "orchestrator", "\(id)")
                #expect(testCase["query"] as? String == ask.label, "\(id) sends a different message than the ask")
            }
        }
    }

    @Test func typedFirstQuestionsAreCovered() throws {
        let queries = try Self.cases().values.compactMap { $0["query"] as? String }
        for question in Self.typedQuestions {
            #expect(queries.contains(question), "no FirstRun case sends \"\(question)\"")
        }
    }

    @Test func noCaseOutlivesItsAsk() throws {
        let askIds = Set(OnboardingPaths.all.flatMap(\.asks).map(Self.caseId))
        for id in try Self.cases().keys where id.hasPrefix("firstrun.ask-") {
            #expect(askIds.contains(id), "\(id) covers an ask the walkthrough no longer has")
        }
    }
}
