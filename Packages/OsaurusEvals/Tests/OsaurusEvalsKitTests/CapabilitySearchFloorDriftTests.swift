//
//  CapabilitySearchFloorDriftTests.swift
//  OsaurusEvals
//
//  Issue #2397: Config/floors.json#caseFloors.capability_search silently
//  drifted from the Suites/CapabilitySearch fixtures — six suite cases had
//  no floor (so --fail-on-floor never gated them) and one floor pointed at a
//  fixture removed with the browser plugin. Floors and fixtures are two
//  spellings of the same contract; this guard makes them provably identical
//  the same way EVALS_DETERMINISTIC_SUITES pins the deterministic lanes.
//

import Foundation
import XCTest

final class CapabilitySearchFloorDriftTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // OsaurusEvalsKitTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // OsaurusEvals/

    private func loadFloors() throws -> [String: [String: Int]] {
        let url = Self.packageRoot.appendingPathComponent("Config/floors.json")
        let root =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let caseFloors = root["caseFloors"] as? [String: Any] ?? [:]
        let block = caseFloors["capability_search"] as? [String: Any] ?? [:]
        return block.compactMapValues { value in
            (value as? [String: Any])?.compactMapValues { $0 as? Int }
        }
    }

    private func loadFixtures() throws -> [String: Int?] {
        let dir = Self.packageRoot.appendingPathComponent("Suites/CapabilitySearch")
        var out: [String: Int?] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where file.hasSuffix(".json") {
            let url = dir.appendingPathComponent(file)
            let fixture =
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                ?? [:]
            let id = fixture["id"] as? String ?? "capability_search.\(file.dropLast(5))"
            // Every expectation group in the fixture declares its own
            // minMatches; the floor mirrors the strongest one.
            let expect = fixture["expect"] as? [String: Any] ?? [:]
            let search = expect["capabilitySearch"] as? [String: Any] ?? [:]
            let declared = search.values
                .compactMap { ($0 as? [String: Any])?["minMatches"] as? Int }
                .max()
            out[id] = declared
        }
        return out
    }

    func testEveryFixtureHasAFloorAndEveryFloorHasAFixture() throws {
        let floors = try loadFloors()
        let fixtures = try loadFixtures()

        let missingFloors = Set(fixtures.keys).subtracting(floors.keys).sorted()
        XCTAssertEqual(
            missingFloors, [],
            "Suite cases with no caseFloors entry — --fail-on-floor is not gating them: \(missingFloors)"
        )

        let staleFloors = Set(floors.keys).subtracting(fixtures.keys).sorted()
        XCTAssertEqual(
            staleFloors, [],
            "caseFloors entries whose fixture no longer exists (dead gates): \(staleFloors)"
        )
    }

    func testFloorsMirrorTheFixturesOwnMinMatches() throws {
        let floors = try loadFloors()
        let fixtures = try loadFixtures()

        for (id, declared) in fixtures {
            guard let declared, let floor = floors[id]?["minMatches"] else { continue }
            XCTAssertEqual(
                floor, declared,
                "\(id): floors.json says minMatches \(floor) but the fixture asserts \(declared) — one of them is lying about the contract"
            )
        }
    }
}
