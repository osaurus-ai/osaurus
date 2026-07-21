//
//  BrowserUseEvalTests.swift
//  OsaurusEvalsKitTests
//
//  Deterministic, MODEL-FREE coverage for the `browser_use` eval lane's
//  fixture substrate. The live lane needs a child model to plan the tool
//  calls, so what CI pins here is the part a model failure must never be
//  confused with: the `FixtureBrowserWorld` contract itself — navigation
//  matching, the structured LOGIN_REQUIRED wall, per-page ref regeneration
//  (stale refs), read_page pagination, batch abort semantics, and the
//  world-state read-back the case scoring depends on. Plus a decode guard
//  over the committed `Suites/BrowserUse` files.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct BrowserUseEvalTests {

    private typealias Page = EvalCase.BrowserFixturePage
    private typealias Element = EvalCase.BrowserFixtureElement

    // MARK: - Envelope helpers

    private func parse(_ envelope: String) -> [String: Any] {
        guard let data = envelope.data(using: .utf8),
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return dict
    }

    private func text(_ envelope: String) -> String {
        let payload = ToolEnvelope.successPayload(envelope)
        if let dict = payload as? [String: Any], let text = dict["text"] as? String {
            return text
        }
        return ""
    }

    // MARK: - Fixture worlds

    /// The contact-form world from `browseruse.form-fill`, inline so the test
    /// doesn't depend on the suite file's exact shape.
    private func contactWorld() -> FixtureBrowserWorld {
        FixtureBrowserWorld(pages: [
            Page(
                url: "https://fixtures.local/contact",
                title: "Contact Us",
                bodyText: "Contact us. Fill in your name and email, then press Send.",
                elements: [
                    Element(id: "name", type: "input", text: "Name", placeholder: "Your name"),
                    Element(id: "email", type: "input", text: "Email", placeholder: "you@example.com"),
                    Element(
                        id: "send", type: "button", text: "Send",
                        goto: "https://fixtures.local/thanks"),
                ]),
            Page(
                url: "https://fixtures.local/thanks",
                title: "Thank You",
                bodyText: "Thanks! Your message has been sent.",
                elements: []),
        ])
    }

    // MARK: - Navigation

    @Test func navigateServesFixturePagesAndFailsTypedOnUnknownURLs() async {
        let world = contactWorld()

        let ok = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/contact"}"#)
        #expect(ToolEnvelope.isSuccess(ok))
        #expect(text(ok).contains("Contact Us"))

        let missing = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/nowhere"}"#)
        #expect(ToolEnvelope.isError(missing))
        #expect(parse(missing)["kind"] as? String == "execution_error")

        // Determinism: the failed navigate must not have changed the page.
        let snap = await world.execute(name: "browser_snapshot", argumentsJSON: "{}")
        #expect(text(snap).contains("Contact Us"))
    }

    @Test func formFillFlowMutatesWorldStateForScoring() async {
        let world = contactWorld()
        _ = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/contact"}"#)

        // Refs are assigned in element order: E1=name, E2=email, E3=send.
        let typed = await world.execute(
            name: "browser_type",
            argumentsJSON: #"{"ref": "E1", "text": "Ada Lovelace"}"#)
        #expect(ToolEnvelope.isSuccess(typed))
        _ = await world.execute(
            name: "browser_type",
            argumentsJSON: #"{"ref": "E2", "text": "ada@example.com"}"#)
        let clicked = await world.execute(
            name: "browser_click", argumentsJSON: #"{"ref": "E3"}"#)
        #expect(ToolEnvelope.isSuccess(clicked))
        #expect(text(clicked).contains("Thank You"), "clicking Send must land on the thanks page")

        // The read-back surface the case scoring uses.
        let values = await world.finalValues()
        #expect(values["name"] == "Ada Lovelace")
        #expect(values["email"] == "ada@example.com")
        #expect(await world.wasClicked("send"))
        #expect(!(await world.wasClicked("name")))
        let verbs = await world.verbTrace()
        #expect(verbs == ["navigate", "type", "type", "click"])
    }

    // MARK: - Login wall

    @Test func loginWallReturnsStructuredFailureUntilOpenLogin() async {
        let world = FixtureBrowserWorld(pages: [
            Page(
                url: "https://fixtures.local/dashboard",
                title: "Dashboard",
                bodyText: "Account balance: $1,234.56.",
                loginRequired: true,
                elements: [])
        ])

        let walled = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/dashboard"}"#)
        #expect(ToolEnvelope.isError(walled))
        let dict = parse(walled)
        #expect(dict["kind"] as? String == "unavailable")
        #expect(dict["code"] as? String == "LOGIN_REQUIRED")
        #expect((dict["hint"] as? String)?.contains("browser_open_login") == true)

        _ = await world.execute(
            name: "browser_open_login",
            argumentsJSON: #"{"url": "https://fixtures.local/dashboard"}"#)
        let after = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/dashboard"}"#)
        #expect(ToolEnvelope.isSuccess(after), "post-login navigation must succeed")
        #expect(await world.verbTrace() == ["navigate", "open_login", "navigate"])
    }

    // MARK: - Stale refs

    @Test func refsFromAPreviousPageAreStale() async {
        let world = FixtureBrowserWorld(pages: [
            Page(
                url: "https://fixtures.local/wizard",
                title: "Step 1",
                elements: [
                    Element(
                        id: "continue", type: "button", text: "Continue",
                        goto: "https://fixtures.local/wizard/step2")
                ]),
            Page(
                url: "https://fixtures.local/wizard/step2",
                title: "Step 2",
                elements: [
                    Element(id: "color", type: "input", text: "Favorite color")
                ]),
        ])
        _ = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/wizard"}"#)

        // E1 = continue (page 1). Clicking navigates; refs regenerate (E2 = color).
        let clicked = await world.execute(
            name: "browser_click", argumentsJSON: #"{"ref": "E1"}"#)
        #expect(text(clicked).contains("Step 2"))

        let stale = await world.execute(
            name: "browser_type", argumentsJSON: #"{"ref": "E1", "text": "blue"}"#)
        #expect(ToolEnvelope.isError(stale))
        #expect(ToolEnvelope.failureMessage(stale).lowercased().contains("stale"))

        let fresh = await world.execute(
            name: "browser_type", argumentsJSON: #"{"ref": "E2", "text": "blue"}"#)
        #expect(ToolEnvelope.isSuccess(fresh))
        #expect(await world.finalValues()["color"] == "blue")
    }

    // MARK: - read_page pagination

    @Test func readPagePaginatesWithOffsetAndHasMore() async {
        let body = String(repeating: "abcdefghij", count: 200)  // 2000 chars
        let world = FixtureBrowserWorld(pages: [
            Page(url: "https://fixtures.local/article", title: "Article", bodyText: body)
        ])
        _ = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/article"}"#)

        let first = await world.execute(
            name: "browser_read_page", argumentsJSON: #"{"max_chars": 500}"#)
        let firstPayload = ToolEnvelope.successPayload(first) as? [String: Any] ?? [:]
        #expect((firstPayload["text"] as? String)?.count == 500)
        #expect(firstPayload["total_chars"] as? Int == 2000)
        #expect(firstPayload["has_more"] as? Bool == true)

        let last = await world.execute(
            name: "browser_read_page", argumentsJSON: #"{"offset": 1500, "max_chars": 500}"#)
        let lastPayload = ToolEnvelope.successPayload(last) as? [String: Any] ?? [:]
        #expect((lastPayload["text"] as? String)?.count == 500)
        #expect(lastPayload["has_more"] as? Bool == false)
    }

    // MARK: - browser_do batch semantics

    @Test func batchDoAbortsOnFirstFailureAndReportsIt() async {
        let world = contactWorld()
        _ = await world.execute(
            name: "browser_navigate",
            argumentsJSON: #"{"url": "https://fixtures.local/contact"}"#)

        // Second action targets a ref that doesn't exist — the batch must
        // surface THAT failure and not run the trailing click.
        let batch = await world.execute(
            name: "browser_do",
            argumentsJSON: #"""
                {"actions": [
                  {"action": "type", "ref": "E1", "text": "Ada"},
                  {"action": "type", "ref": "E99", "text": "nope"},
                  {"action": "click", "ref": "E3"}
                ]}
                """#)
        #expect(ToolEnvelope.isError(batch))
        #expect(await world.finalValues()["name"] == "Ada", "actions before the failure ran")
        #expect(!(await world.wasClicked("send")), "actions after the failure must not run")
    }

    // MARK: - Suite decode guard

    @Test func browserUseSuiteDecodesWithWellFormedCases() throws {
        let suiteDir =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites")
            .appendingPathComponent("BrowserUse")

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(
            suite.decodeFailures.isEmpty,
            "BrowserUse case JSON failed to decode: \(suite.decodeFailures)")
        #expect(suite.cases.count >= 4, "Expected the full BrowserUse suite; got \(suite.cases.count)")

        for testCase in suite.cases {
            let exp = testCase.expect.subagent
            #expect(exp?.lane == "browser_use", "\(testCase.id): lane must be browser_use")
            #expect(exp?.pages?.isEmpty == false, "\(testCase.id): fixture pages are required")
            // Every page the world can land on must be reachable from the
            // case's fixtures — a goto to a missing page would fail navigation.
            let urls = Set((exp?.pages ?? []).map(\.url))
            for page in exp?.pages ?? [] {
                for element in page.elements ?? [] {
                    if let goto = element.goto {
                        #expect(
                            urls.contains(goto),
                            "\(testCase.id): element '\(element.id)' goes to '\(goto)' which is not a fixture page")
                    }
                }
            }
        }
    }
}
