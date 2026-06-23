//
//  ScreenContextFixture.swift
//  OsaurusEvalsKit
//
//  A captured (or synthetic) macOS screen state the `ScreenContextDistiller`
//  can be replayed against deterministically. The distiller is pure over an
//  injected `MacDriver`, so a frozen accessibility tree + listings + a direct
//  focused-element read is everything it needs to produce a `[Screen Context]`
//  block — no real Accessibility, SkyLight, or Screen Recording. That makes a
//  `screen_context` eval reproducible and CI-safe.
//
//  Every member is `Codable` (all the `CU*` contract types are), so a fixture
//  can be hand-authored as synthetic JSON, captured from a real app via the
//  `capture-screen` CLI, or inlined in a case's `expect.screenContext.scene`.
//  `CUImage` is deliberately excluded — these are AX-only fixtures (the
//  distiller is text-only and never reads pixels).
//

import Foundation
import OsaurusCore

public struct ScreenContextFixture: Sendable, Codable, Equatable {

    public struct CaptureSummary: Sendable, Equatable {
        public struct RoleCount: Sendable, Equatable {
            public let role: String
            public let count: Int

            public init(role: String, count: Int) {
                self.role = role
                self.count = count
            }
        }

        public let workingApp: String
        public let workingWindowTitle: String?
        public let appCount: Int
        public let windowCount: Int
        public let elementCount: Int
        public let textElementCount: Int
        public let secureFieldCount: Int
        public let pathFieldCount: Int
        public let truncated: Bool
        public let focusedRole: String?
        public let focusedLabel: String?
        public let topRoles: [RoleCount]
        public let localOnlyReasons: [String]

        public init(
            workingApp: String,
            workingWindowTitle: String?,
            appCount: Int,
            windowCount: Int,
            elementCount: Int,
            textElementCount: Int,
            secureFieldCount: Int,
            pathFieldCount: Int,
            truncated: Bool,
            focusedRole: String?,
            focusedLabel: String?,
            topRoles: [RoleCount],
            localOnlyReasons: [String]
        ) {
            self.workingApp = workingApp
            self.workingWindowTitle = workingWindowTitle
            self.appCount = appCount
            self.windowCount = windowCount
            self.elementCount = elementCount
            self.textElementCount = textElementCount
            self.secureFieldCount = secureFieldCount
            self.pathFieldCount = pathFieldCount
            self.truncated = truncated
            self.focusedRole = focusedRole
            self.focusedLabel = focusedLabel
            self.topRoles = topRoles
            self.localOnlyReasons = localOnlyReasons
        }
    }

    public struct PromotionSanitizationReport: Sendable, Equatable {
        public var stringFieldsRedacted: Int
        public var secureValuesDropped: Int
        public var elementIDsRewritten: Int
        public var pathFieldsDropped: Int
        public var windowTitlesRedacted: Int
        public var appMetadataRedacted: Int

        public init(
            stringFieldsRedacted: Int = 0,
            secureValuesDropped: Int = 0,
            elementIDsRewritten: Int = 0,
            pathFieldsDropped: Int = 0,
            windowTitlesRedacted: Int = 0,
            appMetadataRedacted: Int = 0
        ) {
            self.stringFieldsRedacted = stringFieldsRedacted
            self.secureValuesDropped = secureValuesDropped
            self.elementIDsRewritten = elementIDsRewritten
            self.pathFieldsDropped = pathFieldsDropped
            self.windowTitlesRedacted = windowTitlesRedacted
            self.appMetadataRedacted = appMetadataRedacted
        }
    }

    public struct PromotionCandidate: Sendable, Equatable {
        public let fixture: ScreenContextFixture
        public let report: PromotionSanitizationReport

        public init(fixture: ScreenContextFixture, report: PromotionSanitizationReport) {
            self.fixture = fixture
            self.report = report
        }
    }

    /// The single capture the distiller reads for the working app. Mirrors the
    /// scored fields of `CUSnapshot` (the image and ids are irrelevant to the
    /// text distillation) plus `truncated`, which gates the editor-fallback
    /// `find(...)` path so a fixture can reproduce the chrome-heavy-app case
    /// where the bounded traversal misses the editor.
    public struct Snapshot: Sendable, Codable, Equatable {
        public let app: String
        public let focusedWindow: String?
        /// True when the real AX traversal would have hit its element budget
        /// before finishing — the signal that triggers the distiller's targeted
        /// `textarea` fallback search.
        public let truncated: Bool
        public let windows: [CUWindowSummary]
        public let elements: [CUElement]

        public init(
            app: String,
            focusedWindow: String? = nil,
            truncated: Bool = false,
            windows: [CUWindowSummary] = [],
            elements: [CUElement] = []
        ) {
            self.app = app
            self.focusedWindow = focusedWindow
            self.truncated = truncated
            self.windows = windows
            self.elements = elements
        }

        private enum CodingKeys: String, CodingKey {
            case app, focusedWindow, truncated, windows, elements
        }

        // Lenient decode so a hand-authored synthetic fixture can omit empty
        // collections / the truncated flag. Encoding stays synthesized (the
        // capture CLI writes every key).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.app = try c.decode(String.self, forKey: .app)
            self.focusedWindow = try c.decodeIfPresent(String.self, forKey: .focusedWindow)
            self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
            self.windows = try c.decodeIfPresent([CUWindowSummary].self, forKey: .windows) ?? []
            self.elements = try c.decodeIfPresent([CUElement].self, forKey: .elements) ?? []
        }
    }

    /// Running apps the distiller enumerates (`listApps`). The working app is
    /// resolved from `activeWindow` first, falling back to the first non-self
    /// app here.
    public let apps: [CUAppListing]
    /// The frontmost window (`activeWindow`). Drives working-app resolution.
    public let activeWindow: CUActiveWindow?
    /// Per-pid window listings (`listWindows`). JSON object keys are strings, so
    /// the pid is stored as its decimal string (e.g. `"100"`).
    public let windowsByPid: [String: [CUWindowInfo]]
    /// The working app's captured accessibility tree.
    public let snapshot: Snapshot
    /// The direct focused-element read (`focusedContent`) — the primary "what am
    /// I looking at" signal, independent of the bounded traversal.
    public let focusedContent: CUFocusedContent?

    public init(
        apps: [CUAppListing],
        activeWindow: CUActiveWindow?,
        windowsByPid: [String: [CUWindowInfo]],
        snapshot: Snapshot,
        focusedContent: CUFocusedContent? = nil
    ) {
        self.apps = apps
        self.activeWindow = activeWindow
        self.windowsByPid = windowsByPid
        self.snapshot = snapshot
        self.focusedContent = focusedContent
    }

    private enum CodingKeys: String, CodingKey {
        case apps, activeWindow, windowsByPid, snapshot, focusedContent
    }

    // Lenient decode so a hand-authored synthetic fixture can omit the
    // per-pid window map and the focused read when they aren't needed.
    // Encoding stays synthesized (the capture CLI writes every key).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.apps = try c.decodeIfPresent([CUAppListing].self, forKey: .apps) ?? []
        self.activeWindow = try c.decodeIfPresent(CUActiveWindow.self, forKey: .activeWindow)
        self.windowsByPid =
            try c.decodeIfPresent([String: [CUWindowInfo]].self, forKey: .windowsByPid) ?? [:]
        self.snapshot = try c.decode(Snapshot.self, forKey: .snapshot)
        self.focusedContent = try c.decodeIfPresent(CUFocusedContent.self, forKey: .focusedContent)
    }

    // MARK: - Driver helpers

    /// The pid the distiller will resolve as the working app — `activeWindow`'s
    /// pid when present, else the first listed app's. The `FixtureCUDriver`
    /// serves the snapshot for whichever pid it's asked about, but this is the
    /// one a faithful fixture keys its `windowsByPid` entry on.
    public var workingPid: Int32 {
        activeWindow?.pid ?? apps.first?.pid ?? 0
    }

    /// Window listings for `pid`, or an empty list when the fixture didn't
    /// capture that app's windows.
    public func windows(forPid pid: Int32) -> [CUWindowInfo] {
        windowsByPid[String(pid)] ?? []
    }

    /// Materialize the fixture's `Snapshot` into a real `CUSnapshot` for the
    /// requested pid. `maxElements` is honored (prefix truncation) so the
    /// distiller's chrome-budget behavior is reproduced; `truncated` is OR'd
    /// with "we actually clipped" so either the fixture's flag or a too-small
    /// budget trips the editor fallback.
    public func cuSnapshot(pid: Int32, snapshotId: Int, maxElements: Int?) -> CUSnapshot {
        let all = snapshot.elements
        let clipped: [CUElement]
        let didClip: Bool
        if let cap = maxElements, cap >= 0, all.count > cap {
            clipped = Array(all.prefix(cap))
            didClip = true
        } else {
            clipped = all
            didClip = false
        }
        return CUSnapshot(
            snapshotId: snapshotId,
            pid: pid,
            app: snapshot.app,
            focusedWindow: snapshot.focusedWindow,
            tier: .ax,
            truncated: snapshot.truncated || didClip,
            windows: snapshot.windows,
            elements: clipped,
            image: nil
        )
    }

    // MARK: - Capture lab helpers

    public func captureSummary(topRoleLimit: Int = 8) -> CaptureSummary {
        let windows = windowsByPid.values.reduce(0) { $0 + $1.count }
        let roleCounts = Dictionary(grouping: snapshot.elements, by: { $0.role.lowercased() })
            .map { CaptureSummary.RoleCount(role: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.role < $1.role
            }
            .prefix(topRoleLimit)

        let textElements = snapshot.elements.filter(Self.elementCarriesText).count
        let secureFields = snapshot.elements.filter { Self.isSecureRole($0.role) }.count
        let pathFields = snapshot.elements.filter { $0.path?.isEmpty == false }.count

        var reasons: [String] = []
        if textElements > 0 || focusedContentHasText {
            reasons.append("contains text read from the user's accessibility tree")
        }
        if secureFields > 0 || focusedContent.map({ Self.isSecureRole($0.role) }) == true {
            reasons.append("contains secure-field metadata that must be reviewed")
        }
        if pathFields > 0 {
            reasons.append("contains accessibility paths that can include private labels")
        }
        let hasUserWindowTitle =
            Self.hasUserWindowTitle(activeWindow?.title)
            || Self.hasUserWindowTitle(snapshot.focusedWindow)
            || snapshot.windows.contains(where: { Self.hasUserWindowTitle($0.title) })
            || windowsByPid.values.flatMap({ $0 }).contains(where: { Self.hasUserWindowTitle($0.title) })
        if hasUserWindowTitle {
            reasons.append("contains window title metadata from the user's desktop")
        }
        if Self.hasUserAppMetadata(apps: apps, activeWindow: activeWindow, snapshot: snapshot) {
            reasons.append("contains app metadata from the user's desktop")
        }
        if !reasons.isEmpty {
            reasons.append("keep under Fixtures/ScreenContext/local/ until sanitized")
        }

        return CaptureSummary(
            workingApp: activeWindow?.app ?? snapshot.app,
            workingWindowTitle: activeWindow?.title ?? snapshot.focusedWindow,
            appCount: apps.count,
            windowCount: windows,
            elementCount: snapshot.elements.count,
            textElementCount: textElements,
            secureFieldCount: secureFields,
            pathFieldCount: pathFields,
            truncated: snapshot.truncated,
            focusedRole: focusedContent?.role,
            focusedLabel: focusedContent?.label,
            topRoles: Array(roleCounts),
            localOnlyReasons: reasons
        )
    }

    public func sanitizedForPromotion() -> PromotionCandidate {
        var report = PromotionSanitizationReport()
        let appNamesByPid = Self.syntheticAppNames(apps: apps, activeWindow: activeWindow)
        let syntheticActiveApp =
            activeWindow.flatMap { appNamesByPid[$0.pid] }
            ?? appNamesByPid[workingPid]
            ?? "Synthetic App"
        let syntheticSnapshotApp = appNamesByPid[workingPid] ?? syntheticActiveApp
        let syntheticTitle = Self.syntheticWindowTitle(app: syntheticSnapshotApp)
        let sanitizedApps = apps.enumerated().map { offset, app in
            Self.sanitize(app: app, replacementName: "Synthetic App \(offset + 1)", report: &report)
        }
        Self.recordAppMetadataRedaction(activeWindow?.app, replacement: syntheticActiveApp, report: &report)
        Self.recordAppMetadataRedaction(snapshot.app, replacement: syntheticSnapshotApp, report: &report)

        let active: CUActiveWindow?
        if let activeWindow {
            active = CUActiveWindow(
                pid: activeWindow.pid,
                app: syntheticActiveApp,
                title: Self.redactWindowTitle(activeWindow.title, app: syntheticActiveApp, report: &report),
                x: activeWindow.x,
                y: activeWindow.y,
                w: activeWindow.w,
                h: activeWindow.h
            )
        } else {
            active = nil
        }

        var sanitizedWindows: [String: [CUWindowInfo]] = [:]
        for (pidKey, windows) in windowsByPid {
            let pid = Int32(pidKey)
            let syntheticApp = pid.flatMap { appNamesByPid[$0] } ?? syntheticSnapshotApp
            sanitizedWindows[pidKey] = windows.map { window in
                CUWindowInfo(
                    windowId: window.windowId,
                    title: Self.redactWindowTitle(window.title, app: syntheticApp, report: &report),
                    focused: window.focused,
                    minimized: window.minimized,
                    x: window.x,
                    y: window.y,
                    w: window.w,
                    h: window.h
                )
            }
        }

        let sanitizedSnapshot = Snapshot(
            app: syntheticSnapshotApp,
            focusedWindow: snapshot.focusedWindow == nil ? nil : syntheticTitle,
            truncated: snapshot.truncated,
            windows: snapshot.windows.map { window in
                CUWindowSummary(
                    id: window.id,
                    title: Self.redactWindowTitle(window.title, app: syntheticSnapshotApp, report: &report),
                    focused: window.focused,
                    x: window.x,
                    y: window.y,
                    w: window.w,
                    h: window.h
                )
            },
            elements: snapshot.elements.enumerated().map { offset, element in
                Self.sanitize(element: element, index: offset + 1, report: &report)
            }
        )

        if snapshot.focusedWindow != nil {
            report.windowTitlesRedacted += 1
            report.stringFieldsRedacted += 1
        }

        let sanitized = ScreenContextFixture(
            apps: sanitizedApps,
            activeWindow: active,
            windowsByPid: sanitizedWindows,
            snapshot: sanitizedSnapshot,
            focusedContent: focusedContent.map { Self.sanitize(focused: $0, report: &report) }
        )
        return PromotionCandidate(fixture: sanitized, report: report)
    }

    private var focusedContentHasText: Bool {
        guard let focusedContent else { return false }
        return [
            focusedContent.label,
            focusedContent.placeholder,
            focusedContent.value,
            focusedContent.selectedText,
            focusedContent.viewport,
        ].contains { $0?.isEmpty == false }
    }

    private static func hasUserWindowTitle(_ title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return false
        }
        return !title.hasPrefix("Synthetic ")
    }

    private static func hasUserAppMetadata(
        apps: [CUAppListing],
        activeWindow: CUActiveWindow?,
        snapshot: Snapshot
    ) -> Bool {
        if apps.contains(where: { app in
            app.bundleId?.isEmpty == false || !app.name.hasPrefix("Synthetic ")
        }) {
            return true
        }
        if let activeWindow, !activeWindow.app.hasPrefix("Synthetic ") {
            return true
        }
        return !snapshot.app.hasPrefix("Synthetic ")
    }

    private static func elementCarriesText(_ element: CUElement) -> Bool {
        [
            element.roleDescription,
            element.label,
            element.value,
            element.selectedText,
            element.placeholder,
            element.path,
        ].contains { $0?.isEmpty == false }
    }

    private static func isSecureRole(_ role: String) -> Bool {
        switch role.lowercased() {
        case "securetextfield", "axsecuretextfield", "securefield":
            return true
        default:
            return false
        }
    }

    private static func redactWindowTitle(
        _ title: String?,
        app: String,
        report: inout PromotionSanitizationReport
    ) -> String? {
        guard title?.isEmpty == false else { return title }
        report.windowTitlesRedacted += 1
        report.stringFieldsRedacted += 1
        return syntheticWindowTitle(app: app)
    }

    private static func sanitize(
        app: CUAppListing,
        replacementName: String,
        report: inout PromotionSanitizationReport
    ) -> CUAppListing {
        recordAppMetadataRedaction(app.name, replacement: replacementName, report: &report)
        recordAppMetadataRedaction(app.bundleId, replacement: nil, report: &report)
        return CUAppListing(
            pid: app.pid,
            bundleId: nil,
            name: replacementName,
            active: app.active,
            hidden: app.hidden
        )
    }

    private static func sanitize(
        element: CUElement,
        index: Int,
        report: inout PromotionSanitizationReport
    ) -> CUElement {
        if element.id != "e\(index)" {
            report.elementIDsRewritten += 1
        }
        let secure = isSecureRole(element.role)
        if element.path?.isEmpty == false {
            report.pathFieldsDropped += 1
        }
        let roleDescription = redact(
            element.roleDescription,
            replacement: "Synthetic role description \(index)",
            report: &report
        )
        let label = redact(
            element.label,
            replacement: "Synthetic \(roleLabel(element.role)) label \(index)",
            report: &report
        )
        let placeholder = redact(
            element.placeholder,
            replacement: "Synthetic placeholder \(index)",
            report: &report
        )
        let value: String?
        let selectedText: String?
        if secure {
            value = dropSecure(element.value, report: &report)
            selectedText = dropSecure(element.selectedText, report: &report)
        } else {
            value = redact(
                element.value,
                replacement: syntheticValue(role: element.role, index: index),
                report: &report
            )
            selectedText = redact(
                element.selectedText,
                replacement: "synthetic selection \(index)",
                report: &report
            )
        }

        return CUElement(
            id: "e\(index)",
            role: element.role,
            roleDescription: roleDescription,
            label: label,
            value: value,
            selectedText: selectedText,
            placeholder: placeholder,
            path: nil,
            windowId: element.windowId,
            focused: element.focused,
            enabled: element.enabled,
            x: element.x,
            y: element.y,
            w: element.w,
            h: element.h,
            actions: element.actions
        )
    }

    private static func sanitize(
        focused: CUFocusedContent,
        report: inout PromotionSanitizationReport
    ) -> CUFocusedContent {
        let secure = isSecureRole(focused.role)
        return CUFocusedContent(
            role: focused.role,
            label: redact(
                focused.label,
                replacement: "Synthetic focused \(roleLabel(focused.role))",
                report: &report
            ),
            placeholder: redact(
                focused.placeholder,
                replacement: "Synthetic focused placeholder",
                report: &report
            ),
            value: secure
                ? dropSecure(focused.value, report: &report)
                : redact(
                    focused.value,
                    replacement: syntheticValue(role: focused.role, index: 1),
                    report: &report
                ),
            selectedText: secure
                ? dropSecure(focused.selectedText, report: &report)
                : redact(
                    focused.selectedText,
                    replacement: "synthetic focused selection",
                    report: &report
                ),
            viewport: secure
                ? dropSecure(focused.viewport, report: &report)
                : redact(
                    focused.viewport,
                    replacement: "Synthetic viewport excerpt replaces local capture text.",
                    report: &report
                )
        )
    }

    private static func redact(
        _ value: String?,
        replacement: String,
        report: inout PromotionSanitizationReport
    ) -> String? {
        guard value?.isEmpty == false else { return value }
        report.stringFieldsRedacted += 1
        return replacement
    }

    private static func dropSecure(
        _ value: String?,
        report: inout PromotionSanitizationReport
    ) -> String? {
        guard value?.isEmpty == false else { return value }
        report.secureValuesDropped += 1
        report.stringFieldsRedacted += 1
        return nil
    }

    private static func recordAppMetadataRedaction(
        _ value: String?,
        replacement: String?,
        report: inout PromotionSanitizationReport
    ) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        guard value != replacement else { return }
        report.appMetadataRedacted += 1
        report.stringFieldsRedacted += 1
    }

    private static func syntheticWindowTitle(app: String) -> String {
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("Synthetic ") {
            return "\(name) Window"
        }
        return "Synthetic \(name.isEmpty ? "App" : name) Window"
    }

    private static func syntheticAppNames(
        apps: [CUAppListing],
        activeWindow: CUActiveWindow?
    ) -> [Int32: String] {
        var names: [Int32: String] = [:]
        for (offset, app) in apps.enumerated() {
            names[app.pid] = "Synthetic App \(offset + 1)"
        }
        if let activeWindow, names[activeWindow.pid] == nil {
            names[activeWindow.pid] = "Synthetic App \(names.count + 1)"
        }
        return names
    }

    private static func roleLabel(_ role: String) -> String {
        switch role.lowercased() {
        case "textfield": return "text field"
        case "textarea": return "text area"
        case "searchfield": return "search field"
        case "securetextfield", "axsecuretextfield", "securefield": return "secure field"
        case "statictext", "staticrtext": return "text"
        case let other where other.isEmpty: return "element"
        case let other: return other
        }
    }

    private static func syntheticValue(role: String, index: Int) -> String {
        switch role.lowercased() {
        case "heading":
            return "Synthetic heading \(index)"
        case "statictext", "staticrtext":
            return "Synthetic on-screen text \(index)"
        case "textarea":
            return "Synthetic editor content \(index). Placeholder text replaces local capture text."
        case "textfield", "searchfield", "combobox":
            return "synthetic value \(index)"
        case "webarea":
            return "Synthetic web area content \(index)"
        default:
            return "Synthetic \(roleLabel(role)) value \(index)"
        }
    }
}
