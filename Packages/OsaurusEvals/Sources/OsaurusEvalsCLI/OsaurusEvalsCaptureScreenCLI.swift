//
//  OsaurusEvalsCaptureScreenCLI.swift
//  osaurus-evals
//
//  `capture-screen` subcommand — the real-app side of the screen_context
//  tuning loop. Uses the in-process `NativeMacDriver` to read the frontmost
//  (or a named) app's accessibility tree, listings, and focused-element
//  content, and writes a `ScreenContextFixture` JSON that the `screen_context`
//  eval suite replays deterministically via `FixtureCUDriver`.
//
//    osaurus-evals capture-screen [--app <name>] [--out <path>]
//    osaurus-evals capture-screen --describe <fixture>
//    osaurus-evals capture-screen --promote <local-fixture> [--out <path>]
//
//  Local-only: it needs Accessibility permission (granted to the terminal /
//  binary running it) and a real desktop session, so it never runs in CI. The
//  default output lives under the gitignored
//  `Packages/OsaurusEvals/Fixtures/ScreenContext/local/` directory because a
//  real capture contains your actual on-screen code/text.
//

import Foundation
import OsaurusCore
import OsaurusEvalsKit

extension OsaurusEvalsCLI {

    /// Default (gitignored) directory for real captures. Resolved relative to
    /// the CWD — the convention is to run this from the repo root.
    private static let defaultCaptureDir =
        "Packages/OsaurusEvals/Fixtures/ScreenContext/local"

    /// How many elements to pull when capturing — generously above the
    /// distiller's own 250 budget so the fixture holds a fuller tree. The
    /// replay driver re-clips to the distiller's budget AND lets the targeted
    /// `find` fallback recover deeper elements, reproducing native behavior.
    private static let captureMaxElements = 2000

    static func runCaptureScreen(_ args: [String]) async -> Int32 {
        var appName: String?
        var outPath: String?
        var render = false
        var describePath: String?
        var promotePath: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--app":
                guard i + 1 < args.count else {
                    return failCapture("flag --app requires a value")
                }
                appName = args[i + 1]
                i += 2
            case "--out":
                guard i + 1 < args.count else {
                    return failCapture("flag --out requires a value")
                }
                outPath = args[i + 1]
                i += 2
            case "--describe":
                guard i + 1 < args.count else {
                    return failCapture("flag --describe requires a value")
                }
                describePath = args[i + 1]
                i += 2
            case "--promote":
                guard i + 1 < args.count else {
                    return failCapture("flag --promote requires a value")
                }
                promotePath = args[i + 1]
                i += 2
            case "--render":
                render = true
                i += 1
            case "--help", "-h":
                printCaptureScreenUsage()
                return 0
            default:
                return failCapture("unknown argument: \(arg)")
            }
        }

        if let describePath {
            guard appName == nil, promotePath == nil, outPath == nil, !render else {
                return failCapture("--describe cannot be combined with --app, --out, --promote, or --render")
            }
            return describeScreenFixture(path: describePath)
        }

        if let promotePath {
            guard appName == nil else {
                return failCapture("--promote reads an existing fixture and cannot be combined with --app")
            }
            return await promoteScreenFixture(path: promotePath, outPath: outPath, render: render)
        }

        let driver = NativeMacDriver()

        // Accessibility gate — the capture is useless (empty tree) without it.
        let availability = await driver.availability()
        guard availability.accessibility else {
            FileHandle.standardError.write(
                Data(
                    ("""
                    capture-screen: Accessibility permission is not granted.
                    Grant it to the app running this command (your terminal, or the
                    osaurus-evals binary) in System Settings → Privacy & Security →
                    Accessibility, then retry.

                    """).utf8
                )
            )
            return 2
        }

        let apps = await driver.listApps()
        let active = await driver.activeWindow()

        // Resolve the target app: an explicit --app (exact, then case-insensitive
        // contains), else the genuine frontmost app.
        let target: (pid: Int32, name: String)?
        if let appName {
            if let exact = apps.first(where: { $0.name.caseInsensitiveCompare(appName) == .orderedSame }) {
                target = (exact.pid, exact.name)
            } else if let partial = apps.first(where: {
                $0.name.localizedCaseInsensitiveContains(appName)
            }) {
                target = (partial.pid, partial.name)
            } else {
                return failCapture(
                    "no running app matches --app '\(appName)'. Running apps: "
                        + apps.map(\.name).joined(separator: ", ")
                )
            }
        } else if let active {
            target = (active.pid, active.app)
        } else {
            target = apps.first.map { ($0.pid, $0.name) }
        }

        guard let target else {
            return failCapture("could not resolve a target app (no active window, no running apps)")
        }

        // Per-pid window listings for every enumerated app, so the fixture
        // reproduces the distiller's multi-app window scan.
        var windowsByPid: [String: [CUWindowInfo]] = [:]
        for app in apps {
            let windows = await driver.listWindows(pid: app.pid)
            if !windows.isEmpty {
                windowsByPid[String(app.pid)] = windows
            }
        }

        let snapshot = await driver.capture(
            pid: target.pid,
            tier: .ax,
            windowId: nil,
            maxElements: captureMaxElements,
            focusedWindowOnly: true,
            interactiveOnly: false
        )
        let focusedContent = await driver.focusedContent(pid: target.pid)

        // The fixture's "active window" is the app we captured, so a replay (and
        // `--render`) attributes the snapshot to the right app. Without this, a
        // `--app <non-frontmost>` capture would carry whatever app happened to be
        // frontmost during the read, and the distiller would mislabel "Doing:".
        let targetWindow =
            windowsByPid[String(target.pid)]?.first(where: { $0.focused })
            ?? windowsByPid[String(target.pid)]?.first
        let activeForFixture = CUActiveWindow(
            pid: target.pid,
            app: target.name,
            title: snapshot.focusedWindow ?? targetWindow?.title,
            x: targetWindow?.x ?? 0,
            y: targetWindow?.y ?? 0,
            w: targetWindow?.w ?? 0,
            h: targetWindow?.h ?? 0
        )

        let fixture = ScreenContextFixture(
            apps: apps,
            activeWindow: activeForFixture,
            windowsByPid: windowsByPid,
            snapshot: ScreenContextFixture.Snapshot(
                app: snapshot.app,
                focusedWindow: snapshot.focusedWindow,
                truncated: snapshot.truncated,
                windows: snapshot.windows,
                elements: snapshot.elements
            ),
            focusedContent: focusedContent
        )

        // Resolve the output path (explicit, else a timestamped file under the
        // gitignored local dir).
        let outURL: URL
        if let outPath {
            outURL = URL(fileURLWithPath: outPath)
        } else {
            let stamp = Self.captureTimestamp()
            let slug = Self.fileSlug(target.name)
            outURL = URL(fileURLWithPath: defaultCaptureDir)
                .appendingPathComponent("\(slug)-\(stamp).json")
        }

        do {
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(fixture)
            try data.write(to: outURL)
        } catch {
            return failCapture("failed to write fixture: \(error.localizedDescription)")
        }

        print(
            """
            captured \(target.name) → \(outURL.path)
            Point a screen_context case at this file (relative to \
            Packages/OsaurusEvals/Fixtures/ScreenContext/) and run:
              make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/ScreenContext --verbose
            """
        )
        printCaptureSummary(fixture.captureSummary())

        // `--render`: replay the just-captured fixture through the production
        // distiller and print the exact block the chat would inject. This is the
        // fast capture→diagnose loop (no scratch eval case needed).
        if render {
            let distilled = await ScreenContextDistiller().capture(
                using: FixtureCUDriver(fixture: fixture),
                selfPid: Int32.max,
                selfBundleId: nil,
                preferredPid: nil
            )
            print("\n--- rendered block ---")
            print(distilled.render())
        }
        return 0
    }

    // MARK: - Helpers

    private static func describeScreenFixture(path: String) -> Int32 {
        do {
            let fixture = try loadFixture(at: URL(fileURLWithPath: path))
            printCaptureSummary(fixture.captureSummary())
            return 0
        } catch {
            return failCapture("failed to describe fixture: \(error.localizedDescription)")
        }
    }

    private static func promoteScreenFixture(
        path: String,
        outPath: String?,
        render: Bool
    ) async -> Int32 {
        let inputURL = URL(fileURLWithPath: path)
        do {
            let fixture = try loadFixture(at: inputURL)
            let candidate = fixture.sanitizedForPromotion()
            let outURL =
                outPath.map { URL(fileURLWithPath: $0) }
                ?? defaultPromotionURL(inputURL: inputURL, fixture: fixture)
            try writeFixture(candidate.fixture, to: outURL)

            print(
                """
                wrote sanitized promotion candidate → \(outURL.path)
                source capture → \(inputURL.path)
                """
            )
            printSanitizationReport(candidate.report)
            printCaptureSummary(candidate.fixture.captureSummary())
            print(
                """
                Review and hand-edit this candidate before committing it. The helper replaces \
                captured text with placeholders so you can preserve AX shape without carrying \
                private screen content into committed fixtures.
                """
            )

            if render {
                let distilled = await ScreenContextDistiller().capture(
                    using: FixtureCUDriver(fixture: candidate.fixture),
                    selfPid: Int32.max,
                    selfBundleId: nil,
                    preferredPid: nil
                )
                print("\n--- rendered sanitized block ---")
                print(distilled.render())
            }
            return 0
        } catch {
            return failCapture("failed to promote fixture: \(error.localizedDescription)")
        }
    }

    private static func loadFixture(at url: URL) throws -> ScreenContextFixture {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ScreenContextFixture.self, from: data)
    }

    private static func writeFixture(_ fixture: ScreenContextFixture, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(fixture)
        try data.write(to: url)
    }

    private static func defaultPromotionURL(
        inputURL: URL,
        fixture: ScreenContextFixture
    ) -> URL {
        let stamp = Self.captureTimestamp()
        let sourceSlug = Self.fileSlug(inputURL.deletingPathExtension().lastPathComponent)
        let appSlug = Self.fileSlug(fixture.activeWindow?.app ?? fixture.snapshot.app)
        return URL(fileURLWithPath: defaultCaptureDir)
            .appendingPathComponent("sanitized-\(appSlug)-\(sourceSlug)-\(stamp).json")
    }

    private static func printCaptureSummary(_ summary: ScreenContextFixture.CaptureSummary) {
        let focusNote: String
        if let role = summary.focusedRole {
            if let label = summary.focusedLabel, !label.isEmpty {
                focusNote = "\(role) \"\(label)\""
            } else {
                focusNote = role
            }
        } else {
            focusNote = "none"
        }
        let roleText =
            summary.topRoles.isEmpty
            ? "none"
            : summary.topRoles.map { "\($0.role)=\($0.count)" }.joined(separator: ", ")
        print(
            """
            capture summary:
              app=\(summary.workingApp) window=\(summary.workingWindowTitle ?? "none")
              apps=\(summary.appCount) windows=\(summary.windowCount) elements=\(summary.elementCount) \
            textElements=\(summary.textElementCount) secureFields=\(summary.secureFieldCount) \
            pathFields=\(summary.pathFieldCount) truncated=\(summary.truncated)
              focused=\(focusNote)
              topRoles=\(roleText)
            """
        )
        if !summary.localOnlyReasons.isEmpty {
            print("  localOnly:")
            for reason in summary.localOnlyReasons {
                print("    - \(reason)")
            }
        }
    }

    private static func printSanitizationReport(
        _ report: ScreenContextFixture.PromotionSanitizationReport
    ) {
        print(
            """
            sanitization:
              stringFieldsRedacted=\(report.stringFieldsRedacted) \
            secureValuesDropped=\(report.secureValuesDropped) \
            elementIDsRewritten=\(report.elementIDsRewritten)
              pathFieldsDropped=\(report.pathFieldsDropped) \
            windowTitlesRedacted=\(report.windowTitlesRedacted) \
            appMetadataRedacted=\(report.appMetadataRedacted)
            """
        )
    }

    private static func captureTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Lowercased, filesystem-safe slug from an app name (spaces/punctuation →
    /// `-`, collapsed). Empty input falls back to `app`.
    private static func fileSlug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = name.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "app" : collapsed
    }

    private static func failCapture(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("capture-screen: \(message)\n").utf8))
        printCaptureScreenUsage()
        return 2
    }

    private static func printCaptureScreenUsage() {
        let usage = """
            osaurus-evals capture-screen — write a ScreenContextFixture from a real app

            USAGE:
                osaurus-evals capture-screen [--app <name>] [--out <path>] [--render]
                osaurus-evals capture-screen --describe <fixture>
                osaurus-evals capture-screen --promote <local-fixture> [--out <path>] [--render]

            FLAGS:
                --app <name>   Capture this app (exact, then case-insensitive
                               substring match on the running-app name). Default:
                               the current frontmost app.
                --out <path>   Write the fixture JSON here. Default: a timestamped
                               file under \(defaultCaptureDir)/ (gitignored — real
                               captures contain your on-screen content).
                --render       After capturing, replay the fixture through the
                               distiller and print the exact injected block (the
                               fast capture→diagnose loop).
                --describe <fixture>
                               Print fixture metadata and local-only risk summary.
                               No Accessibility permission required.
                --promote <local-fixture>
                               Write a sanitized promotion candidate. The helper
                               keeps geometry/roles but replaces captured text
                               with placeholders; hand-edit before committing.

            REQUIRES:
                Accessibility permission for the running process (terminal/binary),
                in System Settings → Privacy & Security → Accessibility. Local-only;
                never run in CI.

            EXAMPLES:
                osaurus-evals capture-screen
                osaurus-evals capture-screen --app Xcode
                osaurus-evals capture-screen --app Safari --out /tmp/safari.json
                osaurus-evals capture-screen --describe Packages/OsaurusEvals/Fixtures/ScreenContext/local/xcode.json
                osaurus-evals capture-screen --promote Packages/OsaurusEvals/Fixtures/ScreenContext/local/xcode.json
            """
        print(usage)
    }
}
