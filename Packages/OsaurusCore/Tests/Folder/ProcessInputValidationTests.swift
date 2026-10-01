import Foundation
import Testing

@testable import OsaurusCore

struct ProcessInputValidationTests {
    @Test func rejectsNulArgumentsWithoutLaunching() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.arguments = ["-c", "true\u{0}false"]
        do {
            try await FolderToolHelpers.runProcessAsync(process)
            Issue.record("Expected invalid process argument")
        } catch {
            #expect(error as? ProcessInputValidation.InvalidInput == .argument(1))
            #expect(!process.isRunning)
            #expect(process.terminationHandler == nil)
        }
    }

    @Test func rejectsNulEnvironmentWithoutExposingContents() throws {
        let process = Process()
        process.environment = ["secret\u{0}key": "value"]
        #expect(throws: ProcessInputValidation.InvalidInput.environmentKey) {
            try ProcessInputValidation.validate(process)
        }
        process.environment = ["key": "secret\u{0}value"]
        #expect(throws: ProcessInputValidation.InvalidInput.environmentValue) {
            try ProcessInputValidation.validate(process)
        }
    }

    @Test func preservesValidArgumentsAndEnvironment() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        let arguments = ["%s", "line one\n雪\t'\"\\"]
        let environment = ["PROBE_VALUE": "line one\n雪"]
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try await FolderToolHelpers.runProcessAsync(process)
        #expect(process.terminationStatus == 0)
        #expect(process.arguments == arguments)
        #expect(process.environment == environment)
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == arguments[1])
    }
}
