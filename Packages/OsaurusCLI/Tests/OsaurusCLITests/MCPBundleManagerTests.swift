import Foundation
import XCTest

@testable import OsaurusCLICore

final class MCPBundleManagerTests: XCTestCase {
    private let bundlesRoot = "/tmp/osaurus-bundles"

    private func snapshot() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: bundlesRoot)) ?? []
        return Set(entries)
    }

    /// A failed extraction must not leave its partially-created temp directory behind.
    func testExtractCleansUpTempDirectoryOnUnzipFailure() throws {
        // A non-zip file makes `/usr/bin/unzip` exit non-zero -> extractionFailed.
        let badBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-not-a-zip-\(UUID().uuidString).mcpb")
        try Data("this is not a zip archive".utf8).write(to: badBundle)
        defer { try? FileManager.default.removeItem(at: badBundle) }

        let before = snapshot()
        XCTAssertThrowsError(try MCPBundleManager.extract(badBundle.path)) { error in
            guard case BundleLoadError.extractionFailed = error else {
                return XCTFail("expected extractionFailed, got \(error)")
            }
        }
        let after = snapshot()

        XCTAssertEqual(
            after.subtracting(before),
            [],
            "extract() leaked a temp directory under \(bundlesRoot) on extraction failure"
        )
    }
}
