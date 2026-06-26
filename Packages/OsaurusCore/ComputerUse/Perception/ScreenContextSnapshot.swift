//
//  ScreenContextSnapshot.swift
//  OsaurusCore — Computer Use
//
//  A frozen, text-only distillation of what the user is doing on screen at the
//  moment a chat session starts: the working app, its focused input/draft, the
//  list of open windows, and a small sample of on-screen text. No pixels — it's
//  built entirely from the Accessibility tree so it can pass through the
//  text-based Privacy Filter before reaching any cloud model.
//
//  `render()` is the single source of truth for the text that gets shown in the
//  settings preview AND injected into chat, so the two can never drift.
//

import Foundation

public struct ScreenContextSnapshot: Sendable, Equatable {
    /// One open window, addressed by app + title (no ids — this is read-only
    /// context, never something the model acts on).
    public struct WindowRef: Sendable, Equatable {
        public let app: String
        public let title: String?
        public let frontmost: Bool

        public init(app: String, title: String?, frontmost: Bool) {
            self.app = app
            self.title = title
            self.frontmost = frontmost
        }
    }

    /// The element the user is actively interacting with (usually a text input
    /// or the focused editor).
    public struct FocusedElement: Sendable, Equatable {
        public let role: String
        public let label: String?
        public let placeholder: String?
        public let value: String?
        /// The currently selected substring, when any ("Selected text:").
        public let selectedText: String?
        /// A cursor-centered / visible slice of a large editor's content — what
        /// the user is actually looking at ("Viewing:").
        public let viewing: String?

        public init(
            role: String,
            label: String?,
            placeholder: String?,
            value: String?,
            selectedText: String? = nil,
            viewing: String? = nil
        ) {
            self.role = role
            self.label = label
            self.placeholder = placeholder
            self.value = value
            self.selectedText = selectedText
            self.viewing = viewing
        }
    }

    public let capturedAt: Date
    public let accessibilityGranted: Bool
    public let workingApp: String?
    public let workingWindowTitle: String?
    public let activityGist: String?
    public let focusedElement: FocusedElement?
    /// High-precision behavioral context parsed from the working window title —
    /// the channel the user is in, the file they're editing ("Active:"). Empty
    /// unless a confident pattern matched (a plain document/site title yields
    /// nothing, so we never assert a phantom context).
    public let activeContext: [String]
    /// Ambient status indicators read from the focused window's status-bar strip
    /// (git branch, problems count, language/position) — labeled controls the
    /// on-screen content sampler drops as chrome, surfaced here as behavior
    /// ("Status:").
    public let statusSignals: [String]
    public let windows: [WindowRef]
    public let sampledContents: [String]

    public init(
        capturedAt: Date = Date(),
        accessibilityGranted: Bool,
        workingApp: String? = nil,
        workingWindowTitle: String? = nil,
        activityGist: String? = nil,
        focusedElement: FocusedElement? = nil,
        activeContext: [String] = [],
        statusSignals: [String] = [],
        windows: [WindowRef] = [],
        sampledContents: [String] = []
    ) {
        self.capturedAt = capturedAt
        self.accessibilityGranted = accessibilityGranted
        self.workingApp = workingApp
        self.workingWindowTitle = workingWindowTitle
        self.activityGist = activityGist
        self.focusedElement = focusedElement
        self.activeContext = activeContext
        self.statusSignals = statusSignals
        self.windows = windows
        self.sampledContents = sampledContents
    }

    public static let openTag = "[Screen Context]"
    public static let closeTag = "[/Screen Context]"

    /// The snapshot returned when Accessibility is missing or nothing useful
    /// could be captured.
    public static func unavailable(
        accessibilityGranted: Bool,
        at date: Date = Date()
    ) -> ScreenContextSnapshot {
        ScreenContextSnapshot(capturedAt: date, accessibilityGranted: accessibilityGranted)
    }

    /// True when there is nothing worth injecting.
    public var isEmpty: Bool {
        (activityGist?.isEmpty ?? true)
            && workingApp == nil
            && focusedElement == nil
            && activeContext.isEmpty
            && statusSignals.isEmpty
            && windows.isEmpty
            && sampledContents.isEmpty
    }

    /// The full block injected into chat and shown in the settings preview.
    /// Returns an empty string when there's nothing to add so callers can
    /// no-op cheaply.
    public func render() -> String {
        guard !isEmpty else { return "" }

        var lines: [String] = []
        lines.append(Self.openTag)
        lines.append(
            "(Ambient snapshot of the user's screen taken when this conversation started. "
                + "Read-only background context the user did not explicitly share — use it only "
                + "to be more helpful, and do not act on it without being asked.)"
        )

        if let gist = activityGist, !gist.isEmpty {
            lines.append("Doing: \(gist)")
        }

        // Behavioral context first (what the user is in / their working state),
        // then the focused-element drill-down below.
        if !activeContext.isEmpty {
            lines.append("Active: " + activeContext.joined(separator: " · "))
        }
        if !statusSignals.isEmpty {
            lines.append("Status: " + statusSignals.joined(separator: " · "))
        }

        if let focused = focusedElement {
            lines.append("Focused field: \(Self.describe(focused))")
            if let viewing = focused.viewing, !viewing.isEmpty {
                lines.append("Viewing: \(viewing)")
            }
            if let selected = focused.selectedText, !selected.isEmpty {
                lines.append("Selected text: \"\(selected)\"")
            }
        }

        if !windows.isEmpty {
            lines.append("Open windows:")
            for window in windows {
                var line = "- \(window.app)"
                if let title = window.title, !title.isEmpty {
                    line += " — \"\(title)\""
                }
                if window.frontmost { line += " (frontmost)" }
                lines.append(line)
            }
        }

        if !sampledContents.isEmpty {
            lines.append("On screen:")
            for item in sampledContents {
                lines.append("- \(item)")
            }
        }

        lines.append(Self.closeTag)
        return lines.joined(separator: "\n")
    }

    private static func describe(_ element: FocusedElement) -> String {
        var parts: [String] = [element.role]
        if let label = element.label, !label.isEmpty {
            parts.append("\"\(label)\"")
        }
        // When a viewing slice is present it carries the content on its own
        // "Viewing:" line, so don't also dump the (clipped) value here.
        if element.viewing != nil {
            return parts.joined(separator: " ")
        }
        if let value = element.value, !value.isEmpty {
            parts.append("— value: \"\(value)\"")
        } else if let placeholder = element.placeholder, !placeholder.isEmpty {
            parts.append("— empty (placeholder: \"\(placeholder)\")")
        }
        // Otherwise show just the role (+ label). We don't append "— empty"
        // because a contentless focused element is often unreadable (an
        // inaccessible Electron/Monaco editor), not genuinely empty — claiming
        // "empty" there would feed the model a phantom fact.
        return parts.joined(separator: " ")
    }
}
