//
//  AppleScriptRecipes.swift
//  OsaurusCore — AppleScript Computer Use
//
//  Per-app AppleScript idioms and gotchas, analogous to Computer Use's
//  `AppRecipe`. Each recipe is a handful of known-good vocabulary lines for one
//  app — the forms that models most often get ALMOST right (Safari's `URL of
//  front document`, Notes find-or-create, Music's `current track`). Injected
//  into the loop prompt for the app(s) a task targets so the model anchors on
//  real idioms instead of inventing plausible-looking ones.
//
//  Pure data + matching; no execution behavior. Kept deliberately short per
//  app: these are anchors, not documentation.
//

import Foundation

/// One app's AppleScript idiom sheet.
public struct AppleScriptRecipe: Sendable, Equatable {
    /// App names this recipe applies to (case-insensitive exact match on the
    /// localized app name, e.g. "Safari").
    public let appNames: [String]
    /// Short idiom / gotcha lines, each a single anchoring fact or snippet.
    public let tips: [String]

    public init(appNames: [String], tips: [String]) {
        self.appNames = appNames
        self.tips = tips
    }

    public func matches(app: String) -> Bool {
        appNames.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }
}

/// The curated catalog. Seeded with the apps the subagent most commonly
/// automates; extend one entry at a time as live evals expose new gotchas.
public enum AppleScriptRecipeCatalog {

    public static let recipes: [AppleScriptRecipe] = [
        AppleScriptRecipe(
            appNames: ["Safari"],
            tips: [
                "Front page URL/title: `tell application \"Safari\" to get URL of front document` (also `name of front document`).",
                "Open a URL: `tell application \"Safari\" to open location \"https://…\"`.",
                "Tabs live on windows: `URL of every tab of window 1`; current tab is `current tab of window 1`.",
                "Page text/JS needs \"Allow JavaScript from Apple Events\" (Develop menu) — prefer URL/title reads.",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["Notes"],
            tips: [
                "Find-or-create: `if not (exists note \"Name\") then make new note with properties {name:\"Name\", body:\"…\"}` inside `tell application \"Notes\"` (target `folder \"Notes\"` for the default folder).",
                "A note's `body` is HTML; its first line becomes the `name`. Set `body` to replace content.",
                "Read a note: `get body of note \"Name\"` (raises an error when it doesn't exist — check `exists` first).",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["Music"],
            tips: [
                "Now playing: `tell application \"Music\" to get name of current track` (artist: `artist of current track`). Errors when nothing is playing — guard with `if player state is playing`.",
                "Control: `play`, `pause`, `next track`, `previous track`. Volume: `set sound volume to 50` (0–100, app-local).",
                "Play a playlist: `play playlist \"Name\"`.",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["Mail"],
            tips: [
                "Unread count: `tell application \"Mail\" to get unread count of inbox`.",
                "Recent subjects: `get subject of messages 1 thru 5 of inbox` (message 1 is newest).",
                "Compose (draft, do NOT send unless asked): `make new outgoing message with properties {subject:…, content:…, visible:true}`; add `make new to recipient at end of to recipients of it with properties {address:\"…\"}`.",
                "`send` is a consequential action — only include it when the task explicitly says to send.",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["Finder"],
            tips: [
                "Selected files: `tell application \"Finder\" to get selection` (returns Finder items; coerce with `as alias list`).",
                "Paths: Finder speaks colon-separated HFS paths; use `POSIX path of (item as alias)` to convert, and `POSIX file \"/slash/path\"` going in.",
                "New folder: `make new folder at desktop with properties {name:\"…\"}`.",
                "`delete` moves to Trash (still a destructive action — the gate confirms it).",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["Calendar"],
            tips: [
                "Calendars are looked up by name: `tell application \"Calendar\" to tell calendar \"Home\" …`.",
                "New event: `make new event with properties {summary:\"…\", start date:d1, end date:d2}` — build dates with `set d1 to (current date)` then set its `hours`/`minutes`.",
                "Reading `every event` of a large calendar is slow; filter with `whose start date > …` when possible.",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["Reminders"],
            tips: [
                "New reminder: `tell application \"Reminders\" to tell list \"Reminders\" to make new reminder with properties {name:\"…\", due date:d}`.",
                "Incomplete items: `get name of reminders whose completed is false`.",
                "Complete one: `set completed of reminder \"Name\" to true`.",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["System Events"],
            tips: [
                "System Events is for UI scripting and system state — target a PROCESS, not an app: `tell application \"System Events\" to tell process \"AppName\" …`.",
                "UI scripting (keystroke, click, menu bar) requires the user's Accessibility permission and the target app frontmost (`set frontmost to true`).",
                "Menu example: `click menu item \"Save\" of menu \"File\" of menu bar 1`.",
                "Frontmost app name: `get name of first process whose frontmost is true`.",
            ]
        ),
        AppleScriptRecipe(
            // "Shortcut" (singular) is included so a task phrased "run my …
            // shortcut" matches — target detection is word-boundary exact.
            appNames: ["Shortcuts", "Shortcuts Events", "Shortcut"],
            tips: [
                "Run a user shortcut WITHOUT opening the app: `tell application \"Shortcuts Events\" to run shortcut \"Name\"` (optionally `with input \"…\"`); the result is the shortcut's output.",
                "List available shortcuts: `tell application \"Shortcuts Events\" to get name of every shortcut`.",
                "Use the exact shortcut name — check the list first if a run errors with \"can't get shortcut\".",
                "A shortcut can do anything the user built it to do — treat running one as a consequential action.",
            ]
        ),
        AppleScriptRecipe(
            appNames: ["Terminal"],
            tips: [
                "Run a command in a window: `tell application \"Terminal\" to do script \"cmd\"` (opens a new window; use `in window 1` to reuse).",
                "For a command whose OUTPUT you need, prefer plain `do shell script \"cmd\"` — no Terminal window involved.",
            ]
        ),
    ]

    /// The recipes matching an app name (usually zero or one).
    public static func recipes(for app: String) -> [AppleScriptRecipe] {
        recipes.filter { $0.matches(app: app) }
    }

    /// Every app name the catalog knows (used by target-app detection).
    public static var knownAppNames: [String] {
        recipes.flatMap(\.appNames)
    }
}
