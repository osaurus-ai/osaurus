//
//  ScreenContextDistiller.swift
//  OsaurusCore — Computer Use
//
//  Smart sampling of "what the user is doing" into a compact, text-only
//  `ScreenContextSnapshot`. Rather than dumping the whole accessibility tree,
//  it prioritizes the most informative signals: the working app + focused
//  input (the draft the user is typing), the list of open windows, and a small
//  ranked sample of on-screen text — all budgeted so the injected block stays
//  small.
//
//  Pure over an injected `MacDriver`, so it is fully unit-testable with
//  `MockMacDriver`. The production entry point (`captureForChat`) wires in the
//  real `NativeMacDriver` plus the self-identity and the working-app hint from
//  `FrontmostAppTracker`.
//

import Foundation

public struct ScreenContextDistiller: Sendable {
    /// Max windows listed across all apps.
    public var maxWindows: Int
    /// Max apps whose windows we enumerate (bounds AX traversal cost).
    public var maxAppsToScan: Int
    /// Max sampled on-screen text items.
    public var maxContentItems: Int
    /// Max chars kept for the focused field's value/draft.
    public var maxValueChars: Int
    /// Max chars kept per sampled on-screen item / window title.
    public var maxItemChars: Int

    public init(
        maxWindows: Int = 12,
        maxAppsToScan: Int = 12,
        maxContentItems: Int = 16,
        maxValueChars: Int = 160,
        maxItemChars: Int = 100
    ) {
        self.maxWindows = maxWindows
        self.maxAppsToScan = maxAppsToScan
        self.maxContentItems = maxContentItems
        self.maxValueChars = maxValueChars
        self.maxItemChars = maxItemChars
    }

    /// Osaurus's own identity, used to exclude it from the "what you're doing"
    /// signal (it's usually frontmost when the user hits send).
    private struct SelfIdentity {
        let pid: Int32
        let bundleId: String?

        func matches(pid: Int32, bundleId: String?) -> Bool {
            if pid == self.pid { return true }
            if let bundleId, let mine = self.bundleId, bundleId == mine { return true }
            return false
        }

        func owns(_ app: CUAppListing) -> Bool {
            matches(pid: app.pid, bundleId: app.bundleId)
        }
    }

    private struct WorkingApp {
        let pid: Int32
        let name: String
        let windowTitle: String?
    }

    /// Build a snapshot from the given driver. `selfPid` / `selfBundleId`
    /// identify Osaurus so it can be excluded from the "what you're doing"
    /// signal; `preferredPid` is the working-app fallback used when Osaurus is
    /// itself frontmost (see `FrontmostAppTracker`).
    public func capture(
        using driver: MacDriver,
        selfPid: Int32,
        selfBundleId: String?,
        preferredPid: Int32?
    ) async -> ScreenContextSnapshot {
        guard await driver.availability().accessibility else {
            return .unavailable(accessibilityGranted: false)
        }

        let identity = SelfIdentity(pid: selfPid, bundleId: selfBundleId)
        let active = await driver.activeWindow()
        let apps = await driver.listApps()

        let working = resolveWorkingApp(
            active: active,
            apps: apps,
            identity: identity,
            preferredPid: preferredPid
        )
        let windows = await buildWindows(
            using: driver,
            apps: apps,
            active: active,
            working: working,
            identity: identity
        )

        var focused: ScreenContextSnapshot.FocusedElement?
        var sampled: [String] = []
        var workingWindowTitle = working?.windowTitle

        if let working {
            let snap = await driver.capture(
                pid: working.pid,
                tier: .ax,
                windowId: nil,
                maxElements: 80,
                focusedWindowOnly: true
            )
            if let title = snap.focusedWindow, !title.isEmpty {
                workingWindowTitle = title
            }
            focused = focusedElement(from: snap)
            sampled = sampleContents(from: snap, windowTitle: workingWindowTitle, focused: focused)
        }

        return ScreenContextSnapshot(
            accessibilityGranted: true,
            workingApp: working?.name,
            workingWindowTitle: workingWindowTitle,
            activityGist: buildGist(app: working?.name, windowTitle: workingWindowTitle, focused: focused),
            focusedElement: focused,
            windows: windows,
            sampledContents: sampled
        )
    }

    // MARK: - Working app resolution

    private func resolveWorkingApp(
        active: CUActiveWindow?,
        apps: [CUAppListing],
        identity: SelfIdentity,
        preferredPid: Int32?
    ) -> WorkingApp? {
        // 1. The genuine frontmost app, when Osaurus didn't steal focus.
        if let active, !identity.matches(pid: active.pid, bundleId: nil) {
            return WorkingApp(pid: active.pid, name: active.app, windowTitle: active.title)
        }
        // 2. The app the user was on right before Osaurus took focus.
        if let preferredPid,
            let match = apps.first(where: { $0.pid == preferredPid }),
            !identity.owns(match)
        {
            return WorkingApp(pid: match.pid, name: match.name, windowTitle: nil)
        }
        // 3. Best-effort: the first visible non-Osaurus app, else any non-Osaurus app.
        let candidate =
            apps.first(where: { !$0.hidden && !identity.owns($0) })
            ?? apps.first(where: { !identity.owns($0) })
        return candidate.map { WorkingApp(pid: $0.pid, name: $0.name, windowTitle: nil) }
    }

    // MARK: - Window list

    private func buildWindows(
        using driver: MacDriver,
        apps: [CUAppListing],
        active: CUActiveWindow?,
        working: WorkingApp?,
        identity: SelfIdentity
    ) async -> [ScreenContextSnapshot.WindowRef] {
        // Scan the working app first so its windows lead the list, then the
        // rest, skipping Osaurus and hidden apps.
        var ordered: [CUAppListing] = []
        if let workingPid = working?.pid, let workingApp = apps.first(where: { $0.pid == workingPid }) {
            ordered.append(workingApp)
        }
        ordered += apps.filter { $0.pid != working?.pid && !$0.hidden && !identity.owns($0) }
        ordered = Array(ordered.prefix(maxAppsToScan))

        var refs: [ScreenContextSnapshot.WindowRef] = []
        for app in ordered {
            if refs.count >= maxWindows { break }
            for window in await driver.listWindows(pid: app.pid) {
                if refs.count >= maxWindows { break }
                if window.minimized { continue }
                let hasTitle = !(window.title?.isEmpty ?? true)
                if !hasTitle && !window.focused { continue }
                refs.append(
                    ScreenContextSnapshot.WindowRef(
                        app: app.name,
                        title: window.title.map { clean($0, limit: maxItemChars) },
                        frontmost: app.pid == active?.pid && window.focused
                    )
                )
            }
        }
        return refs
    }

    // MARK: - Focused element + contents

    private func focusedElement(from snapshot: CUSnapshot) -> ScreenContextSnapshot.FocusedElement? {
        guard let element = snapshot.elements.first(where: { $0.focused }) else { return nil }
        return ScreenContextSnapshot.FocusedElement(
            role: friendlyRole(element.role),
            label: cleaned(element.label, limit: maxItemChars),
            placeholder: cleaned(element.placeholder, limit: maxItemChars),
            value: cleaned(element.value, limit: maxValueChars)
        )
    }

    private func sampleContents(
        from snapshot: CUSnapshot,
        windowTitle: String?,
        focused: ScreenContextSnapshot.FocusedElement?
    ) -> [String] {
        // Seed the de-dup set with text we've already surfaced so the sample
        // only adds new signal.
        var seen = Set([windowTitle, focused?.value, focused?.label].compactMap { $0?.lowercased() })
        var items: [String] = []

        for element in snapshot.elements {
            if items.count >= maxContentItems { break }
            guard let text = sampleText(for: element) else { continue }
            let key = text.lowercased()
            if seen.insert(key).inserted {
                items.append(text)
            }
        }
        return items
    }

    /// One sampled line for an element, or nil if it carries no useful text.
    private func sampleText(for element: CUElement) -> String? {
        let label = cleaned(element.label, limit: maxItemChars)
        let value = cleaned(element.value, limit: maxItemChars)

        switch element.role.lowercased() {
        case "statictext", "heading", "staticrtext":
            return value ?? label
        case "button", "link", "menuitem", "menubaritem", "tab", "checkbox", "radiobutton",
            "popupbutton", "menubutton":
            return label
        case "securetextfield":
            return label.map { "\($0): (hidden)" }
        case "textfield", "textarea", "searchfield", "combobox":
            // Non-focused inputs only matter when they already hold something.
            guard let value else { return nil }
            return label.map { "\($0): \(value)" } ?? value
        default:
            return nil
        }
    }

    // MARK: - Gist

    private func buildGist(
        app: String?,
        windowTitle: String?,
        focused: ScreenContextSnapshot.FocusedElement?
    ) -> String? {
        guard let app else { return nil }
        var gist = "In \(app)"
        if let windowTitle, !windowTitle.isEmpty {
            gist += " — \"\(windowTitle)\""
        }
        guard let focused else { return gist }

        if Self.textInputRoles.contains(focused.role) {
            let hasDraft = !(focused.value?.isEmpty ?? true)
            gist += hasDraft ? "; editing \(focused.role) (draft present)" : "; \(focused.role) focused (empty)"
        } else {
            gist += "; \(focused.role) focused"
        }
        return gist
    }

    // MARK: - Role helpers

    /// Friendly forms of the input roles, matched against `friendlyRole` output.
    private static let textInputRoles: Set<String> = [
        "text field", "text area", "search field", "secure field", "combo box",
    ]

    private func friendlyRole(_ role: String) -> String {
        switch role.lowercased() {
        case "textfield": return "text field"
        case "textarea": return "text area"
        case "searchfield": return "search field"
        case "securetextfield": return "secure field"
        case "combobox": return "combo box"
        case "popupbutton": return "pop-up button"
        case "statictext", "staticrtext": return "text"
        case let other: return other
        }
    }

    // MARK: - Text helpers

    /// Collapse whitespace/newlines into a single line and truncate to `limit`.
    private func clean(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `clean`, but nil for nil / whitespace-only input.
    private func cleaned(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let result = clean(text, limit: limit)
        return result.isEmpty ? nil : result
    }
}

// MARK: - Production entry point

extension ScreenContextDistiller {
    /// Capture a snapshot for the chat send path using the real macOS driver,
    /// Osaurus's own identity, and the working-app hint from the frontmost
    /// tracker.
    @MainActor
    public static func captureForChat(
        driver: MacDriver = NativeMacDriver()
    ) async -> ScreenContextSnapshot {
        await ScreenContextDistiller().capture(
            using: driver,
            selfPid: ProcessInfo.processInfo.processIdentifier,
            selfBundleId: Bundle.main.bundleIdentifier,
            preferredPid: FrontmostAppTracker.shared.lastNonSelfPid
        )
    }
}
