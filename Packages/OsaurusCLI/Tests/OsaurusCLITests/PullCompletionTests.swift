import Foundation
import XCTest

@testable import OsaurusCLICore

final class PullCompletionTests: XCTestCase {
    func testCompleteFilesNotifyOnceWithoutHTTPOrPathPayload() throws {
        try withRoot { root in
            try Data("cfg".utf8).write(to: root.appendingPathComponent("config.json"))
            try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))
            var names: [String] = []
            var payloads: [[AnyHashable: Any]] = []
            let result = PullCommand.notifyAppIfPullComplete(
                files: [("config.json", 3), ("model.safetensors", 7)], destination: root
            ) { name, payload in
                names.append(name)
                payloads.append(payload)
            }
            XCTAssertTrue(result)
            XCTAssertEqual(names, ["com.dinoki.osaurus.control.modelsReload"])
            XCTAssertEqual(payloads.count, 1)
            XCTAssertTrue(payloads[0].isEmpty)
        }
    }

    func testIncompleteOrEmptyPullCannotNotify() throws {
        try withRoot { root in
            try Data("cfg".utf8).write(to: root.appendingPathComponent("config.json"))
            let cases: [[(path: String, size: Int64)]] = [
                [],
                [("config.json", 3), ("model.safetensors", 7)],
                [("config.json", 4)],
                [("config.json", 0)],
            ]
            for files in cases {
                var notified = false
                XCTAssertFalse(PullCommand.notifyAppIfPullComplete(files: files, destination: root) { _, _ in
                    notified = true
                })
                XCTAssertFalse(notified)
            }
        }
    }

    func testInvalidPathOrLinkedFinalFileCannotNotify() throws {
        try withRoot { root in
            let target = root.appendingPathComponent("target")
            try Data("cfg".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("config.json"), withDestinationURL: target)
            for path in ["../target", "/target", "config.json"] {
                var notified = false
                XCTAssertFalse(PullCommand.notifyAppIfPullComplete(files: [(path, 3)], destination: root) { _, _ in
                    notified = true
                })
                XCTAssertFalse(notified)
            }
        }
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pull-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
