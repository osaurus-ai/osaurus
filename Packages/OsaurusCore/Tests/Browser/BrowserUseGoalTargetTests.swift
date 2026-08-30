//
//  BrowserUseGoalTargetTests.swift
//  OsaurusCoreTests — Native Browser Use
//
//  Pin `BrowserUseTool.unresolvedPageReference` — the guard that stops a goal
//  pointing at "this page" from being resolved against whatever the
//  PERSISTENT per-agent browser session happens to be parked on.
//
//  osaurus#2439: asked to scrape four `psappdeploytoolkit.com` doc URLs, the
//  model called `browser_use(goal: "Read the full content of this page and
//  output all the HTML/text content …")`. The session was still on an
//  unrelated repo from an earlier task, so the subagent read a GitHub 404 and
//  returned it as the answer. The parent agent had no way to notice, spent
//  the next several hours "scraping", and produced nothing.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct BrowserUseGoalTargetTests {

    /// The exact goal from the failing session, plus its close variants.
    @Test func deicticGoalWithNoTargetIsRejected() {
        let goals = [
            "Read the full content of this page and output all the HTML/text content, "
                + "especially the headings, code blocks, and configuration examples.",
            "Summarize the current page.",
            "Extract every link from the page above.",
            "Copy the text of this url.",
            "List the navigation items on this website.",
        ]
        for goal in goals {
            #expect(
                BrowserUseTool.unresolvedPageReference(in: goal) != nil,
                "goal names no target and must be rejected: \(goal)"
            )
        }
    }

    /// An explicit target makes the goal self-contained. It must pass even
    /// when it ALSO says "this page" — the reference resolves against the
    /// target the goal just named, not against session state.
    @Test func explicitTargetSuppressesTheCheck() {
        let goals = [
            "On https://psappdeploytoolkit.com/docs/4.1.x/introduction, read the full page text.",
            "Go to http://example.com and summarize this page.",
            "On github.com, list my open pull requests and which have failing checks.",
            "Open www.example.co.uk and read the current page.",
            "Visit docs.psappdeploytoolkit.com/usage and extract the code blocks.",
        ]
        for goal in goals {
            #expect(
                BrowserUseTool.unresolvedPageReference(in: goal) == nil,
                "goal carries an explicit target and must pass: \(goal)"
            )
        }
    }

    /// Continuing an already-established session is legitimate — the guard
    /// must not reject goals that describe actions without standing in for
    /// the target itself.
    @Test func ordinaryGoalsWithoutDeicticReferencesPass() {
        let goals = [
            "Search for \"PSAppDeployToolkit\" and open the first result.",
            "Log in and download the latest invoice.",
            "Click the next button, then read the results table.",
            "Find the pricing information, e.g. the monthly tier.",
        ]
        for goal in goals {
            #expect(
                BrowserUseTool.unresolvedPageReference(in: goal) == nil,
                "goal must not be rejected: \(goal)"
            )
        }
    }

    /// The rejection has to name the offending phrase so the model can fix
    /// the specific words rather than guessing at the schema.
    @Test func rejectionNamesTheOffendingPhrase() {
        #expect(BrowserUseTool.unresolvedPageReference(in: "Read this page.") == "this page")
        #expect(
            BrowserUseTool.unresolvedPageReference(in: "Summarize the current page.")
                == "the current page"
        )
    }

    /// The check is case-insensitive; models capitalize sentence-initially.
    @Test func matchIsCaseInsensitive() {
        #expect(BrowserUseTool.unresolvedPageReference(in: "This Page, please.") != nil)
    }
}
