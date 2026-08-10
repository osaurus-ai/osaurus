//
//  BrowserSupportTests.swift
//  OsaurusCore — Native Browser Use
//
//  Ports the deterministic (non-WebKit) plugin tests: the selector/JS escape
//  helpers (EscapeSelectorTests), the snapshot formatter across detail levels
//  (FormatSnapshotTests), and the login-redirect heuristic. These pin
//  agent-facing output parity with the retired `osaurus.browser` plugin.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Selector / JS escaping

@Suite struct BrowserEscapeSelectorTests {

    @Test func passesThroughOrdinarySelectors() {
        #expect(browserEscapeSelector("button.primary") == "button.primary")
        #expect(
            browserEscapeSelector("#login-form input[name=email]")
                == "#login-form input[name=email]")
    }

    @Test func escapesSingleQuotes() {
        #expect(browserEscapeSelector("a[title='hi']") == #"a[title=\'hi\']"#)
    }

    @Test func escapesBackslash() {
        // input: a\b → output: a\\b (so the JS literal sees a single backslash)
        #expect(browserEscapeSelector(#"a\b"#) == #"a\\b"#)
    }

    @Test func backslashIsEscapedBeforeQuote() {
        // Order matters: if backslash were escaped after the quote, "a'" would
        // become a\\' instead of a\'. Pin the order so a regression can't
        // sneak back in (the pre-2.0.0 plugin bug).
        #expect(browserEscapeSelector("a'") == #"a\'"#)
    }

    @Test func escapesNewlinesAndTabs() {
        #expect(browserEscapeSelector("a\nb") == "a\\nb")
        #expect(browserEscapeSelector("a\tb") == "a\\tb")
        #expect(browserEscapeSelector("a\rb") == "a\\rb")
    }

    @Test func emptyStringStaysEmpty() {
        #expect(browserEscapeSelector("") == "")
    }

    @Test func jsonEscapeHandlesQuotesAndControlCharacters() {
        #expect(browserEscapeJSON(#"say "hi""#) == #"say \"hi\""#)
        #expect(browserEscapeJSON("a\\b") == #"a\\b"#)
        #expect(browserEscapeJSON("line1\nline2") == "line1\\nline2")
    }
}

// MARK: - Detail level parsing

@Suite struct BrowserDetailLevelTests {

    @Test func parsesKnownLevels() {
        #expect(BrowserDetailLevel.parse("none", default: .compact) == .none)
        #expect(BrowserDetailLevel.parse("compact", default: .standard) == .compact)
        #expect(BrowserDetailLevel.parse("standard", default: .compact) == .standard)
        #expect(BrowserDetailLevel.parse("full", default: .compact) == .full)
    }

    @Test func absentOrInvalidFallsBackToDefault() {
        #expect(BrowserDetailLevel.parse(nil, default: .compact) == .compact)
        #expect(BrowserDetailLevel.parse("verbose", default: .standard) == .standard)
    }
}

// MARK: - Snapshot formatting (plugin parity)

@Suite struct BrowserSnapshotFormatterTests {

    private func makeSampleData(
        title: String = "Test Page",
        url: String = "https://example.com",
        hasMore: Bool = false,
        bodyText: String = "",
        elements: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "title": title,
            "url": url,
            "hasMore": hasMore,
            "bodyText": bodyText,
            "elementCount": elements.count,
            "elements": elements,
        ]
    }

    private func makeSampleElements() -> [[String: Any]] {
        [
            [
                "ref": "E1", "type": "input", "text": "",
                "placeholder": "Enter email", "name": "email",
                "required": true, "id": "email-input",
                "ariaLabel": "Email address",
            ],
            [
                "ref": "E2", "type": "input", "text": "",
                "placeholder": "Password", "name": "password",
                "required": true, "id": "pwd-input",
            ],
            [
                "ref": "E3", "type": "button", "text": "Submit",
                "id": "submit-btn",
            ],
            [
                "ref": "E4", "type": "link", "text": "Forgot password?",
                "href": "https://example.com/forgot", "id": "forgot-link",
            ],
        ]
    }

    @Test func noneReturnsEmptyString() {
        let data = makeSampleData(elements: makeSampleElements())
        #expect(BrowserSnapshotFormatter.format(data, detail: .none) == "")
    }

    @Test func compactIsSingleLineAfterHeader() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = BrowserSnapshotFormatter.format(data, detail: .compact)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
    }

    @Test func compactIncludesPageHeader() {
        let data = makeSampleData(title: "My Page", url: "https://example.com/test")
        let result = BrowserSnapshotFormatter.format(data, detail: .compact)
        #expect(result.contains("- page: My Page | url: https://example.com/test"))
    }

    @Test func compactTruncatesLongText() {
        let elements: [[String: Any]] = [
            [
                "ref": "E1", "type": "button",
                "text": "This is a very long button label that should be truncated",
            ]
        ]
        let data = makeSampleData(elements: elements)
        let result = BrowserSnapshotFormatter.format(data, detail: .compact)
        #expect(result.contains("This is a very long ..."))
        #expect(!result.contains("should be truncated"))
    }

    @Test func compactHasMoreIndicator() {
        let data = makeSampleData(hasMore: true, elements: makeSampleElements())
        let result = BrowserSnapshotFormatter.format(data, detail: .compact)
        #expect(result.hasSuffix(" ..."))
    }

    @Test func compactEmptyElements() {
        let data = makeSampleData()
        let result = BrowserSnapshotFormatter.format(data, detail: .compact)
        #expect(result.contains("(no interactive elements found)"))
    }

    @Test func standardIsMultiLineWithRefs() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = BrowserSnapshotFormatter.format(data, detail: .standard)

        #expect(result.contains("[E1] input"))
        #expect(result.contains("[E2] input"))
        #expect(result.contains("[E3] button \"Submit\""))
        #expect(result.contains("[E4] link \"Forgot password?\""))

        let elementLines = result.split(separator: "\n").filter { $0.hasPrefix("[E") }
        #expect(elementLines.count == 4)
    }

    @Test func standardIncludesKeyAttributes() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = BrowserSnapshotFormatter.format(data, detail: .standard)
        #expect(result.contains("placeholder=\"Enter email\""))
        #expect(result.contains("required"))
        #expect(result.contains("href=\"https://example.com/forgot\""))
    }

    @Test func standardHasSeparatePageHeader() {
        let data = makeSampleData(title: "Test", url: "https://test.com")
        let result = BrowserSnapshotFormatter.format(data, detail: .standard)
        #expect(result.contains("- page: Test\n"))
        #expect(result.contains("- url: https://test.com\n"))
    }

    @Test func standardRendersCheckedAndDisabled() {
        let elements: [[String: Any]] = [
            ["ref": "E1", "type": "checkbox", "text": "Remember me", "checked": true],
            ["ref": "E2", "type": "button", "text": "Save", "disabled": true],
        ]
        let data = makeSampleData(elements: elements)
        let result = BrowserSnapshotFormatter.format(data, detail: .standard)
        #expect(result.contains("[E1] checkbox \"Remember me\" checked"))
        #expect(result.contains("[E2] button \"Save\" disabled"))
    }

    @Test func fullIncludesPageText() {
        let data = makeSampleData(
            bodyText: "Welcome to our application. Please sign in to continue.",
            elements: makeSampleElements()
        )
        let result = BrowserSnapshotFormatter.format(data, detail: .full)
        #expect(result.contains("- text: Welcome to our application."))
    }

    @Test func fullIncludesAllAttributes() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = BrowserSnapshotFormatter.format(data, detail: .full)
        #expect(result.contains("id=\"email-input\""))
        #expect(result.contains("name=\"email\""))
        #expect(result.contains("aria-label=\"Email address\""))
        #expect(result.contains("id=\"submit-btn\""))
        #expect(result.contains("id=\"forgot-link\""))
    }

    @Test func fullTruncatesLongBodyText() {
        let longText = String(repeating: "Hello world. ", count: 50)
        let data = makeSampleData(bodyText: longText, elements: makeSampleElements())
        let result = BrowserSnapshotFormatter.format(data, detail: .full)
        let textLine = result.split(separator: "\n").first { $0.hasPrefix("- text:") }
        #expect(textLine != nil)
        #expect(textLine?.hasSuffix("...") == true)
    }

    @Test func specialCharactersSurviveFormatting() {
        let elements: [[String: Any]] = [
            ["ref": "E1", "type": "button", "text": "Click \"here\" now"]
        ]
        let data = makeSampleData(elements: elements)
        let result = BrowserSnapshotFormatter.format(data, detail: .standard)
        #expect(result.contains("Click \"here\" now"))
    }

    @Test func emptyElementsHandledAtEveryLevel() {
        let data = makeSampleData(elements: [])
        for detail in [BrowserDetailLevel.compact, .standard, .full] {
            let result = BrowserSnapshotFormatter.format(data, detail: detail)
            #expect(result.contains("(no interactive elements found)"))
        }
    }

    @Test func crossOriginFramesAreListedAtStandardAndFull() {
        var data = makeSampleData(elements: makeSampleElements())
        data["crossOriginFrames"] = ["https://pay.example.com/frame", "https://auth.example.com/"]
        for detail in [BrowserDetailLevel.standard, .full] {
            let result = BrowserSnapshotFormatter.format(data, detail: detail)
            #expect(result.contains("cross-origin frames (content not reachable)"))
            #expect(result.contains("https://pay.example.com/frame"))
        }
        // Compact stays compact.
        let compact = BrowserSnapshotFormatter.format(data, detail: .compact)
        #expect(!compact.contains("cross-origin"))
    }

    @Test func absentFramesLeaveOutputByteIdentical() {
        // Parity guard: the frames line only appears when frames exist.
        let data = makeSampleData(elements: makeSampleElements())
        let result = BrowserSnapshotFormatter.format(data, detail: .standard)
        #expect(!result.contains("cross-origin"))
    }
}

// MARK: - URL scheme policy

@Suite struct BrowserSchemePolicyTests {

    @Test @MainActor func httpAndHttpsAreNavigable() {
        #expect(BrowserSession.navigationRefusalReason(for: URL(string: "http://example.com")) == nil)
        #expect(BrowserSession.navigationRefusalReason(for: URL(string: "https://example.com/x?y=1")) == nil)
        #expect(BrowserSession.navigationRefusalReason(for: URL(string: "HTTPS://EXAMPLE.COM")) == nil)
    }

    @Test @MainActor func aboutBlankIsAllowed() {
        // The initial document and window.open targets load about:blank.
        #expect(BrowserSession.navigationRefusalReason(for: URL(string: "about:blank")) == nil)
    }

    @Test @MainActor func fileURLsAreBlockedByDefault() {
        let reason = BrowserSession.navigationRefusalReason(
            for: URL(string: "file:///Users/me/.ssh/id_rsa"))
        #expect(reason?.contains("Local file URLs are blocked") == true)
    }

    @Test @MainActor func fileURLsAreAllowedOnlyUnderTheTestSeam() {
        BrowserSession.allowFileURLsForTesting = true
        defer { BrowserSession.allowFileURLsForTesting = false }
        #expect(BrowserSession.navigationRefusalReason(for: URL(string: "file:///tmp/fixture.html")) == nil)
    }

    @Test @MainActor func dataBlobAndCustomSchemesAreBlocked() {
        for raw in [
            "data:text/html,<script>alert(1)</script>",
            "blob:https://example.com/uuid",
            "javascript:alert(1)",
            "ftp://example.com/file",
            "x-custom-app://launch",
        ] {
            let reason = BrowserSession.navigationRefusalReason(for: URL(string: raw))
            #expect(reason?.contains("blocked") == true, "\(raw) must be refused")
        }
    }

    @Test @MainActor func nilURLIsNotRefused() {
        // A missing URL is not a policy matter (WebKit no-ops it).
        #expect(BrowserSession.navigationRefusalReason(for: nil) == nil)
    }
}

// MARK: - Screenshot path confinement

@Suite struct BrowserScreenshotPathTests {

    private let downloads = URL(fileURLWithPath: "/Users/test/Downloads")

    private func resolve(_ custom: String?, exists: Set<String> = []) -> URL? {
        BrowserScreenshotPath.resolve(
            custom: custom,
            downloadsDir: downloads,
            fileExists: { exists.contains($0) }
        )
    }

    @Test func defaultLandsInDownloadsWithPNGExtension() {
        let url = resolve(nil)
        #expect(url?.path.hasPrefix(downloads.path + "/") == true)
        #expect(url?.pathExtension == "png")
    }

    @Test func bareFilenameResolvesInsideDownloads() {
        #expect(resolve("shot.png")?.path == "/Users/test/Downloads/shot.png")
        // Missing extension gets .png appended.
        #expect(resolve("shot")?.path == "/Users/test/Downloads/shot.png")
    }

    @Test func absolutePathsOutsideDownloadsAreRejected() {
        #expect(resolve("/etc/passwd") == nil)
        #expect(resolve("/Users/test/Desktop/x.png") == nil)
        #expect(resolve("~/Library/LaunchAgents/evil.png") == nil)
    }

    @Test func traversalOutOfDownloadsIsRejected() {
        #expect(resolve("../.ssh/authorized_keys.png") == nil)
        #expect(resolve("sub/../../escape.png") == nil)
        // Sibling directory with the same prefix must not slip past.
        #expect(resolve("/Users/test/DownloadsEvil/x.png") == nil)
    }

    @Test func downloadsItselfIsNotAValidTarget() {
        #expect(resolve("/Users/test/Downloads") == nil)
    }

    @Test func existingFilesAreNeverOverwritten() {
        let taken: Set<String> = [
            "/Users/test/Downloads/shot.png",
            "/Users/test/Downloads/shot-1.png",
        ]
        let url = resolve("shot.png", exists: taken)
        #expect(url?.path == "/Users/test/Downloads/shot-2.png")
    }

    @Test func subdirectoriesInsideDownloadsAreAllowed() {
        #expect(resolve("agent/run1.png")?.path == "/Users/test/Downloads/agent/run1.png")
    }
}

// MARK: - Login redirect detection

@Suite struct BrowserLoginDetectorTests {

    @Test func detectsLoginPaths() {
        #expect(
            BrowserLoginDetector.loginHost(
                finalURL: "https://github.com/login?return_to=/", title: "GitHub")
                == "github.com")
        #expect(
            BrowserLoginDetector.loginHost(
                finalURL: "https://example.com/users/sign_in", title: "Example")
                == "example.com")
    }

    @Test func detectsLoginTitles() {
        #expect(
            BrowserLoginDetector.loginHost(
                finalURL: "https://example.com/dashboard", title: "Sign in to Example")
                == "example.com")
        #expect(
            BrowserLoginDetector.loginHost(
                finalURL: "https://example.com/x", title: "Log in | Example")
                == "example.com")
    }

    @Test func ordinaryPagesAreNotLoginWalls() {
        // Conservative: false negatives fine, false positives nag the user.
        #expect(
            BrowserLoginDetector.loginHost(
                finalURL: "https://example.com/products", title: "Products — Example")
                == nil)
        #expect(
            BrowserLoginDetector.loginHost(
                finalURL: "https://example.com/blog/how-to-login-faster", title: "Blog")
                == nil)
    }
}
