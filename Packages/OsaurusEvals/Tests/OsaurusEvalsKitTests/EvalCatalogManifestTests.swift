//
//  EvalCatalogManifestTests.swift
//  OsaurusEvalsKitTests
//
//  Pins the eval-catalog inventory against Config/catalog-manifest.json.
//
//  The per-suite decode smokes only assert FLOOR counts (>=) so that
//  adding cases never breaks them — the flip side is that a deleted,
//  renamed, or re-homed case could vanish silently. This test closes
//  that hole: it regenerates the suite → sorted-case-ids map from
//  Suites/**/*.json and requires an exact match with the committed
//  manifest, so every catalog mutation is a deliberate, reviewable
//  diff. On mismatch it writes the freshly computed manifest to a temp
//  file so the fix is a copy, not hand-editing 470+ ids.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@Suite
struct EvalCatalogManifestTests {

    /// Package root resolved from this source file's location —
    /// stable under both `swift test --package-path …` (any cwd)
    /// and Xcode test runs.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
    }

    private static var suitesRoot: URL {
        packageRoot.appendingPathComponent("Suites")
    }

    private static var manifestURL: URL {
        packageRoot.appendingPathComponent("Config/catalog-manifest.json")
    }

    /// Decode every suite directory and build the live suite → sorted
    /// ids map, collecting decode failures and duplicate ids along the
    /// way (both must be empty for the catalog to be healthy).
    private static func computeLiveManifest() throws -> (
        manifest: [String: [String]],
        decodeFailures: [String],
        duplicateIds: [String]
    ) {
        let fm = FileManager.default
        let suiteDirs = try fm.contentsOfDirectory(
            at: suitesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var manifest: [String: [String]] = [:]
        var decodeFailures: [String] = []
        var idToSuite: [String: String] = [:]
        var duplicates: [String] = []

        for dir in suiteDirs {
            let suiteName = dir.lastPathComponent
            let suite = try EvalSuite.load(from: dir)
            for failure in suite.decodeFailures {
                decodeFailures.append("\(suiteName)/\(failure.filename): \(failure.error)")
            }
            for testCase in suite.cases {
                if let existing = idToSuite[testCase.id] {
                    duplicates.append("\(testCase.id) (in \(existing) and \(suiteName))")
                }
                idToSuite[testCase.id] = suiteName
            }
            manifest[suiteName] = suite.cases.map(\.id).sorted()
        }
        return (manifest, decodeFailures, duplicates)
    }

    @Test func catalogHasNoDecodeFailuresOrDuplicateIds() throws {
        let live = try Self.computeLiveManifest()
        #expect(
            live.decodeFailures.isEmpty,
            "case files failed to decode:\n\(live.decodeFailures.joined(separator: "\n"))"
        )
        #expect(
            live.duplicateIds.isEmpty,
            "duplicate case ids across the catalog:\n\(live.duplicateIds.joined(separator: "\n"))"
        )
    }

    @Test func catalogMatchesCommittedManifest() throws {
        let live = try Self.computeLiveManifest()

        let data = try Data(contentsOf: Self.manifestURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let committed =
            (root?["suites"] as? [String: [String]])?
            .mapValues { $0.sorted() } ?? [:]

        guard live.manifest != committed else { return }

        // Build a readable drift summary before failing, and write the
        // regenerated manifest so the fix is a file copy.
        var drift: [String] = []
        let allSuites = Set(live.manifest.keys).union(committed.keys).sorted()
        for suiteName in allSuites {
            let liveIds = Set(live.manifest[suiteName] ?? [])
            let committedIds = Set(committed[suiteName] ?? [])
            for added in liveIds.subtracting(committedIds).sorted() {
                drift.append("+ \(suiteName): \(added)")
            }
            for removed in committedIds.subtracting(liveIds).sorted() {
                drift.append("- \(suiteName): \(removed)")
            }
        }

        let regenerated: [String: Any] = [
            "_comment": (root?["_comment"] as? String) ?? "",
            "suites": live.manifest.mapValues { $0 },
        ]
        let regeneratedData = try JSONSerialization.data(
            withJSONObject: regenerated,
            options: [.prettyPrinted, .sortedKeys]
        )
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-manifest.regenerated.json")
        try? regeneratedData.write(to: outURL)

        Issue.record(
            Comment(
                rawValue: """
                    eval catalog drifted from Config/catalog-manifest.json \
                    (+ = on disk but not in manifest, - = in manifest but missing on disk):
                    \(drift.joined(separator: "\n"))

                    If the change is intentional, copy the regenerated manifest over the committed one:
                      cp \(outURL.path) \(Self.manifestURL.path)
                    (then restore/adjust the top-level _comment if needed)
                    """
            )
        )
    }
}
