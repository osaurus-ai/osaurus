//
//  WhatsNewModels.swift
//  osaurus
//
//  Data types and static release notes for the "What's New" modal.
//

import Foundation
import OsaurusRepository

/// Optional call-to-action a `WhatsNewPage` can carry. The host UI handles
/// each case as a deep link (open Settings on a specific tab, open a URL,
/// etc.) so the view stays purely declarative.
public enum WhatsNewAction: Hashable, Sendable {
    /// Open Settings → Sandbox.
    case openSandboxSettings
    /// Open Settings → Server (where API keys are listed).
    case openAPIKeysSettings
    /// Open an arbitrary documentation URL in the system browser.
    case openSecurityDoc(URL)
    /// Open Settings → Storage (encryption key + plaintext export).
    case openStorageSettings
    /// Trigger a one-shot plaintext export of conversation/memory data.
    case exportPlaintextBackup
}

public struct WhatsNewPage: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    /// If nil, the page shows a sparkling stars background instead of an image.
    public let imageURL: URL?
    /// When set, the modal renders a prominent button labelled `actionLabel`
    /// in the footer that invokes `action`. Use sparingly — most pages should
    /// be informational only.
    public let actionLabel: String?
    public let action: WhatsNewAction?

    public init(
        id: String,
        title: String,
        description: String,
        imageURL: URL? = nil,
        actionLabel: String? = nil,
        action: WhatsNewAction? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.imageURL = imageURL
        self.actionLabel = actionLabel
        self.action = action
    }
}

public struct WhatsNewRelease: Identifiable, Hashable, Sendable {
    public let version: String
    public let pages: [WhatsNewPage]

    public var id: String { version }

    public init(version: String, pages: [WhatsNewPage]) {
        self.version = version
        self.pages = pages
    }
}

public enum WhatsNewContent {
    /// Release notes keyed by app version. Add a `WhatsNewRelease` entry
    /// here whose `version` matches `CFBundleShortVersionString` for each
    /// release that should announce changes on first launch after update.
    public static let releases: [WhatsNewRelease] = [securityHardening_0_17_7]

    /// First-launch announcement for the #950 security audit fixes
    /// **plus** the at-rest encryption migration that ships alongside.
    /// Pages whose id ends in `:sandbox` or `:legacy-keys` are
    /// conditional — see
    /// `WhatsNewGate.filterPages(_:hasSandbox:hasLegacyPairedKeys:)`.
    private static let securityHardening_0_17_7 = WhatsNewRelease(
        version: "0.17.7",
        pages: [
            WhatsNewPage(
                id: "security-0.17.7:summary",
                title: "Security update",
                description:
                    "Chats and memory are now encrypted on disk. Sandbox plugins authenticate with per-agent tokens. Pairings are agent-scoped."
            ),
            WhatsNewPage(
                id: "security-0.17.7:storage",
                title: "Encrypted at rest",
                description:
                    "Chat history, memory, and configuration are encrypted with a key kept in your Keychain. Export a plaintext backup any time before reinstalling macOS.",
                actionLabel: "Backup & key options",
                action: .openStorageSettings
            ),
            WhatsNewPage(
                id: "security-0.17.7:sandbox",
                title: "Sandbox isolation",
                description: "Plugins now authenticate with per-agent tokens instead of self-reported headers.",
                actionLabel: "Open sandbox",
                action: .openSandboxSettings
            ),
            WhatsNewPage(
                id: "security-0.17.7:legacy-keys",
                title: "Paired devices",
                description: "New pairings are agent-scoped and expire in 90 days. Older keys are marked Legacy.",
                actionLabel: "Review",
                action: .openAPIKeysSettings
            ),
        ]
    )

    /// Returns the release notes for `version`, if any.
    public static func release(for version: String) -> WhatsNewRelease? {
        releases.first { $0.version == version }
    }

    /// Returns every release whose version is strictly greater than `stored`
    /// and less than or equal to `current`, sorted oldest → newest.
    /// Used to aggregate notes when a user skips one or more versions
    public static func releases(
        after stored: SemanticVersion,
        upTo current: SemanticVersion
    ) -> [WhatsNewRelease] {
        releases
            .compactMap { release -> (SemanticVersion, WhatsNewRelease)? in
                guard let v = SemanticVersion.parse(release.version) else { return nil }
                guard v > stored, v <= current else { return nil }
                return (v, release)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    /// Most recent release that has notes. used by the "Show What's New"
    /// menu action when the user wants to re-view the latest notes.
    public static var latest: WhatsNewRelease? { releases.last }
}
