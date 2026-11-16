//
//  TelemetryDocSyncTests.swift
//  osaurusTests
//
//  `docs/TELEMETRY.md` is the public, authoritative list of what Osaurus
//  sends. Every event name `FeatureTelemetry` and `OnboardingTelemetry`
//  pass to `track` must appear there, so an event can't ship undocumented.
//

import Foundation
import Testing

struct TelemetryDocSyncTests {

    /// `Packages/OsaurusCore/`, walking up from this file.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Telemetry/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // OsaurusCore/

    private static let sources = [
        "Services/FeatureTelemetry.swift",
        "Views/Onboarding/OnboardingTelemetry.swift",
    ]

    /// Every string literal passed as `track`'s first argument, including
    /// calls that put the name on the next line.
    static func trackedEventNames(in source: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\.track\(\s*"([a-z0-9_]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(
            regex.matches(in: source, range: range).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            })
    }

    @Test func trackedEventNames_reads_single_and_multi_line_calls() throws {
        let sample = """
            service.track("one_line", ["a": 1])
            service.track(
                "next_line",
                [:])
            service.track(name)
            """
        #expect(try Self.trackedEventNames(in: sample) == ["one_line", "next_line"])
    }

    @Test func every_tracked_event_is_documented() throws {
        let doc = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("../../docs/TELEMETRY.md").standardizedFileURL,
            encoding: .utf8)
        var names: Set<String> = []
        for path in Self.sources {
            let source = try String(contentsOf: Self.packageRoot.appendingPathComponent(path), encoding: .utf8)
            names.formUnion(try Self.trackedEventNames(in: source))
        }
        #expect(names.count > 40)
        let missing = names.filter { !doc.contains("`\($0)`") }.sorted()
        #expect(missing.isEmpty, "Add these events to docs/TELEMETRY.md: \(missing)")
    }
}
