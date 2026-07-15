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
    /// Max status-bar signals surfaced (git branch, problems, language, …).
    public var maxStatusSignals: Int
    /// Max chars kept for the focused field's value/draft and selection.
    public var maxValueChars: Int
    /// Max chars kept for the focused editor's "viewing" slice and large
    /// on-screen text bodies (a multi-line code/article window).
    public var maxViewingChars: Int
    /// Max chars kept per sampled on-screen item / window title.
    public var maxItemChars: Int

    public init(
        maxWindows: Int = 12,
        maxAppsToScan: Int = 12,
        maxContentItems: Int = 16,
        maxStatusSignals: Int = 6,
        maxValueChars: Int = 280,
        maxViewingChars: Int = 600,
        maxItemChars: Int = 140
    ) {
        self.maxWindows = maxWindows
        self.maxAppsToScan = maxAppsToScan
        self.maxContentItems = maxContentItems
        self.maxStatusSignals = maxStatusSignals
        self.maxValueChars = maxValueChars
        self.maxViewingChars = maxViewingChars
        self.maxItemChars = maxItemChars
    }

    /// Area (width * height) of a rectangle reported by the accessibility API,
    /// clamped so the multiply can't overflow `Int` and trap. AX can return
    /// absurd or garbage dimensions for off-screen or misreporting elements, and
    /// the raw `w * h` (and the downstream `area * 100` comparison) would crash
    /// on overflow. Clamping each side keeps the value well within `Int` while
    /// preserving the relative ordering these areas are used for.
    private static func clampedArea(_ w: Int, _ h: Int) -> Int {
        let side = 1_000_000
        return min(max(0, w), side) * min(max(0, h), side)
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
        var activeContext: [String] = []
        var statusSignals: [String] = []
        var workingWindowTitle = working?.windowTitle

        if let working {
            // `interactiveOnly: false` so passive content roles (statictext,
            // headings, …) come through — they're the real "what's on screen"
            // signal, not the buttons/menus an interactive-only tree returns.
            // The larger element budget gives that content room past the chrome
            // that tends to sit at the top of the tree.
            let snap = await driver.capture(
                pid: working.pid,
                tier: .ax,
                windowId: nil,
                maxElements: 350,
                focusedWindowOnly: true,
                interactiveOnly: false
            )
            if let title = snap.focusedWindow, !title.isEmpty {
                workingWindowTitle = title
            }

            // Primary "what I'm looking at" signal: a direct read of the focused
            // UI element, independent of the bounded traversal above (which
            // chrome-heavy apps can exhaust before reaching the editor).
            let directFocus = await driver.focusedContent(pid: working.pid)
            focused = focusedElement(direct: directFocus, snapshot: snap)

            // Reliability fallback: when the traversal was truncated and still
            // surfaced no real editor body, ask for the focused window's text
            // areas explicitly — Xcode/Cursor bury the AXTextArea deep under the
            // navigator/inspector. Gated on `truncated` so a fully-captured tree
            // (no editor genuinely present) never pays the extra read.
            var contentElements = snap.elements
            if snap.truncated, !hasSizableTextArea(snap.elements) {
                let editor = await driver.find(
                    pid: working.pid,
                    text: nil,
                    roles: ["textarea"],
                    windowId: snap.focusedWindowId,
                    enabledOnly: false,
                    limit: 6
                )
                contentElements += editor.elements
                focused = backfillViewing(focused, fromEditor: editor.elements)
            }

            // Web / scroll content fallback: browsers expose page text only under
            // an `AXWebArea`, and virtualized lists (Slack messages, long docs)
            // render rows deep under a scroll area — both of which a depth-first,
            // budgeted traversal can exhaust on chrome before reaching. When the
            // captured tree still carries no readable body, ask for content roles
            // in the focused window explicitly; the targeted find reaches the web
            // area / rows the ambient pass missed.
            if !hasReadableBody(contentElements) {
                let body = await driver.find(
                    pid: working.pid,
                    text: nil,
                    roles: ["statictext", "heading", "webarea"],
                    windowId: snap.focusedWindowId,
                    enabledOnly: false,
                    limit: 60
                )
                contentElements += body.elements
            }

            // Behavioral signals from the reliable, interactive/titled AX layer
            // (the same surface Computer Use acts on): structured context from
            // the window title, and status-bar indicators the content sampler
            // drops as chrome. Computed before sampling so their tokens can be
            // de-duped out of the "On screen:" sample.
            activeContext = parseActiveContext(workingWindowTitle)
            statusSignals = statusBarSignals(
                elements: contentElements,
                focusedWindow: focusedWindowSummary(in: snap)
            )

            sampled = sampleContents(
                elements: contentElements,
                focusedWindow: focusedWindowSummary(in: snap),
                windowTitle: workingWindowTitle,
                focused: focused,
                statusSignals: statusSignals
            )
        }

        return ScreenContextSnapshot(
            accessibilityGranted: true,
            workingApp: working?.name,
            workingWindowTitle: workingWindowTitle,
            activityGist: buildGist(app: working?.name, windowTitle: workingWindowTitle, focused: focused),
            focusedElement: focused,
            activeContext: activeContext,
            statusSignals: statusSignals,
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
            !identity.owns(match) {
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

    /// Build the focused element, preferring the direct AX read (which carries
    /// the selection and a viewport slice) and falling back to the traversal's
    /// focused element when the direct read is unavailable or empty.
    private func focusedElement(
        direct: CUFocusedContent?,
        snapshot: CUSnapshot
    ) -> ScreenContextSnapshot.FocusedElement? {
        if let direct {
            // Secure fields: never surface value/selection/viewport even if the
            // driver somehow read one (it shouldn't). Defense-in-depth so a
            // password never reaches the model via screen context.
            let isSecure = CUSecureFieldRole.contains(direct.role)
            let viewing = isSecure ? nil : contentValue(direct.viewport, limit: maxViewingChars)
            let value = isSecure ? nil : contentValue(direct.value, limit: maxValueChars)
            let selected = isSecure ? nil : contentValue(direct.selectedText, limit: maxValueChars)
            let label = labelValue(direct.label, limit: maxItemChars)
            let placeholder = labelValue(direct.placeholder, limit: maxItemChars)
            if viewing != nil || value != nil || selected != nil || label != nil
                || placeholder != nil {
                return ScreenContextSnapshot.FocusedElement(
                    role: friendlyRole(direct.role),
                    label: label,
                    placeholder: placeholder,
                    value: value,
                    selectedText: selected,
                    viewing: viewing
                )
            }
            // The direct read existed but carried only a sentinel / chrome (e.g.
            // Monaco's "editor is not accessible" label, a lone "/" viewport). For
            // an editor/input role, surface just the bare role — the user is
            // typing here, we simply can't read it — instead of dumping the junk.
            if Self.rawInputRoles.contains(direct.role.lowercased()) {
                return ScreenContextSnapshot.FocusedElement(
                    role: friendlyRole(direct.role),
                    label: nil,
                    placeholder: nil,
                    value: nil,
                    selectedText: nil,
                    viewing: nil
                )
            }
        }

        guard let element = snapshot.elements.first(where: { $0.focused }) else { return nil }
        // Same secure-field guard on the breadth-limited traversal fallback: a
        // focused password field surfaces only its role/label, never its value.
        let isSecure = CUSecureFieldRole.contains(element.role)
        let value = isSecure ? nil : contentValue(element.value, limit: maxValueChars)
        let selected = isSecure ? nil : contentValue(element.selectedText, limit: maxValueChars)
        let label = labelValue(element.label, limit: maxItemChars)
        let placeholder = labelValue(element.placeholder, limit: maxItemChars)
        if value == nil, selected == nil, label == nil, placeholder == nil,
            !Self.rawInputRoles.contains(element.role.lowercased()) {
            return nil
        }
        return ScreenContextSnapshot.FocusedElement(
            role: friendlyRole(element.role),
            label: label,
            placeholder: placeholder,
            value: value,
            selectedText: selected,
            viewing: nil
        )
    }

    /// The focused window's summary (for area-aware ranking), falling back to the
    /// largest window when none is flagged focused.
    private func focusedWindowSummary(in snapshot: CUSnapshot) -> CUWindowSummary? {
        snapshot.windows.first(where: { $0.focused })
            ?? snapshot.windows.max(by: { Self.clampedArea($0.w, $0.h) < Self.clampedArea($1.w, $1.h) })
    }

    /// True when the elements already contain a text area carrying real content,
    /// so the editor-body fallback `find` isn't needed.
    private func hasSizableTextArea(_ elements: [CUElement]) -> Bool {
        elements.contains { element in
            element.role.lowercased() == "textarea"
                && (cleaned(element.value, limit: 8)?.isEmpty == false)
        }
    }

    /// True when the captured tree already carries a readable on-screen body —
    /// one substantial text block, or several medium ones. Used to decide whether
    /// the web/scroll content fallback `find` is worth issuing: browser pages and
    /// virtualized lists otherwise come back as just chrome (address bar, nav,
    /// toolbar buttons) with no real content.
    private func hasReadableBody(_ elements: [CUElement]) -> Bool {
        let bodyRoles: Set<String> = [
            "statictext", "staticrtext", "heading", "webarea", "textarea",
        ]
        // One substantial block (a sentence/paragraph) is enough on its own;
        // otherwise it takes several medium lines to count as a real body.
        let substantialChars = 40
        let mediumChars = 12
        let mediumBlocksNeeded = 4
        var mediumBlocks = 0
        for element in elements where bodyRoles.contains(element.role.lowercased()) {
            let text = element.value ?? element.label ?? ""
            let length = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            if length >= substantialChars { return true }
            if length >= mediumChars {
                mediumBlocks += 1
                if mediumBlocks >= mediumBlocksNeeded { return true }
            }
        }
        return false
    }

    /// When the focused element has no viewing/value yet, derive a viewing slice
    /// from the largest editor text area found by the fallback search.
    private func backfillViewing(
        _ focused: ScreenContextSnapshot.FocusedElement?,
        fromEditor elements: [CUElement]
    ) -> ScreenContextSnapshot.FocusedElement? {
        let alreadyHasBody = focused?.viewing != nil || (focused?.value?.isEmpty == false)
        if alreadyHasBody { return focused }

        let largest =
            elements
            .filter { $0.role.lowercased() == "textarea" }
            .max(by: { Self.clampedArea($0.w, $0.h) < Self.clampedArea($1.w, $1.h) })
        guard let largest, let viewing = cleaned(largest.value, limit: maxViewingChars) else {
            return focused
        }

        if let focused {
            return ScreenContextSnapshot.FocusedElement(
                role: focused.role,
                label: focused.label,
                placeholder: focused.placeholder,
                value: focused.value,
                selectedText: focused.selectedText,
                viewing: viewing
            )
        }
        return ScreenContextSnapshot.FocusedElement(
            role: friendlyRole(largest.role),
            label: cleaned(largest.label, limit: maxItemChars),
            placeholder: nil,
            value: nil,
            selectedText: cleaned(largest.selectedText, limit: maxValueChars),
            viewing: viewing
        )
    }

    private func sampleContents(
        elements: [CUElement],
        focusedWindow: CUWindowSummary?,
        windowTitle: String?,
        focused: ScreenContextSnapshot.FocusedElement?,
        statusSignals: [String]
    ) -> [String] {
        // Seed the de-dup set with text we've already surfaced (window title +
        // focused draft / selection / viewing + the status-bar signals) so the
        // sample only adds new signal. Keys are the sanitized, case-folded form
        // so a trailing zero-width char can't slip a near-duplicate through.
        var seen = Set(
            ([windowTitle, focused?.value, focused?.viewing, focused?.label, focused?.selectedText]
                .compactMap { $0 } + statusSignals)
                .map(dedupKey)
        )

        let windowArea = focusedWindow.map { Self.clampedArea($0.w, $0.h) } ?? 0

        // Rank candidates so genuine content leads: the main editor/body first,
        // then headings, then body text, then filled inputs — lower tiers only
        // fill leftover budget. Within a tier, larger/more central elements beat
        // tiny chrome; document order is the final tiebreak (`sort` isn't
        // stable).
        var ranked: [(rank: Int, weight: Int, index: Int, text: String)] = []
        for (index, element) in elements.enumerated() {
            // The focused field is already surfaced as "Focused field:" /
            // "Viewing:"; don't repeat it here.
            if element.focused { continue }
            guard let item = sampledItem(for: element, windowArea: windowArea),
                !isLowSignal(item.text),
                !isBooleanToken(item.text)
            else { continue }
            ranked.append((rank: item.rank.rawValue, weight: item.weight, index: index, text: item.text))
        }
        ranked.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.index < $1.index
        }

        // When the focused element already carries the main signal (a viewing
        // slice or a draft/selection), "On screen:" is secondary — keep it short
        // so the block stays focused on what the user is actually doing. With no
        // focused content (e.g. reading a doc), it's the primary signal, so allow
        // the full budget.
        let hasStrongFocus =
            focused?.viewing != nil
            || (focused?.value?.isEmpty == false)
            || (focused?.selectedText?.isEmpty == false)
        let cap = hasStrongFocus ? min(maxContentItems, 6) : maxContentItems

        var items: [String] = []
        for candidate in ranked {
            if items.count >= cap { break }
            let key = dedupKey(candidate.text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            items.append(candidate.text)
        }
        return items
    }

    /// On-screen content tiers, highest priority first.
    private enum ContentRank: Int {
        /// The focused/largest editor text area or a large document text block —
        /// the real "what's on screen" body that chrome must not outrank.
        case mainContent
        case heading
        case bodyText
        case input
    }

    /// One ranked sample line for an element (with an area weight for
    /// within-tier ordering), or nil for UI chrome / empty / noise elements.
    private func sampledItem(
        for element: CUElement,
        windowArea: Int
    ) -> (text: String, rank: ContentRank, weight: Int)? {
        let label = cleaned(element.label, limit: maxItemChars)
        let area = Self.clampedArea(element.w, element.h)
        // "Large" = occupies a meaningful fraction of the focused window, the
        // signature of a document/editor body vs. a sidebar label.
        let isLarge = windowArea > 0 && area * 100 >= windowArea * 12

        switch element.role.lowercased() {
        case "heading":
            guard let text = cleaned(element.value, limit: maxItemChars) ?? label else { return nil }
            if looksLikeBareToken(text) { return nil }
            return (text, .heading, area)
        case "statictext", "staticrtext":
            // Big text blocks are the document body (article/code); tiny ones are
            // chrome/labels (e.g. Xcode's navigator package list).
            let limit = isLarge ? maxViewingChars : maxItemChars
            guard let text = cleaned(element.value, limit: limit) ?? label else { return nil }
            if looksLikeBareToken(text) || looksLikeHashToken(text) { return nil }
            // A small static-text that's a single token is sidebar / status-bar /
            // navigator chrome (package & file names, branch labels, commit
            // hashes) — not the content the user is reading. Real reading content
            // (paragraphs, code lines, chat messages) spans multiple words. Large
            // blocks are always kept: they're the document/editor body.
            if !isLarge, isSingleToken(text) { return nil }
            return (text, isLarge ? .mainContent : .bodyText, area)
        case "textarea":
            // A non-focused text area with content is the editor body.
            let limit = isLarge ? maxViewingChars : maxValueChars
            guard let value = cleaned(element.value, limit: limit) else { return nil }
            if looksLikeBareToken(value) { return nil }
            return (label.map { "\($0): \(value)" } ?? value, .mainContent, area)
        case "securetextfield":
            guard let label else { return nil }
            return ("\(label): (hidden)", .input, area)
        case "textfield", "searchfield", "combobox":
            // Non-focused inputs only matter when they already hold something.
            guard let value = cleaned(element.value, limit: maxValueChars) else { return nil }
            if looksLikeBareToken(value) || looksLikeHashToken(value) { return nil }
            // A labeled field carries context ("Address and search bar: <url>") —
            // keep it. An UNLABELED single-token value is navigator/sidebar chrome
            // (Xcode's editable file-name rows are `textfield`s), not content.
            if let label { return ("\(label): \(value)", .input, area) }
            if isSingleToken(value) { return nil }
            return (value, .input, area)
        default:
            // Interactive chrome (buttons, links, menu items, tabs, …) and
            // structural roles carry no real "what's on screen" signal.
            return nil
        }
    }

    /// True for a standalone token that is only digits and dots (optionally a
    /// leading `v`), e.g. `9.15.0`, `0.3.11`, `v1.2`, `12` — the bare
    /// dependency-version noise from package sidebars. Labeled values
    /// ("Swift 5.9") and anything with a space survive.
    private func looksLikeBareToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        var body = Substring(trimmed)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        guard !body.isEmpty else { return false }
        let onlyDigitsAndDots = body.allSatisfy { $0.isNumber || $0 == "." }
        let hasDigit = body.contains { $0.isNumber }
        return onlyDigitsAndDots && hasDigit
    }

    /// True for a bare hex-ish token of 7–40 chars containing a digit — a git
    /// short/long SHA like `d35c074`, the kind of identifier that litters IDE
    /// status bars and blame gutters.
    private func looksLikeHashToken(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 7, t.count <= 40, !t.contains(" ") else { return false }
        let isHex = t.allSatisfy { $0.isHexDigit }
        let hasDigit = t.contains { $0.isNumber }
        return isHex && hasDigit
    }

    /// True for a single whitespace-free token (e.g. `OsaurusCore`,
    /// `swift-numerics`, `main*`, `Prettier`). Multi-word strings — sentences,
    /// chat messages, code lines — have internal whitespace and survive.
    private func isSingleToken(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).contains(" ")
    }

    /// True for a standalone `true`/`false` — the ARIA/state boolean that web
    /// accessibility trees leak as on-screen text (e.g. a checkbox's value
    /// rendered as a static string). Never real content.
    private func isBooleanToken(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return t == "true" || t == "false"
    }

    /// `cleaned`, but also nil for AX "unavailable" placeholders and low-signal
    /// junk — the strings Electron editors expose instead of real content.
    private func contentValue(_ text: String?, limit: Int) -> String? {
        guard let value = cleaned(text, limit: limit) else { return nil }
        if isUnavailablePlaceholder(value) || isLowSignal(value) { return nil }
        return value
    }

    /// `cleaned` for a label/placeholder: drops the "unavailable" sentinel but
    /// keeps short labels (a one-word field name is still a useful signal).
    private func labelValue(_ text: String?, limit: Int) -> String? {
        guard let value = cleaned(text, limit: limit) else { return nil }
        return isUnavailablePlaceholder(value) ? nil : value
    }

    /// AX placeholders that carry no real content — e.g. Monaco / VS Code's
    /// "The editor is not accessible at this time. To enable screen reader
    /// optimized mode…" sentinel that Electron editors expose instead of the
    /// buffer. Matched loosely so wording variants are covered.
    private func isUnavailablePlaceholder(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("is not accessible")
            || lowered.contains("screen reader optimized")
    }

    /// Raw (pre-`friendlyRole`) AX roles for text inputs / editors. Used to keep
    /// a "Focused field: <role>" line even when the content is unreadable.
    private static let rawInputRoles: Set<String> = [
        "textfield", "textarea", "searchfield", "securetextfield", "combobox",
    ]

    /// Characters that carry no signal alone: keyboard-shortcut glyphs plus the
    /// brackets/spaces that wrap them in hints like "(⌘J)". A string made only
    /// of these is chrome, not content.
    private static let decorativeCharacters: Set<Character> = [
        "⌘", "⌥", "⌃", "⇧", "↩", "⏎", "⌫", "⌦", "⎋", "⇥", "⇪", "⌅", "␣",
        "(", ")", "[", "]", "{", "}", " ",
    ]

    /// True for items too short or shortcut-only to be worth surfacing.
    private func isLowSignal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 { return true }
        return trimmed.filter { !Self.decorativeCharacters.contains($0) }.count < 2
    }

    /// Folded key for de-dup: sanitized, then case-folded.
    private func dedupKey(_ text: String) -> String {
        normalize(text).lowercased()
    }

    // MARK: - Behavior signals

    /// High-precision "what context is the user in" parsed from the working
    /// window title — the channel they're in (`#…`) and the file they're editing
    /// (`Foo.swift`). Only unambiguous patterns produce a signal, so a plain
    /// document/site title (e.g. "Weather — Safari") yields nothing rather than a
    /// guessed, possibly-wrong label. App shells encode this in the title
    /// reliably (Slack: "#engineering — Osaurus"; editors: "File.swift — folder")
    /// even when the body content is virtualized/inaccessible.
    private func parseActiveContext(_ title: String?) -> [String] {
        guard let title = cleaned(title, limit: maxItemChars) else { return [] }
        var out: [String] = []
        for segment in titleSegments(title) {
            let token = stripLeadingMarkers(segment)
            guard !token.isEmpty else { continue }
            if token.hasPrefix("#"), token.count > 1, !token.contains(" ") {
                out.append("channel \(token)")
            } else if let conversation = conversationContext(token) {
                out.append(conversation)
            } else if isFileName(token) {
                out.append("editing \(token)")
            }
            if out.count >= 2 { break }
        }
        return out
    }

    /// A chat-app conversation title segment — Slack/Teams style "Name (Channel)"
    /// / "Name (DM)" / "Name (Thread)". Returns "channel <name>" for channel
    /// types (the common case) and "<name> (<type>)" for DMs/threads, or nil when
    /// the trailing parenthetical isn't a known conversation type.
    private func conversationContext(_ segment: String) -> String? {
        guard segment.hasSuffix(")"), let open = segment.lastIndex(of: "(") else {
            return nil
        }
        let inner = segment.index(after: open)
        let close = segment.index(before: segment.endIndex)
        guard inner < close else { return nil }
        let type = segment[inner ..< close].trimmingCharacters(in: .whitespaces)
        let name = segment[segment.startIndex ..< open].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !type.isEmpty else { return nil }
        let typeLower = type.lowercased()
        guard Self.conversationTypes.contains(typeLower) else { return nil }
        return typeLower.contains("channel") ? "channel \(name)" : "\(name) (\(type))"
    }

    /// Split a window title on the dash/bullet/pipe separators apps use between
    /// the active item and its container ("File.swift — folder", "Page · Site").
    private func titleSegments(_ title: String) -> [String] {
        var segments = [title]
        for separator in [" — ", " – ", " - ", " · ", " • ", " | "] {
            segments = segments.flatMap { $0.components(separatedBy: separator) }
        }
        return
            segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Drop leading "modified"/bullet markers an editor prefixes to a dirty file
    /// title (e.g. "● Foo.swift") so the bare name classifies cleanly.
    private func stripLeadingMarkers(_ text: String) -> String {
        var body = Substring(text)
        while let first = body.first, Self.leadingTitleMarkers.contains(first) || first == " " {
            body = body.dropFirst()
        }
        return String(body)
    }

    /// True for a bare file name (`Distiller.swift`, `index.tsx`, `Makefile.am`)
    /// — a single token with a short alphabetic extension. Excludes web hosts
    /// (`example.com`) via a small TLD guard so a site title isn't read as a
    /// file, and bare version tokens (`1.2.3`) which have no alphabetic body.
    private func isFileName(_ text: String) -> Bool {
        guard !text.contains(" "), text.contains(".") else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let ext = parts.last else { return false }
        let extension_ = ext.lowercased()
        guard (1 ... 5).contains(extension_.count), extension_.allSatisfy(\.isLetter) else {
            return false
        }
        if Self.webHostSuffixes.contains(String(extension_)) { return false }
        let base = parts.dropLast().joined(separator: ".")
        return base.contains(where: { $0.isLetter })
    }

    /// Ambient status indicators read from the focused window's status-bar strip
    /// (the thin band along the bottom edge): the git branch, problems count,
    /// language/encoding, cursor position — the labeled controls that name the
    /// user's working state. These are short tokens the on-screen content sampler
    /// intentionally drops as chrome, so we surface them here, where they read as
    /// behavior. Geometry-gated on a real bottom-edge frame, so it's inert when
    /// the tree carries no frames and never mistakes the editor body (a tall,
    /// centered element) for a status item.
    private func statusBarSignals(
        elements: [CUElement],
        focusedWindow: CUWindowSummary?
    ) -> [String] {
        guard let window = focusedWindow, window.h > 0 else { return [] }
        let windowBottom = window.y + window.h
        let bandHeight = max(28, window.h * 6 / 100)
        let bandTop = windowBottom - bandHeight

        var found: [(x: Int, text: String)] = []
        var seen = Set<String>()
        for element in elements where !element.focused {
            guard Self.statusRoles.contains(element.role.lowercased()) else { continue }
            // A status item is short, thin, and hugs the bottom edge.
            guard element.h > 0, element.h <= 44 else { continue }
            let centerY = element.y + element.h / 2
            guard centerY >= bandTop, centerY <= windowBottom + 4 else { continue }
            guard let token = statusToken(for: element) else { continue }
            let key = dedupKey(token)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            found.append((x: element.x, text: token))
        }
        // Left-to-right, the order a status bar reads in.
        found.sort { $0.x < $1.x }
        return Array(found.prefix(maxStatusSignals).map(\.text))
    }

    /// One status-bar token for an element, or nil for empty / pure-noise /
    /// chrome items. Static text renders the state directly in `value`
    /// ("main*", "Prettier", "Ln 42, Col 8"); a control's accessible `label` is
    /// its status summary, and when it also carries a distinct `value` the pair
    /// reads as "label: value". Filtered so the status line carries the user's
    /// working state — not button action hints, generic feature buttons, or the
    /// version/commit noise the content sampler already removes.
    private func statusToken(for element: CUElement) -> String? {
        let value = cleaned(element.value, limit: maxItemChars)
        let label = cleaned(element.label, limit: maxItemChars)
        let role = element.role.lowercased()
        let isStatic = role == "statictext" || role == "staticrtext"

        let token: String?
        if isStatic {
            token = value ?? label
        } else if let label, let value, label != value {
            token = "\(label): \(value)"
        } else {
            token = label ?? value
        }
        guard let status = token else { return nil }

        // Button-action affordances ("… (Git) - Checkout Branch/Tag…", "git blame
        // - No info about the current line") are control hints, not state.
        if status.contains("…") || status.contains("...") || status.contains(" - ") {
            return nil
        }
        // Pure noise: versions, commit hashes, ARIA booleans, AX sentinels, bare
        // counts, icon-only / shortcut glyphs.
        if isLowSignal(status) || isBooleanToken(status) || looksLikeBareToken(status)
            || looksLikeHashToken(status) || isUnavailablePlaceholder(status) {
            return nil
        }
        // A generic feature button with no state ("remote", "Notifications",
        // "Cursor Tab") is chrome, not behavior — require a state indicator for
        // non-static controls. Static text in the band is always the live state.
        if !isStatic, !hasStateIndicator(status) {
            return nil
        }
        return status
    }

    /// True when a control's label carries actual state — a value separator
    /// (`Workspace: osaurus`), a branch dirty/slash marker (`main*`,
    /// `feature/x`), or a digit (problem/position counts) — versus a bare
    /// feature name.
    private func hasStateIndicator(_ text: String) -> Bool {
        text.contains { $0 == ":" || $0 == "*" || $0 == "/" || $0.isNumber }
    }

    /// Extension suffixes that are really web TLDs, used to keep `isFileName`
    /// from reading a host (`example.com`) in a browser title as a file.
    private static let webHostSuffixes: Set<String> = [
        "com", "org", "net", "io", "dev", "co", "ai", "app", "gov", "edu", "me",
    ]

    /// Leading glyphs an editor prefixes to a modified/dirty file title.
    private static let leadingTitleMarkers: Set<Character> = ["●", "•", "◦", "*", "∙", "·"]

    /// Trailing parenthetical types a chat app appends to a conversation title
    /// ("105-osaurus (Channel)", "Alice (DM)"), used to read the active channel
    /// from the window title.
    private static let conversationTypes: Set<String> = [
        "channel", "private channel", "private", "dm", "direct message",
        "direct messages", "group dm", "group message", "thread", "huddle", "canvas",
    ]

    /// Roles a status-bar item can take. Inputs / web areas / scroll areas are
    /// excluded so a bottom-edge composer or page body is never read as status.
    private static let statusRoles: Set<String> = [
        "statictext", "staticrtext", "button", "menubutton", "popupbutton",
        "checkbox", "radiobutton", "tab",
    ]

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

        // A viewing slice already says what the user is looking at on the
        // dedicated "Viewing:" line; keep "Doing:" to app + window so it stays a
        // clean one-liner (matches the editor-context shape).
        if focused.viewing != nil { return gist }

        // Nothing readable in the focused element (e.g. an inaccessible Monaco
        // editor surfaced as a bare role): the app + window already says enough,
        // so don't assert an "(empty)"/"(draft)" state we can't actually confirm.
        let hasFocusSignal =
            (focused.value?.isEmpty == false)
            || (focused.selectedText?.isEmpty == false)
            || (focused.label?.isEmpty == false)
            || (focused.placeholder?.isEmpty == false)
        guard hasFocusSignal else { return gist }

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

    /// Sanitize on-screen text: drop non-printing scalars and collapse every run
    /// of whitespace/newlines into single spaces. Stripping the non-printing
    /// scalars is what kills the blank `- ` lines (icon-only / codicon buttons)
    /// and folds `"Agents Window\u{200b}"` into `"Agents Window"` so de-dup works.
    private func normalize(_ text: String) -> String {
        let printable = String.UnicodeScalarView(text.unicodeScalars.filter(Self.isPrintable))
        return String(printable).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `normalize`, then truncate to `limit` with an ellipsis.
    private func clean(_ text: String, limit: Int) -> String {
        let normalized = normalize(text)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Scalars worth keeping when sanitizing on-screen text. Whitespace is kept
    /// so `normalize` can collapse it; control (Cc), format/zero-width (Cf),
    /// private-use icon glyphs (Co), surrogate (Cs), unassigned, and explicit
    /// line/paragraph separators are dropped because they render blank or defeat
    /// de-dup.
    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned,
            .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
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
