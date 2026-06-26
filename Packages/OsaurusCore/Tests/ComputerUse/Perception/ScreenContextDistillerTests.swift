//
//  ScreenContextDistillerTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Pure-data coverage for the screen-context smart sampler. Drives the
//  distiller through `MockMacDriver` so working-app selection, the
//  Osaurus-exclusion fallback, focused-field extraction, the window list, and
//  the rendered block are all asserted without touching real Accessibility.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ScreenContextDistillerTests: XCTestCase {
    private let selfPid: Int32 = 999
    private let selfBundleId = "ai.osaurus.osaurus"

    // MARK: Fixtures

    private func safariSnapshot() -> CUSnapshot {
        CUSnapshot(
            snapshotId: 1,
            pid: 100,
            app: "Safari",
            focusedWindow: "Weather — Safari",
            tier: .ax,
            truncated: false,
            windows: [
                CUWindowSummary(id: 1, title: "Weather — Safari", focused: true, x: 0, y: 0, w: 1200, h: 800)
            ],
            elements: [
                CUElement(
                    id: "e1",
                    role: "textfield",
                    label: "Search",
                    value: "weather tomorrow",
                    placeholder: "Search or enter address",
                    windowId: 1,
                    focused: true
                ),
                CUElement(id: "e2", role: "button", label: "Go", windowId: 1),
                CUElement(id: "e3", role: "statictext", value: "Results for weather", windowId: 1),
            ],
            image: nil
        )
    }

    private func makeDriver(
        accessibility: Bool = true,
        apps: [CUAppListing],
        active: CUActiveWindow?,
        windowsByPid: [Int32: [CUWindowInfo]] = [:],
        snapshots: [Int32: [CUSnapshot]] = [:],
        focusedContent: [Int32: CUFocusedContent] = [:]
    ) -> MockMacDriver {
        MockMacDriver(
            availability: MacDriverAvailability(
                accessibility: accessibility,
                screenRecording: false,
                skyLight: false
            ),
            apps: apps,
            windowsByPid: windowsByPid,
            activeWindow: active,
            snapshots: snapshots,
            focusedContent: focusedContent
        )
    }

    /// A single-window editor-style driver (Xcode/Cursor shape): one focused
    /// window of the given size, the supplied elements, and an optional direct
    /// focused-content read.
    private func editorDriver(
        app: String,
        bundleId: String,
        title: String,
        windowW: Int = 1400,
        windowH: Int = 900,
        elements: [CUElement],
        truncated: Bool = false,
        focusedContent: CUFocusedContent? = nil
    ) -> MockMacDriver {
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: 100,
            app: app,
            focusedWindow: title,
            tier: .ax,
            truncated: truncated,
            windows: [
                CUWindowSummary(id: 1, title: title, focused: true, x: 0, y: 0, w: windowW, h: windowH)
            ],
            elements: elements,
            image: nil
        )
        return makeDriver(
            apps: [CUAppListing(pid: 100, bundleId: bundleId, name: app, active: true, hidden: false)],
            active: CUActiveWindow(pid: 100, app: app, title: title, x: 0, y: 0, w: windowW, h: windowH),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: title,
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: windowW,
                        h: windowH
                    )
                ]
            ],
            snapshots: [100: [snapshot]],
            focusedContent: focusedContent.map { [100: $0] } ?? [:]
        )
    }

    // MARK: Tests

    func testUsesFrontmostNonSelfApp() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Weather — Safari", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ]
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertTrue(snap.accessibilityGranted)
        XCTAssertEqual(snap.workingApp, "Safari")
        XCTAssertEqual(snap.workingWindowTitle, "Weather — Safari")
        XCTAssertEqual(snap.focusedElement?.role, "text field")
        XCTAssertEqual(snap.focusedElement?.value, "weather tomorrow")
        XCTAssertEqual(snap.activityGist, "In Safari — \"Weather — Safari\"; editing text field (draft present)")
        XCTAssertEqual(snap.windows.first?.app, "Safari")
        XCTAssertTrue(snap.windows.first?.frontmost ?? false)
        // Interactive chrome (the "Go" button) is dropped; real on-screen text
        // is kept, and the focused draft is not repeated in the sample.
        XCTAssertFalse(snap.sampledContents.contains("Go"))
        XCTAssertTrue(snap.sampledContents.contains("Results for weather"))
        XCTAssertFalse(snap.sampledContents.contains("weather tomorrow"))
    }

    func testFallsBackToPreferredAppWhenOsaurusIsFrontmost() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: false, hidden: false)
            ],
            // Osaurus itself is frontmost (its pid == selfPid).
            active: CUActiveWindow(pid: selfPid, app: "Osaurus", title: "Chat", x: 0, y: 0, w: 600, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ]
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: 100
        )

        XCTAssertEqual(snap.workingApp, "Safari")
        // No window is frontmost because the genuine frontmost app (Osaurus) is excluded.
        XCTAssertFalse(snap.windows.contains { $0.frontmost })
    }

    func testFallsBackToFirstVisibleAppWhenNoHint() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 200, bundleId: "com.apple.mail", name: "Mail", active: false, hidden: false),
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: false, hidden: false),
            ],
            active: CUActiveWindow(pid: selfPid, app: "Osaurus", title: "Chat", x: 0, y: 0, w: 600, h: 800),
            windowsByPid: [
                200: [
                    CUWindowInfo(
                        windowId: 9,
                        title: "Inbox",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1000,
                        h: 700
                    )
                ]
            ]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.workingApp, "Mail")
    }

    func testExcludesOsaurusOwnWindowsFromList() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false),
                // Osaurus shows up in the app list (dock-icon / .regular mode).
                CUAppListing(pid: selfPid, bundleId: selfBundleId, name: "Osaurus", active: false, hidden: false),
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Weather — Safari", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ],
                selfPid: [
                    CUWindowInfo(
                        windowId: 2,
                        title: "Osaurus Chat",
                        focused: false,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 600,
                        h: 800
                    )
                ],
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertTrue(snap.windows.allSatisfy { $0.app != "Osaurus" })
    }

    func testWindowListIsCapped() async {
        let windows = (1 ... 5).map {
            CUWindowInfo(
                windowId: $0,
                title: "Tab \($0)",
                focused: $0 == 1,
                minimized: false,
                x: 0,
                y: 0,
                w: 100,
                h: 100
            )
        }
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Tab 1", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [100: windows],
            snapshots: [100: [safariSnapshot()]]
        )

        let distiller = ScreenContextDistiller(maxWindows: 2)
        let snap = await distiller.capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.windows.count, 2)
    }

    func testRenderedBlockShape() async {
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: "Weather — Safari", x: 0, y: 0, w: 1200, h: 800),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Weather — Safari",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1200,
                        h: 800
                    )
                ]
            ],
            snapshots: [100: [safariSnapshot()]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )
        let text = snap.render()

        XCTAssertTrue(text.hasPrefix(ScreenContextSnapshot.openTag))
        XCTAssertTrue(text.hasSuffix(ScreenContextSnapshot.closeTag))
        XCTAssertTrue(text.contains("Doing: In Safari"))
        XCTAssertTrue(text.contains("Focused field: text field"))
        XCTAssertTrue(text.contains("Open windows:"))
        XCTAssertTrue(text.contains("- Safari — \"Weather — Safari\" (frontmost)"))
        XCTAssertTrue(text.contains("On screen:"))
    }

    func testNoAccessibilityYieldsEmptySnapshot() async {
        let driver = makeDriver(
            accessibility: false,
            apps: [],
            active: nil
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertFalse(snap.accessibilityGranted)
        XCTAssertTrue(snap.isEmpty)
        XCTAssertEqual(snap.render(), "")
    }

    // MARK: On-screen sampling (ranking, sanitizing, de-dup)

    /// A focused-window AX tree shaped like an Electron app (Cursor): a few real
    /// content nodes buried under toolbar/menu chrome and icon-only glyphs.
    private func cursorDriver(_ elements: [CUElement]) -> MockMacDriver {
        let title = "ScreenContextSnapshot.swift — osaurus"
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: 100,
            app: "Cursor",
            focusedWindow: title,
            tier: .ax,
            truncated: false,
            windows: [CUWindowSummary(id: 1, title: title, focused: true, x: 0, y: 0, w: 1400, h: 900)],
            elements: elements,
            image: nil
        )
        return makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.todesktop.cursor", name: "Cursor", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Cursor", title: title, x: 0, y: 0, w: 1400, h: 900),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: title,
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1400,
                        h: 900
                    )
                ]
            ],
            snapshots: [100: [snapshot]]
        )
    }

    private func sample(_ elements: [CUElement]) async -> [String] {
        await ScreenContextDistiller().capture(
            using: cursorDriver(elements),
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        ).sampledContents
    }

    func testDropsChromeAndRanksContentFirst() async {
        let sampled = await sample([
            CUElement(id: "b1", role: "button", label: "Toggle Primary Side Bar (⌘B)", windowId: 1),
            CUElement(id: "b2", role: "button", label: "Go Back (⌃-)", windowId: 1),
            CUElement(id: "m1", role: "menuitem", label: "Open Cursor Settings", windowId: 1),
            CUElement(id: "tab", role: "tab", label: "ScreenContextSnapshot.swift", windowId: 1),
            CUElement(id: "t1", role: "statictext", value: "public func render() -> String", windowId: 1),
            CUElement(id: "h1", role: "heading", label: "Outline", windowId: 1),
        ])

        // Real content survives.
        XCTAssertTrue(sampled.contains("Outline"))
        XCTAssertTrue(sampled.contains("public func render() -> String"))
        // Interactive chrome (buttons, menu items, tabs) is dropped entirely.
        XCTAssertFalse(sampled.contains { $0.contains("Toggle Primary Side Bar") })
        XCTAssertFalse(sampled.contains { $0.contains("Go Back") })
        XCTAssertFalse(sampled.contains("Open Cursor Settings"))
        XCTAssertFalse(sampled.contains("ScreenContextSnapshot.swift"))
        // Headings rank ahead of body text.
        let headingIdx = sampled.firstIndex(of: "Outline")
        let bodyIdx = sampled.firstIndex(of: "public func render() -> String")
        XCTAssertNotNil(headingIdx)
        XCTAssertNotNil(bodyIdx)
        if let headingIdx, let bodyIdx {
            XCTAssertLessThan(headingIdx, bodyIdx)
        }
    }

    func testSanitizesGlyphsAndDeduplicates() async {
        let sampled = await sample([
            // Icon-only codicon glyph (private-use area) -> renders blank.
            CUElement(id: "icon", role: "statictext", value: "\u{ea7b}", windowId: 1),
            // Whitespace-only.
            CUElement(id: "blank", role: "statictext", value: "   ", windowId: 1),
            // Keyboard-shortcut-only -> low signal.
            CUElement(id: "sc", role: "statictext", value: "⌘J", windowId: 1),
            // Zero-width-suffixed duplicate of the next item.
            CUElement(id: "zw1", role: "statictext", value: "Agents Window\u{200b}", windowId: 1),
            CUElement(id: "zw2", role: "statictext", value: "Agents Window", windowId: 1),
            CUElement(id: "real", role: "statictext", value: "Read-only background context", windowId: 1),
        ])

        // No blank / whitespace-only lines leak through.
        XCTAssertFalse(sampled.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        // Shortcut-only entry is dropped.
        XCTAssertFalse(sampled.contains("⌘J"))
        // The zero-width-suffixed pair folds into a single entry.
        XCTAssertEqual(sampled.filter { $0 == "Agents Window" }.count, 1)
        // Genuine text remains.
        XCTAssertTrue(sampled.contains("Read-only background context"))
    }

    func testRequestsContentInclusiveCapture() async {
        let driver = cursorDriver([
            CUElement(id: "t1", role: "statictext", value: "hello world", windowId: 1)
        ])
        _ = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )
        let interactiveOnly = await driver.lastCaptureInteractiveOnly
        XCTAssertEqual(interactiveOnly, false)
    }

    // MARK: Focused editor — viewport, selection, version-noise

    /// The direct focused-content read surfaces a "Viewing:" slice and a
    /// "Selected text:" line, and the Focused field line does not also dump the
    /// raw value when a viewport is present.
    func testFocusedEditorSurfacesViewportAndSelection() async {
        let viewport =
            "func gate(_ mutation: StorageMutation) throws {\n"
            + "    guard isEnabled else { return }\n"
            + "    try validate(mutation)\n}"
        let focusedContent = CUFocusedContent(
            role: "textarea",
            label: "StorageMutationGate.swift",
            placeholder: nil,
            value: "import Foundation\n\n\(viewport)\n\n// …rest of the file…",
            selectedText: "throw StorageError.gateClosed",
            viewport: viewport
        )
        let driver = editorDriver(
            app: "Xcode",
            bundleId: "com.apple.dt.Xcode",
            title: "osaurus — StorageMutationGate.swift",
            elements: [
                CUElement(
                    id: "ed",
                    role: "textarea",
                    label: "StorageMutationGate.swift",
                    value: "import Foundation …",
                    windowId: 1,
                    focused: true,
                    x: 300,
                    y: 100,
                    w: 1000,
                    h: 760
                )
            ],
            focusedContent: focusedContent
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.focusedElement?.role, "text area")
        XCTAssertEqual(snap.focusedElement?.viewing?.contains("func gate("), true)
        XCTAssertEqual(snap.focusedElement?.selectedText, "throw StorageError.gateClosed")

        let text = snap.render()
        XCTAssertTrue(text.contains("Viewing: func gate("))
        XCTAssertTrue(text.contains("Selected text: \"throw StorageError.gateClosed\""))
        // The Focused field line must not also dump the (clipped) value when a
        // viewing slice is present.
        XCTAssertFalse(text.contains("— value:"))
        // The gist stays a clean one-liner (no "; editing …" suffix).
        XCTAssertEqual(snap.activityGist, "In Xcode — \"osaurus — StorageMutationGate.swift\"")
    }

    /// A large editor/body text element outranks tiny sidebar labels, and bare
    /// dependency-version tokens (the reported Xcode noise) are dropped while a
    /// labeled version string survives.
    func testEditorBeatsPackageVersionNoise() async {
        let code =
            "import Foundation\n\nfunc gate(_ m: StorageMutation) throws { try validate(m) }"
        var elements: [CUElement] = [
            CUElement(
                id: "ed",
                role: "statictext",
                value: code,
                windowId: 1,
                x: 300,
                y: 100,
                w: 1000,
                h: 700
            ),
            CUElement(
                id: "nav",
                role: "heading",
                label: "Package Dependencies",
                windowId: 1,
                x: 0,
                y: 40,
                w: 240,
                h: 20
            ),
            // Labeled version survives (has a space — not a bare token).
            CUElement(
                id: "lang",
                role: "statictext",
                value: "Swift 5.9.1",
                windowId: 1,
                x: 20,
                y: 380,
                w: 200,
                h: 16
            ),
        ]
        let versions = ["9.15.0", "0.3.11", "1.0.0", "2.4.1", "v3.2", "5.9.0", "12.0.1"]
        for (i, v) in versions.enumerated() {
            elements.append(
                CUElement(
                    id: "v\(i)",
                    role: "statictext",
                    value: v,
                    windowId: 1,
                    x: 20,
                    y: 200 + i * 18,
                    w: 110,
                    h: 16
                )
            )
        }

        let driver = editorDriver(
            app: "Xcode",
            bundleId: "com.apple.dt.Xcode",
            title: "osaurus",
            elements: elements
        )
        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )
        let sampled = snap.sampledContents

        // The code body is sampled and leads ahead of the sidebar heading.
        XCTAssertTrue(sampled.contains { $0.contains("func gate(") }, "editor body should be sampled")
        let codeIdx = sampled.firstIndex { $0.contains("func gate(") }
        let headIdx = sampled.firstIndex { $0.contains("Package Dependencies") }
        XCTAssertNotNil(codeIdx)
        if let codeIdx, let headIdx { XCTAssertLessThan(codeIdx, headIdx) }
        // Every bare version token is dropped.
        for v in versions {
            XCTAssertFalse(sampled.contains(v), "bare version token \(v) should be dropped")
        }
        // The labeled version string survives.
        XCTAssertTrue(sampled.contains { $0.contains("Swift 5.9.1") })
    }

    /// When the bounded traversal is truncated and surfaced no editor body, a
    /// targeted text-area `find` backfills the "Viewing:" slice.
    func testTruncatedCaptureTriggersEditorFallback() async {
        let title = "osaurus — Main.swift"
        let chrome = (0 ..< 5).map {
            CUElement(
                id: "c\($0)",
                role: "statictext",
                value: "0.\($0).0",
                windowId: 1,
                x: 10,
                y: 40 + $0 * 16,
                w: 100,
                h: 14
            )
        }
        let window = CUWindowSummary(id: 1, title: title, focused: true, x: 0, y: 0, w: 1400, h: 900)
        // Capture snapshot: chrome only, and truncated (editor never reached).
        let chromeSnap = CUSnapshot(
            snapshotId: 1,
            pid: 100,
            app: "Xcode",
            focusedWindow: title,
            tier: .ax,
            truncated: true,
            windows: [window],
            elements: chrome,
            image: nil
        )
        // The fallback find() returns the editor text area.
        let editorSnap = CUSnapshot(
            snapshotId: 2,
            pid: 100,
            app: "Xcode",
            focusedWindow: title,
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(
                    id: "ed",
                    role: "textarea",
                    label: "Main.swift",
                    value: "func gate() { try run() }",
                    windowId: 1,
                    x: 300,
                    y: 100,
                    w: 1000,
                    h: 700
                )
            ],
            image: nil
        )
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.dt.Xcode", name: "Xcode", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Xcode", title: title, x: 0, y: 0, w: 1400, h: 900),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: title,
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1400,
                        h: 900
                    )
                ]
            ],
            snapshots: [100: [chromeSnap, editorSnap]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.focusedElement?.viewing?.contains("func gate()"), true)
        XCTAssertTrue(snap.render().contains("Viewing: func gate()"))
        // The bare version chrome is still dropped.
        for i in 0 ..< 5 {
            XCTAssertFalse(snap.sampledContents.contains("0.\(i).0"))
        }
    }

    /// A browser whose bounded capture returned only chrome (no readable body —
    /// the page tree sits under an `AXWebArea` the depth-first budget exhausted
    /// before) triggers the web/scroll content fallback: a targeted
    /// `find(statictext/heading/webarea)` recovers the page body, while nav
    /// chrome, ARIA booleans, and version tokens stay dropped.
    func testThinChromeTriggersWebContentFallback() async {
        let title = "Understanding macOS Accessibility — Example Blog"
        let window = CUWindowSummary(id: 1, title: title, focused: true, x: 0, y: 0, w: 1400, h: 900)
        // Capture snapshot: browser chrome only — a URL field, a button, a link.
        // Not truncated (so the editor fallback never fires) and carrying no
        // readable body (so the web fallback does).
        let chromeSnap = CUSnapshot(
            snapshotId: 1,
            pid: 100,
            app: "Safari",
            focusedWindow: title,
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(
                    id: "url",
                    role: "textfield",
                    label: "Address and search bar",
                    value: "https://example.com/blog",
                    windowId: 1,
                    x: 200,
                    y: 20,
                    w: 900,
                    h: 28
                ),
                CUElement(id: "reload", role: "button", label: "Reload", windowId: 1, x: 60, y: 20, w: 24, h: 24),
                CUElement(id: "signin", role: "link", value: "Sign in", windowId: 1, x: 1200, y: 20, w: 80, h: 24),
            ],
            image: nil
        )
        // The fallback find() returns the page body under the web area, plus the
        // chrome it must drop: a single-token nav label, an ARIA boolean, and a
        // bare version token.
        let bodySnap = CUSnapshot(
            snapshotId: 2,
            pid: 100,
            app: "Safari",
            focusedWindow: title,
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(
                    id: "h1",
                    role: "heading",
                    value: "Understanding macOS Accessibility",
                    windowId: 1,
                    x: 250,
                    y: 90,
                    w: 900,
                    h: 48
                ),
                CUElement(
                    id: "p1",
                    role: "statictext",
                    value: "The accessibility tree exposes every on-screen element so Osaurus can read it.",
                    windowId: 1,
                    x: 250,
                    y: 150,
                    w: 900,
                    h: 60
                ),
                CUElement(id: "nav", role: "statictext", value: "Home", windowId: 1, x: 20, y: 120, w: 100, h: 18),
                CUElement(id: "bool", role: "statictext", value: "true", windowId: 1, x: 20, y: 150, w: 60, h: 18),
                CUElement(
                    id: "ver",
                    role: "statictext",
                    label: "Safari version",
                    value: "16.5",
                    windowId: 1,
                    x: 20,
                    y: 180,
                    w: 100,
                    h: 18
                ),
            ],
            image: nil
        )
        let driver = makeDriver(
            apps: [
                CUAppListing(pid: 100, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            active: CUActiveWindow(pid: 100, app: "Safari", title: title, x: 0, y: 0, w: 1400, h: 900),
            windowsByPid: [
                100: [
                    CUWindowInfo(
                        windowId: 1,
                        title: title,
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1400,
                        h: 900
                    )
                ]
            ],
            snapshots: [100: [chromeSnap, bodySnap]]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        // The page body the bounded capture missed now surfaces.
        XCTAssertTrue(
            snap.sampledContents.contains { $0.contains("accessibility tree exposes every on-screen element") }
        )
        XCTAssertTrue(snap.sampledContents.contains("Understanding macOS Accessibility"))
        // Chrome stays out: single-token nav, ARIA boolean, version token, link.
        XCTAssertFalse(snap.sampledContents.contains("Home"))
        XCTAssertFalse(snap.sampledContents.contains("true"))
        XCTAssertFalse(snap.sampledContents.contains("16.5"))
        XCTAssertFalse(snap.sampledContents.contains("Sign in"))
    }

    // MARK: Behavior signals (active context + status bar)

    /// An Electron editor (Cursor) whose buffer is inaccessible still yields
    /// behavior: the title names the active file (`Active:`) and the bottom
    /// status bar's git branch surfaces (`Status:`), while the Monaco sentinel
    /// never leaks. This is the concrete Cursor improvement — the branch that
    /// the on-screen sampler drops as a single token is surfaced as behavior.
    func testEditorTitleNamesActiveFileAndStatusBarSurfacesBranch() async {
        let sentinel =
            "The editor is not accessible at this time. To enable screen "
            + "reader optimized mode, use Shift+Option+F1"
        let driver = editorDriver(
            app: "Cursor",
            bundleId: "com.todesktop.cursor",
            title: "ScreenContextDistiller.swift — osaurus",
            windowW: 1600,
            windowH: 1000,
            elements: [
                CUElement(
                    id: "ed",
                    role: "textarea",
                    label: sentinel,
                    value: sentinel,
                    windowId: 1,
                    focused: true,
                    x: 380,
                    y: 80,
                    w: 1100,
                    h: 880
                ),
                // Bottom status bar (band): git branch + formatter mode.
                CUElement(id: "branch", role: "statictext", value: "main*", windowId: 1, x: 20, y: 980, w: 50, h: 18),
                CUElement(id: "ext", role: "statictext", value: "Prettier", windowId: 1, x: 1500, y: 980, w: 60, h: 18),
                // Top-left panel label is NOT status (outside the band).
                CUElement(
                    id: "panel",
                    role: "statictext",
                    value: "Agents Window",
                    windowId: 1,
                    x: 20,
                    y: 60,
                    w: 180,
                    h: 20
                ),
            ],
            focusedContent: CUFocusedContent(role: "textarea", label: sentinel, value: sentinel, viewport: "/")
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.activeContext, ["editing ScreenContextDistiller.swift"])
        XCTAssertTrue(snap.statusSignals.contains("main*"))
        // Left-to-right status order (branch at x:20 before formatter at x:1500).
        XCTAssertEqual(snap.statusSignals, ["main*", "Prettier"])

        let text = snap.render()
        XCTAssertTrue(text.contains("Active: editing ScreenContextDistiller.swift"))
        XCTAssertTrue(text.contains("Status: main* · Prettier"))
        // The inaccessible-editor sentinel must never leak.
        XCTAssertFalse(text.contains("not accessible"))
        XCTAssertFalse(text.contains("Viewing:"))
    }

    /// A chat shell (Slack) encodes the active channel in the window title, so
    /// `Active: channel #…` surfaces even when the messages are virtualized.
    func testChatTitleSurfacesActiveChannel() async {
        let driver = editorDriver(
            app: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            title: "#engineering — Osaurus",
            windowW: 1400,
            windowH: 900,
            elements: [
                CUElement(id: "side", role: "statictext", value: "Threads", windowId: 1, x: 24, y: 120, w: 120, h: 18)
            ]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.activeContext, ["channel #engineering"])
        XCTAssertTrue(snap.render().contains("Active: channel #engineering"))
        // The single-token sidebar label stays out of the content sample.
        XCTAssertFalse(snap.sampledContents.contains("Threads"))
    }

    /// The real Slack title format ("Name (Channel) - Workspace - Slack") also
    /// surfaces the active channel — the parenthesized conversation-type suffix,
    /// not just a leading `#`.
    func testChatParenthesizedChannelTitleSurfacesActiveChannel() async {
        let driver = editorDriver(
            app: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            title: "105-osaurus (Channel) - Osaurus - Slack",
            windowW: 1400,
            windowH: 900,
            elements: [
                CUElement(id: "nav", role: "statictext", value: "Home", windowId: 1, x: 24, y: 120, w: 80, h: 18)
            ]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.activeContext, ["channel 105-osaurus"])
        XCTAssertTrue(snap.render().contains("Active: channel 105-osaurus"))
    }

    /// A labeled status control reads as "label: value"; a bottom-edge INPUT is
    /// never mistaken for status (role-gated), and a bare version token in the
    /// band is dropped (no reintroducing the version noise).
    func testStatusBarFormatsLabeledControlAndSkipsInputsAndVersions() async {
        let driver = editorDriver(
            app: "Cursor",
            bundleId: "com.todesktop.cursor",
            title: "Untitled-1 — osaurus",
            windowW: 1400,
            windowH: 900,
            elements: [
                CUElement(
                    id: "branch",
                    role: "button",
                    label: "Source Control",
                    value: "feature/ax-readiness",
                    windowId: 1,
                    x: 20,
                    y: 884,
                    w: 160,
                    h: 22
                ),
                // A bottom-edge composer (input role) is not a status signal.
                CUElement(
                    id: "composer",
                    role: "textfield",
                    label: "Message",
                    value: "",
                    windowId: 1,
                    x: 300,
                    y: 880,
                    w: 760,
                    h: 24
                ),
                // A bare version token in the band is dropped.
                CUElement(id: "ver", role: "statictext", value: "1.96.2", windowId: 1, x: 1200, y: 884, w: 70, h: 18),
            ]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertEqual(snap.statusSignals, ["Source Control: feature/ax-readiness"])
        XCTAssertFalse(snap.statusSignals.contains { $0.contains("Message") })
        XCTAssertFalse(snap.statusSignals.contains("1.96.2"))
    }

    /// A plain document/site title yields no `Active:` context (no guessed,
    /// possibly-wrong label) and nothing outside the status band becomes status.
    func testPlainTitleYieldsNoActiveContextOrStatus() async {
        let driver = editorDriver(
            app: "Safari",
            bundleId: "com.apple.Safari",
            title: "Weather — Safari",
            windowW: 1200,
            windowH: 800,
            elements: [
                CUElement(
                    id: "body",
                    role: "statictext",
                    value: "Tomorrow will be sunny with light winds across the bay.",
                    windowId: 1,
                    x: 250,
                    y: 150,
                    w: 700,
                    h: 400
                )
            ]
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertTrue(snap.activeContext.isEmpty)
        XCTAssertTrue(snap.statusSignals.isEmpty)
        let text = snap.render()
        XCTAssertFalse(text.contains("Active:"))
        XCTAssertFalse(text.contains("Status:"))
    }

    // MARK: Secure-field guard

    /// A focused secure text field never surfaces its value/selection/viewport
    /// through the DIRECT focused-content read — even if the driver somehow
    /// reads one — so a password can't reach the model via screen context.
    func testSecureFieldDirectReadNeverSurfacesValue() async {
        let secret = "hunter2-topsecret"
        let driver = editorDriver(
            app: "Safari",
            bundleId: "com.apple.Safari",
            title: "Sign in — Example",
            elements: [
                CUElement(
                    id: "pw",
                    role: "securetextfield",
                    label: "Password",
                    value: secret,
                    windowId: 1,
                    focused: true
                )
            ],
            focusedContent: CUFocusedContent(
                role: "securetextfield",
                label: "Password",
                value: secret,
                selectedText: secret,
                viewport: secret
            )
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertNil(snap.focusedElement?.value)
        XCTAssertNil(snap.focusedElement?.selectedText)
        XCTAssertNil(snap.focusedElement?.viewing)
        // The label still surfaces (it's not secret) so the field is represented.
        XCTAssertEqual(snap.focusedElement?.label, "Password")
        XCTAssertFalse(snap.render().contains(secret))
    }

    /// Same guard on the breadth-limited TRAVERSAL fallback (no direct read): a
    /// focused secure field surfaces only its role/label, never its value.
    func testSecureFieldTraversalFallbackNeverSurfacesValue() async {
        let secret = "p@ssw0rd-do-not-leak"
        let driver = editorDriver(
            app: "Safari",
            bundleId: "com.apple.Safari",
            title: "Sign in — Example",
            elements: [
                CUElement(
                    id: "pw",
                    role: "axsecuretextfield",
                    label: "Password",
                    value: secret,
                    windowId: 1,
                    focused: true
                )
            ],
            focusedContent: nil
        )

        let snap = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: selfPid,
            selfBundleId: selfBundleId,
            preferredPid: nil
        )

        XCTAssertNil(snap.focusedElement?.value)
        XCTAssertNil(snap.focusedElement?.selectedText)
        XCTAssertFalse(snap.render().contains(secret))
        XCTAssertFalse(snap.sampledContents.contains { $0.contains(secret) })
    }
}
