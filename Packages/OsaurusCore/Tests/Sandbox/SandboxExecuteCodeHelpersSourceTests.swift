//
//  SandboxExecuteCodeHelpersSourceTests.swift
//  osaurusTests
//
//  Pins the shape of `osaurus_tools.py` — the Python module staged
//  inside the sandbox for every `sandbox_execute_code` call.
//
//  Two layers of safety:
//    1. **Substring pins** ensure the helper functions and exports we
//       advertise to the model are still in the source string. Renaming
//       a helper without updating the description is the sneaky failure
//       mode here — the substring pin catches it.
//    2. **Optional `py_compile` smoke** invokes the host's `python3 -m
//       py_compile` (when available) on the embedded source. Catches
//       indentation / syntax errors that would only surface in the
//       sandbox at runtime. Skipped automatically when python3 isn't on
//       the test host's PATH so CI without python3 still passes.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxExecuteCodeHelpersSourceTests {

    // MARK: - Substring pins

    @Test
    func helperSource_definesExpectedFunctions() {
        let source = SandboxExecuteCodeHelpers.pythonSource
        let required = [
            "def read_file(",
            "def write_file(",
            "def edit_file(",
            "def search_files(",
            "def terminal(",
        ]
        for line in required {
            #expect(source.contains(line), "missing helper definition: `\(line)`")
        }
    }

    @Test
    func helperSource_doesNotExposeShareArtifact() {
        // share_artifact is intentionally excluded — calling it from a
        // script would silently no-op the chat artifact card. Pinning
        // the absence so a future "let's just add it back" change has
        // to update this test (and read the comment explaining why).
        let source = SandboxExecuteCodeHelpers.pythonSource
        #expect(!source.contains("def share_artifact("))
        #expect(!source.contains("\"share_artifact\""))
    }

    @Test
    func helperSource_advertisesOnlyExportedNames() {
        let source = SandboxExecuteCodeHelpers.pythonSource
        let exported = [
            "\"read_file\"",
            "\"write_file\"",
            "\"edit_file\"",
            "\"search_files\"",
            "\"terminal\"",
            "\"SandboxToolError\"",
        ]
        for entry in exported {
            #expect(source.contains(entry), "missing __all__ entry: \(entry)")
        }
    }

    @Test
    func helperSource_pinsBridgePathConstants() {
        // Hardcoded inside the helper — if `SandboxManager` ever changes
        // either the guest socket path or the token file path, this
        // test surfaces the drift before `sandbox_execute_code` would
        // hit a runtime "could not connect" error inside the sandbox.
        let source = SandboxExecuteCodeHelpers.pythonSource
        #expect(source.contains("/tmp/osaurus-bridge.sock"))
        #expect(source.contains("/run/osaurus/{user}.token"))
        #expect(source.contains("X-Osaurus-Script-Id"))
    }

    /// If a future edit accidentally truncates the raw-string literal
    /// (mismatched delimiter, runaway interpolation), the resulting
    /// source would shrink dramatically. Catch that here before it ships.
    @Test
    func helperSource_isNonTrivial() {
        let lineCount = SandboxExecuteCodeHelpers.pythonSource
            .components(separatedBy: "\n").count
        #expect(lineCount > 50, "helper source unexpectedly truncated: \(lineCount) lines")
    }

    /// The shell-escape `'\\''` trick downstream assumes single-byte
    /// chars in the script payload. An em-dash slipping into a comment
    /// would round-trip safely today but invites footguns later.
    @Test
    func helperSource_isAsciiOnly() {
        #expect(
            SandboxExecuteCodeHelpers.pythonSource.allSatisfy { $0.isASCII },
            "non-ASCII char snuck into helper source"
        )
    }

    // MARK: - py_compile smoke (skipped when python3 unavailable)

    /// If the test host has `python3` on its PATH, parse the embedded
    /// source via `compile(...)` so syntax errors surface at unit-test
    /// time instead of at sandbox runtime. The compile step is sandbox-
    /// safe (no execution).
    @Test
    func helperSource_compilesUnderHostPython3IfAvailable() throws {
        guard let python3 = Self.locatePython3() else {
            // No python3 on the host — skip silently. CI environments
            // without python3 should still pass this test.
            return
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus_tools_pin_\(UUID().uuidString).py")
        try SandboxExecuteCodeHelpers.pythonSource.write(
            to: tmpURL,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let (status, stderr) = try Self.runPython3Compile(python3, sourcePath: tmpURL.path)
        #expect(status == 0, "py_compile rejected osaurus_tools.py: \(stderr)")
    }

    /// Common candidate paths for the host's `python3`. We deliberately
    /// don't shell out to `which` — that adds a Process invocation per
    /// test and the candidates here cover macOS / Linux / Homebrew.
    private static func locatePython3() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Spawn `python3 <script>` with the staged source, capture stderr,
    /// and return `(exitStatus, stderr)`. Stdout is drained but not
    /// returned because `compile(...)` is silent on success.
    private static func runPython3Compile(
        _ python3Path: String,
        sourcePath: String
    ) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3Path)
        process.arguments = [
            "-c",
            "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')",
            sourcePath,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        let stderr =
            String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        return (process.terminationStatus, stderr)
    }
}
