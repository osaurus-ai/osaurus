//
//  ProcessLaunchValidationTests.swift
//
//  Regression for APPLE-MACOS-258: `Process.run()` raises an uncatchable
//  `NSInvalidArgumentException` (`-[NSString fileSystemRepresentation]`)
//  when a launch string carries an embedded NUL. Model-supplied `shell_run`
//  commands can contain one, so `runProcessAsync` must refuse the launch
//  with a normal Swift error instead of crashing the app.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ProcessLaunchValidationTests {

    private func process(arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/echo")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return p
    }

    @Test func argumentWithNULIsRejectedBeforeLaunch() async {
        let p = process(arguments: ["ok", "bad\u{0}arg"])
        await #expect(throws: FolderToolError.self) {
            try await FolderToolHelpers.runProcessAsync(p)
        }
        #expect(!p.isRunning)
        #expect(p.processIdentifier == 0)
    }

    // The string setters always keep the NUL, regardless of how the running
    // Foundation bridges it into `executableURL` / `currentDirectoryURL`.
    @Test func executablePathWithNULIsRejected() {
        let p = Process()
        p.launchPath = "/bin/ec\u{0}ho"
        #expect(throws: FolderToolError.self) {
            try FolderToolHelpers.validateLaunchStrings(of: p)
        }
    }

    @Test func workingDirectoryWithNULIsRejected() {
        let p = process(arguments: [])
        p.currentDirectoryPath = "/tmp/\u{0}x"
        #expect(throws: FolderToolError.self) {
            try FolderToolHelpers.validateLaunchStrings(of: p)
        }
    }

    /// Foundation releases disagree on what a file URL built from a string
    /// with an embedded NUL looks like afterwards (kept verbatim, `%00`
    /// percent-encoded, or truncated at the NUL). Whenever the NUL survives
    /// in any representation the validator must reject it; when Foundation
    /// dropped it there is nothing left to crash on and the launch is clean.
    @Test func urlFormsWithNULAreRejectedWheneverTheNULSurvives() {
        let exec = Process()
        exec.executableURL = URL(fileURLWithPath: "/bin/ec\u{0}ho")
        let cwd = process(arguments: [])
        cwd.currentDirectoryURL = URL(fileURLWithPath: "/tmp/\u{0}x")

        for (p, url) in [(exec, exec.executableURL), (cwd, cwd.currentDirectoryURL)] {
            let survives =
                (url?.path.utf8.contains(0) ?? false)
                || (url?.path(percentEncoded: false).utf8.contains(0) ?? false)
                || (url?.absoluteString.localizedCaseInsensitiveContains("%00") ?? false)
                || (p.launchPath?.utf8.contains(0) ?? false)
                || (p.currentDirectoryPath.utf8.contains(0))
            if survives {
                #expect(throws: FolderToolError.self) {
                    try FolderToolHelpers.validateLaunchStrings(of: p)
                }
            } else {
                #expect(throws: Never.self) {
                    try FolderToolHelpers.validateLaunchStrings(of: p)
                }
            }
        }
    }

    @Test func environmentWithNULIsRejected() {
        let key = process(arguments: [])
        key.environment = ["BAD\u{0}KEY": "v"]
        #expect(throws: FolderToolError.self) {
            try FolderToolHelpers.validateLaunchStrings(of: key)
        }

        let value = process(arguments: [])
        value.environment = ["KEY": "bad\u{0}value"]
        #expect(throws: FolderToolError.self) {
            try FolderToolHelpers.validateLaunchStrings(of: value)
        }
    }

    @Test func errorIsReportedAsInvalidArguments() {
        let p = process(arguments: ["x\u{0}"])
        do {
            try FolderToolHelpers.validateLaunchStrings(of: p)
            Issue.record("expected a throw")
        } catch let error as FolderToolError {
            guard case .invalidArguments(let message) = error else {
                Issue.record("unexpected case: \(error)")
                return
            }
            #expect(message.contains("NUL"))
            #expect(!message.utf8.contains(0))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func cleanLaunchStillRuns() async throws {
        let p = process(arguments: ["hello"])
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.environment = ["PATH": "/usr/bin:/bin"]
        try await FolderToolHelpers.runProcessAsync(p)
        #expect(p.terminationStatus == 0)
    }
}
