//
//  EvalSuite.swift
//  OsaurusEvalsKit
//
//  Loads a directory of `*.json` eval cases. Stays a thin wrapper
//  around `JSONDecoder` so contributors can drop a new case file in
//  `Suites/Preflight/` and the runner picks it up automatically — no
//  Swift edit, no test target rebuild.
//

import Foundation

public struct EvalSuite: Sendable {
    public let directory: URL
    public let cases: [EvalCase]
    /// Filenames the loader couldn't decode, paired with the underlying
    /// error message. Surfaced to the runner instead of throwing so one
    /// malformed case doesn't block an entire suite run — the report
    /// flags them as `errored` rows so they stay visible.
    public let decodeFailures: [(filename: String, error: String)]

    public init(
        directory: URL,
        cases: [EvalCase],
        decodeFailures: [(filename: String, error: String)] = []
    ) {
        self.directory = directory
        self.cases = cases
        self.decodeFailures = decodeFailures
    }

    /// Walk `directory` (non-recursive) for `*.json` files and decode
    /// each as an `EvalCase`. Files are sorted lexicographically so
    /// reports are stable across runs and re-orderings of the
    /// filesystem listing.
    public static func load(from directory: URL) throws -> EvalSuite {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw EvalSuiteError.notADirectory(directory)
        }

        let urls =
            try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        var cases: [EvalCase] = []
        var failures: [(String, String)] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let item = try decoder.decode(EvalCase.self, from: data)
                cases.append(item)
            } catch {
                failures.append((url.lastPathComponent, String(describing: error)))
            }
        }
        return EvalSuite(directory: directory, cases: cases, decodeFailures: failures)
    }
}

public enum EvalSuiteError: Error, LocalizedError {
    case notADirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "Suite path is not a directory: \(url.path)"
        }
    }
}
