//
//  OsaurusShortcuts.swift
//  osaurus
//
//  Declares the App Shortcuts so Osaurus's intents appear in Shortcuts,
//  Spotlight, and Siri without the user assembling them by hand.
//

import AppIntents

struct OsaurusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Note: App Shortcut phrases may only interpolate AppEntity / AppEnum
        // parameters, never a plain `String` like `prompt`, so the prompt is
        // supplied through the intent parameter rather than inline in a phrase.
        AppShortcut(
            intent: AskOsaurusIntent(),
            phrases: [
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask Osaurus",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: RunAgentIntent(),
            phrases: [
                "Run \(\.$agent) in \(.applicationName)",
                "Run an \(.applicationName) agent",
            ],
            shortTitle: "Run Agent",
            systemImageName: "play.circle"
        )
    }
}
