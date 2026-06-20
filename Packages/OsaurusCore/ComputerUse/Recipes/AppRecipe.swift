//
//  AppRecipe.swift
//  OsaurusCore — Computer Use
//
//  Per-app refinements (PR3), modeled on the driver REFERENCE.md numbered
//  sequences. A recipe carries two things:
//
//    1. Extra effect signals — app-specific words that should push the
//       classifier toward `consequential` (e.g. a browser "Leave site" /
//       "Resend" prompt, a dialog "Don't Save" / "Discard"). These merge into
//       `EffectClassifier` so the gate is context-aware per app.
//    2. Flows — human-readable ordered hint sequences for common tasks, kept
//       as data so they can seed prompts or docs without hard-coding logic.
//
//  Matching is by normalized app-name / bundle-id fragment. A recipe with no
//  matchers is "universal" (applies to every app) — used for the dialog
//  recipe, since modal dialogs aren't their own app.
//

import Foundation

/// An ordered task hint, mirroring the driver's numbered REFERENCE.md flows.
public struct RecipeFlow: Sendable, Equatable {
    public let name: String
    public let steps: [String]

    public init(name: String, steps: [String]) {
        self.name = name
        self.steps = steps
    }
}

/// A per-app (or universal) refinement bundle.
public struct AppRecipe: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// Normalized app-name / bundle-id fragments this recipe matches. Empty =
    /// universal.
    public let matchers: [String]
    /// App-specific words that escalate an action to `consequential`.
    public let consequentialSignals: [String]
    /// App-specific commit-control words (escalate only with recipients).
    public let commitSignals: [String]
    /// Ordered task hints.
    public let flows: [RecipeFlow]

    public init(
        id: String,
        displayName: String,
        matchers: [String],
        consequentialSignals: [String] = [],
        commitSignals: [String] = [],
        flows: [RecipeFlow] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.matchers = matchers
        self.consequentialSignals = consequentialSignals
        self.commitSignals = commitSignals
        self.flows = flows
    }

    /// Whether this recipe applies to `app`. Universal recipes (no matchers)
    /// always apply; otherwise an app matches if its normalized name contains
    /// any matcher fragment.
    public func matches(app: String?) -> Bool {
        if matchers.isEmpty { return true }
        guard let app else { return false }
        let n = AutonomyPolicy.normalize(app)
        return matchers.contains { n.contains($0) }
    }
}

/// Merged signal sets handed to the classifier for the current app.
public struct RecipeSignals: Sendable, Equatable {
    public let consequential: Set<String>
    public let commit: Set<String>

    public init(consequential: Set<String>, commit: Set<String>) {
        self.consequential = consequential
        self.commit = commit
    }

    public static let empty = RecipeSignals(consequential: [], commit: [])
}

// MARK: - Seed registry

public enum AppRecipes {
    /// All shipped recipes. Universal ones first so callers can rely on order.
    public static let all: [AppRecipe] = [dialog, safari, chromium]

    /// Recipes that apply to `app` (universal + name-matched).
    public static func matching(app: String?) -> [AppRecipe] {
        all.filter { $0.matches(app: app) }
    }

    /// The merged extra signal sets for the current app.
    public static func signals(for app: String?) -> RecipeSignals {
        var consequential: Set<String> = []
        var commit: Set<String> = []
        for recipe in matching(app: app) {
            consequential.formUnion(recipe.consequentialSignals)
            commit.formUnion(recipe.commitSignals)
        }
        return RecipeSignals(consequential: consequential, commit: commit)
    }

    /// Flow hints for the current app.
    public static func flows(for app: String?) -> [RecipeFlow] {
        matching(app: app).flatMap { $0.flows }
    }

    /// A compact, model-facing rendering of the current app's flow hints, or
    /// `nil` when no recipe matches. Injected once per app by `ComputerUseLoop`
    /// so the model gets the proven numbered sequence (e.g. the address-bar flow)
    /// instead of rediscovering it. Bounded to the first few flows to stay cheap.
    public static func guidanceText(for app: String?, maxFlows: Int = 3) -> String? {
        let flowList = flows(for: app)
        guard !flowList.isEmpty else { return nil }
        let appLabel = (app?.isEmpty == false) ? app! : "this app"
        var lines = ["Hints for \(appLabel):"]
        for flow in flowList.prefix(max(1, maxFlows)) {
            lines.append("- \(flow.name): " + flow.steps.joined(separator: " -> "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Seeds

    /// Universal modal-dialog refinement. Modal sheets ("Don't Save", "Discard",
    /// "Replace") commit or destroy work and are easy to mis-rank as a plain
    /// navigate click, so they escalate everywhere.
    static let dialog = AppRecipe(
        id: "dialog",
        displayName: "Dialogs & sheets",
        matchers: [],
        consequentialSignals: [
            "don't save", "dont save", "discard", "replace", "overwrite",
            "move to trash", "delete", "remove", "erase", "reset", "revert",
        ],
        flows: [
            RecipeFlow(
                name: "Save dialog",
                steps: [
                    "Read the dialog buttons (Save / Don't Save / Cancel).",
                    "Pick the button matching the user's intent; Don't Save discards work.",
                    "Confirm the dialog closed via the verify delta.",
                ]
            )
        ]
    )

    /// Safari refinement: destructive history/site prompts + the address-bar flow.
    static let safari = AppRecipe(
        id: "safari",
        displayName: "Safari",
        matchers: ["safari"],
        consequentialSignals: [
            "leave page", "leave site", "resend", "clear history", "remove",
            "close all tabs", "empty cache",
        ],
        flows: [
            RecipeFlow(
                name: "Navigate to a URL",
                steps: [
                    "Focus the address bar (click it or press cmd+l).",
                    "Type the URL.",
                    "Press return to load it.",
                    "Wait for the new view, then verify the page title changed.",
                ]
            )
        ]
    )

    /// Chromium-family refinement (Chrome / Edge / Brave / Arc): the same
    /// destructive prompts under different wording.
    static let chromium = AppRecipe(
        id: "chromium",
        displayName: "Chromium browsers",
        matchers: ["chrome", "chromium", "edge", "brave", "arc", "vivaldi", "opera"],
        consequentialSignals: [
            "leave site", "reload site", "resend", "clear browsing data", "remove",
            "close all", "delete data",
        ],
        flows: [
            RecipeFlow(
                name: "Navigate to a URL",
                steps: [
                    "Focus the omnibox (click it or press cmd+l).",
                    "Type the URL.",
                    "Press return to load it.",
                    "Verify the tab title or page heading changed.",
                ]
            )
        ]
    )
}
