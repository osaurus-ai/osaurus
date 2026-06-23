//
//  AppRecipeTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR3 coverage for per-app recipes: matcher resolution (universal + named),
//  the merged `RecipeSignals`, and — the point of the feature — that those
//  signals refine `EffectClassifier` so app-specific prompts ("Leave Site",
//  "Don't Save", "Clear browsing data") escalate to `consequential` where the
//  app-agnostic vocabulary alone would let them through as a plain navigate.
//

import Foundation
import XCTest

@testable import OsaurusCore

// MARK: - Matching + signal merge

final class AppRecipeTests: XCTestCase {
    func testUniversalDialogAppliesEverywhere() {
        XCTAssertTrue(AppRecipes.matching(app: "Notes").contains { $0.id == "dialog" })
        XCTAssertTrue(AppRecipes.matching(app: nil).contains { $0.id == "dialog" })
        // A named recipe never applies to an unrelated app.
        XCTAssertFalse(AppRecipes.matching(app: "Notes").contains { $0.id == "safari" })
    }

    func testNamedRecipeMatchesByNameFragment() {
        let safari = AppRecipes.matching(app: "Safari").map(\.id)
        XCTAssertEqual(Set(safari), ["dialog", "safari"])

        let chrome = AppRecipes.matching(app: "Google Chrome").map(\.id)
        XCTAssertEqual(Set(chrome), ["dialog", "chromium"])
    }

    func testSignalsMergeUniversalAndNamed() {
        let safari = AppRecipes.signals(for: "Safari")
        XCTAssertTrue(safari.consequential.contains("leave site"))  // safari
        XCTAssertTrue(safari.consequential.contains("don't save"))  // dialog (universal)

        let chrome = AppRecipes.signals(for: "Google Chrome")
        XCTAssertTrue(chrome.consequential.contains("clear browsing data"))

        // No app ⇒ only the universal dialog signals.
        let none = AppRecipes.signals(for: nil)
        XCTAssertTrue(none.consequential.contains("discard"))
        XCTAssertFalse(none.consequential.contains("leave site"))
    }

    func testFlowsExposeForMatchedApps() {
        XCTAssertFalse(AppRecipes.flows(for: "Safari").isEmpty)
    }

    func testGuidanceTextRendersFlowsForApp() {
        guard let safari = AppRecipes.guidanceText(for: "Safari") else {
            return XCTFail("expected guidance text for Safari")
        }
        XCTAssertTrue(safari.hasPrefix("Hints for Safari:"))
        XCTAssertTrue(safari.contains("Navigate to a URL"))
        XCTAssertTrue(safari.lowercased().contains("address bar"))
        // Steps are joined into an ordered hint with arrows.
        XCTAssertTrue(safari.contains("->"))
    }

    func testGuidanceTextFallsBackToUniversalDialog() {
        // Even an app with no named recipe matches the universal dialog (which
        // carries a flow), so guidance is still produced.
        guard let text = AppRecipes.guidanceText(for: nil) else {
            return XCTFail("expected universal dialog guidance")
        }
        XCTAssertTrue(text.contains("Save dialog"))
    }
}

// MARK: - Recipe-refined classification

final class RecipeClassifierTests: XCTestCase {
    private func click(_ describe: String) -> AgentAction {
        AgentAction(verb: .click, target: AgentTarget(describe: describe))
    }

    func testSafariLeaveSiteNeedsRecipeToEscalate() {
        let action = click("Leave Site")
        // App-agnostic vocabulary doesn't know "Leave Site" — stays navigate.
        XCTAssertEqual(
            EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Leave Site",
                appName: "Safari"
            ),
            .navigate
        )
        // With the Safari recipe merged in, it escalates.
        XCTAssertEqual(
            EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Leave Site",
                appName: "Safari",
                recipeSignals: AppRecipes.signals(for: "Safari")
            ),
            .consequential
        )
    }

    func testDialogDontSaveEscalatesViaUniversalRecipe() {
        let action = click("Don't Save")
        // App-agnostic vocabulary now treats the bare commit token ("save") as
        // an `edit` (so it confirms under balanced rather than auto-running),
        // but it does NOT know "Don't Save" discards work — that stays edit.
        XCTAssertEqual(
            EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Don't Save",
                appName: "Notes"
            ),
            .edit
        )
        // The universal dialog recipe is what recognizes "Don't Save" as a
        // discard and escalates it the rest of the way to consequential.
        XCTAssertEqual(
            EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Don't Save",
                appName: "Notes",
                recipeSignals: AppRecipes.signals(for: "Notes")
            ),
            .consequential
        )
    }

    func testChromeClearBrowsingDataEscalatesWithRecipe() {
        let action = click("Clear browsing data")
        XCTAssertEqual(
            EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Clear browsing data",
                appName: "Google Chrome",
                recipeSignals: AppRecipes.signals(for: "Google Chrome")
            ),
            .consequential
        )
    }

    func testRecipeStillCannotLowerBaseline() {
        // A benign edit in Safari stays at least edit even with recipe signals.
        let action = AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "hello")
        let effect = EffectClassifier.classify(
            action: action,
            resolvedRole: "AXTextField",
            resolvedLabel: "Address",
            appName: "Safari",
            recipeSignals: AppRecipes.signals(for: "Safari")
        )
        XCTAssertGreaterThanOrEqual(effect, .edit)
    }
}
