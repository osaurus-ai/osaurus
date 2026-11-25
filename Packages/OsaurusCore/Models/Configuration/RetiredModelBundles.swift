//
//  RetiredModelBundles.swift
//  OsaurusCore
//
//  Task-model bundles whose only consumer was removed. They can still sit in
//  the models directory, so they are kept out of the chat model picker (they
//  never emit normal chat replies) and labeled as retired in Local Models
//  until the user deletes them.
//

import Foundation

enum RetiredModelBundles {
    /// Repo-id prefixes of the dedicated AppleScript models. The AppleScript
    /// subagent was replaced by Computer Use.
    static let appleScriptRepoIdPrefixes = [
        "OsaurusAI/Osaurus-AppleScript-",
        "JANGQ-AI/AppleScript-",
    ]

    static func isRetired(id: String) -> Bool {
        appleScriptRepoIdPrefixes.contains {
            id.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    /// Already localized.
    static var badgeText: String { L("Retired") }

    /// Already localized.
    static var badgeHelp: String {
        L("AppleScript automation was replaced by Computer Use. Osaurus no longer uses this model; delete it to free disk space.")
    }
}
