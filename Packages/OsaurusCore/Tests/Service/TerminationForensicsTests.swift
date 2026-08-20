//
//  TerminationForensicsTests.swift
//  osaurus
//
//  The silent-restart report class: UI + menu bar icon vanish and reappear
//  with no crash report, and a factory reset destroys the evidence. These
//  pin the attribution contract: intentional exits leave a marker, the next
//  launch converts marker-presence into a verdict file, and a missing marker
//  after a forensics-active session reads `unattributed` — while a fresh
//  root reads `firstLaunch`, never a false alarm.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct TerminationForensicsTests {

    private func withTempRoot<T: Sendable>(
        _ body: @Sendable (URL) throws -> T
    ) async rethrows -> T {
        try await OsaurusTestGlobals.withPathsLock {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-termination-forensics-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previous = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            return try body(root)
        }
    }

    @Test("a fresh root is firstLaunch, never a false unattributed alarm")
    func freshRootIsFirstLaunch() async throws {
        try await withTempRoot { root in
            #expect(TerminationForensics.evaluateAtLaunch() == .firstLaunch)
            // And the verdict file records it.
            let data = try Data(
                contentsOf: root.appendingPathComponent("last-exit-verdict.json"))
            let record = try JSONDecoder().decode(
                TerminationForensics.VerdictRecord.self, from: data)
            #expect(record.verdict == .firstLaunch)
        }
    }

    @Test("an intentional exit reads back clean, with the reason, and clears the marker")
    func intentionalExitIsClean() async throws {
        try await withTempRoot { root in
            _ = TerminationForensics.evaluateAtLaunch()  // arm the sentinel
            TerminationForensics.recordIntentionalExit(reason: "quit-complete")

            #expect(TerminationForensics.evaluateAtLaunch() == .clean)
            let data = try Data(
                contentsOf: root.appendingPathComponent("last-exit-verdict.json"))
            let record = try JSONDecoder().decode(
                TerminationForensics.VerdictRecord.self, from: data)
            #expect(record.verdict == .clean)
            #expect(record.previousReason == "quit-complete")
            // Marker consumed: a THIRD launch with no new exit is unattributed.
            #expect(TerminationForensics.evaluateAtLaunch() == .unattributed)
        }
    }

    @Test("dying without a marker after an armed session reads unattributed")
    func silentDeathIsUnattributed() async throws {
        try await withTempRoot { root in
            _ = TerminationForensics.evaluateAtLaunch()  // previous launch armed forensics
            // ...process dies here with no recordIntentionalExit...
            #expect(TerminationForensics.evaluateAtLaunch() == .unattributed)
            let data = try Data(
                contentsOf: root.appendingPathComponent("last-exit-verdict.json"))
            let record = try JSONDecoder().decode(
                TerminationForensics.VerdictRecord.self, from: data)
            #expect(record.verdict == .unattributed)
            #expect(record.previousReason == nil)
        }
    }

    @Test("a later marker on the same shutdown overwrites with the more specific reason")
    func laterMarkerWins() async throws {
        try await withTempRoot { _ in
            _ = TerminationForensics.evaluateAtLaunch()
            TerminationForensics.recordIntentionalExit(reason: "app-terminate")
            TerminationForensics.recordIntentionalExit(reason: "exit-backstop-45s")
            _ = TerminationForensics.evaluateAtLaunch()
            let data = try Data(
                contentsOf: OsaurusPaths.root().appendingPathComponent("last-exit-verdict.json"))
            let record = try JSONDecoder().decode(
                TerminationForensics.VerdictRecord.self, from: data)
            #expect(record.previousReason == "exit-backstop-45s")
        }
    }
}
