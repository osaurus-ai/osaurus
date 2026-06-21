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
    /// Open Settings → Privacy (Privacy Filter master switch + custom rules).
    case openPrivacySettings
    /// Open Settings → Computer Use.
    case openComputerUseSettings
    /// Open Management → Credits.
    case openCredits
}

public struct WhatsNewPage: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    /// If nil, the page shows a sparkling stars background instead of an image.
    public let imageURL: URL?
    /// SF Symbol rendered over the accent gradient when `imageURL` is nil.
    /// Gives each page its own glyph instead of a single shared sparkle.
    /// Falls back to a generic sparkle in the view when nil.
    public let systemImage: String?
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
        systemImage: String? = nil,
        actionLabel: String? = nil,
        action: WhatsNewAction? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.imageURL = imageURL
        self.systemImage = systemImage
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
    public static let releases: [WhatsNewRelease] = [
        privacyFilter_0_19_0,
        osaurusCloud_0_20_1,
        computerUse_0_20_7,
    ]

    /// First-launch announcement for the Privacy Filter feature.
    /// Three pages: what it does, how the review flow keeps you in
    /// control, and where to tune the regex catalog. The last page's
    /// CTA deep-links to Settings → Privacy via `openPrivacySettings`.
    private static let privacyFilter_0_19_0 = WhatsNewRelease(
        version: "0.19.0",
        pages: [
            WhatsNewPage(
                id: "privacy-filter-0.19.0:summary",
                title: "Privacy Filter",
                description:
                    "Before anything leaves your Mac for a cloud model, Osaurus can scan for phone numbers, emails, names, addresses, and other sensitive data and swap them for placeholders. Responses are restored on the way back.",
                systemImage: "hand.raised.fill"
            ),
            WhatsNewPage(
                id: "privacy-filter-0.19.0:review",
                title: "You stay in control",
                description:
                    "Every redaction is shown to you before the request leaves — approve, edit, or send anyway. Replacements are highlighted inline in chat so you always know what shipped.",
                systemImage: "checkmark.shield.fill"
            ),
            WhatsNewPage(
                id: "privacy-filter-0.19.0:customize",
                title: "Tune what's scrubbed",
                description:
                    "Toggle built-in categories, add your own regex rules, and choose whether to auto-approve familiar redactions. Cloud-only — local models never round-trip through the filter.",
                systemImage: "slider.horizontal.3",
                actionLabel: "Open Privacy settings",
                action: .openPrivacySettings
            ),
        ]
    )

    /// First-launch announcement for Osaurus Cloud.
    /// The final CTA deep-links to Management → Credits so users can fund
    /// Router usage and try hosted models immediately.
    private static let osaurusCloud_0_20_1 = WhatsNewRelease(
        version: "0.20.1",
        pages: [
            WhatsNewPage(
                id: "osaurus-cloud-0.20.1:summary",
                title: "Osaurus Cloud is here",
                description:
                    "Use hosted models from Osaurus without bringing your own API key. Add credits once, pick an Osaurus model, and keep your agents, tools, memory, and local workflow exactly where they are.",
                systemImage: "cloud.fill"
            ),
            WhatsNewPage(
                id: "osaurus-cloud-0.20.1:venice",
                title: "Private inferencing through Venice AI",
                description:
                    "Osaurus Cloud routes inference through Venice AI, a privacy-first provider. Your chats stay on your Mac, while hosted requests use Router credits instead of separate provider accounts.",
                systemImage: "lock.shield.fill"
            ),
            WhatsNewPage(
                id: "osaurus-cloud-0.20.1:feedback",
                title: "We want your feedback",
                description:
                    "This is the first Osaurus Cloud launch. Please tell us what feels fast, what feels confusing, and which models or credit controls you want next.",
                systemImage: "bubble.left.and.bubble.right.fill",
                actionLabel: "Open Credits",
                action: .openCredits
            ),
        ]
    )

    /// First-launch announcement for Computer Use (experimental).
    /// Three pages: what it does, the safe-by-default autonomy gate, and the
    /// local-first perception + opt-in screen context posture. The final CTA
    /// deep-links to Settings → Computer Use so users can enable it per agent
    /// and tune autonomy immediately.
    private static let computerUse_0_20_7 = WhatsNewRelease(
        version: "0.20.7",
        pages: [
            WhatsNewPage(
                id: "computer-use-0.20.7:summary",
                title: "Computer Use (experimental)",
                description:
                    "Let a custom agent operate a macOS app to reach a goal — fill a form, flip a setting, pull text off the screen. It works primarily from the accessibility tree and only falls back to a screenshot when an element can't be resolved. Off by default; enabled per agent.",
                systemImage: "macwindow"
            ),
            WhatsNewPage(
                id: "computer-use-0.20.7:safety",
                title: "Safe by default",
                description:
                    "Every action is classified — read, navigate, edit, or consequential — and passes an autonomy gate first. The default balanced preset runs reads and navigation but pauses for your confirmation before edits or anything consequential (send, delete, purchase). Add a per-app or per-agent ceiling, or an allowlist of apps it may touch.",
                systemImage: "checkmark.shield.fill"
            ),
            WhatsNewPage(
                id: "computer-use-0.20.7:privacy",
                title: "Local-first and private",
                description:
                    "Perception stays on your Mac unless you opt in to Cloud vision — and even then frames are OCR-scrubbed for PII first. You can also opt in to Screen context, which shares a frozen, text-only snapshot of what you're doing with chat and routes it through the Privacy Filter before any cloud send.",
                systemImage: "lock.fill",
                actionLabel: "Open Computer Use settings",
                action: .openComputerUseSettings
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
