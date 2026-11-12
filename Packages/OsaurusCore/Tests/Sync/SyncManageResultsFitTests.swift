//
//  SyncManageResultsFitTests.swift
//  OsaurusCoreTests
//
//  A device's manage results record has to fit the core's 64 KiB app data
//  cap: one over it never wrote, and was retried on every change.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sync manage results fit")
struct SyncManageResultsFitTests {
    private typealias Results = SyncDeviceFeedContract.ManageResults

    /// `count` results, each carrying about `size` bytes of data, done one after another.
    private func results(count: Int, size: Int) -> Results {
        var all: [String: SyncDeviceFeedContract.ManageResult] = [:]
        for i in 0..<count {
            all["r\(i)"] = .init(
                ok: true, data: .string(String(repeating: "m", count: size)), doneMs: Int64(1_000 + i))
        }
        return Results(results: all)
    }

    private func size(_ r: Results) -> Int { (try? SyncHostedRunContract.encode(r).count) ?? .max }

    @Test func smallResultsAreUnchanged() {
        let r = results(count: 3, size: 100)
        #expect(r.fitted() == r)
    }

    @Test func oldestLoseTheirDataFirst() {
        let r = results(count: 4, size: 20_000)
        let fitted = r.fitted()
        #expect(size(fitted) <= Results.maxBytes)
        #expect(fitted.results.count == 4)
        #expect(fitted.results["r0"]?.data == nil)
        #expect(fitted.results["r3"]?.data != nil)
    }

    @Test func fittingIsStable() {
        let fitted = results(count: 6, size: 30_000).fitted()
        #expect(size(fitted) <= Results.maxBytes)
        #expect(fitted.fitted() == fitted)
    }
}
