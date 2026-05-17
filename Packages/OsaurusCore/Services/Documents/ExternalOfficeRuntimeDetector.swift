//
//  ExternalOfficeRuntimeDetector.swift
//  osaurus
//
//  Finds optional office-suite runtimes for future high-fidelity document
//  work. The detector only verifies executable discovery and bounded
//  `--version` metadata; it never sends document bytes to the runtime.
//

import Darwin
import Foundation

/// Identifies the office-suite family so later document code can choose
/// conservative compatibility paths without making the runtime mandatory.
public enum ExternalOfficeRuntimeKind: String, Equatable, Sendable {
    case libreOffice = "LibreOffice"
    case openOffice = "OpenOffice"
}

/// Records where a candidate came from because explicit configuration is a
/// stronger signal than a generic PATH hit when future consumers explain UI
/// or diagnostics.
public enum ExternalOfficeRuntimeSource: Equatable, Sendable {
    case explicitURL
    case environmentVariable(name: String)
    case applicationBundle
    case searchPath
}

/// Captures the bounded `--version` probe outcome without retaining raw
/// process output that could grow large or accidentally include host details.
public struct ExternalOfficeVersionProbe: Equatable, Sendable {
    /// Distinguishes a real version response from launch and timeout failures
    /// without exposing the raw process output.
    public enum Status: Equatable, Sendable {
        case exited(status: Int32)
        case launchFailed
        case timedOut
    }

    public let status: Status
    public let capturedOutputBytes: Int
    public let outputWasTruncated: Bool

    public init(
        status: Status,
        capturedOutputBytes: Int,
        outputWasTruncated: Bool
    ) {
        self.status = status
        self.capturedOutputBytes = capturedOutputBytes
        self.outputWasTruncated = outputWasTruncated
    }
}

/// Describes a discovered runtime while keeping unavailable results cheap and
/// explicit; absence of this optional dependency must never block parsing.
public struct ExternalOfficeRuntimeSnapshot: Equatable, Sendable {
    public let available: Bool
    public let kind: ExternalOfficeRuntimeKind?
    public let version: String?
    public let executableURL: URL?
    public let source: ExternalOfficeRuntimeSource?
    public let versionProbe: ExternalOfficeVersionProbe?

    public init(
        available: Bool,
        kind: ExternalOfficeRuntimeKind?,
        version: String?,
        executableURL: URL?,
        source: ExternalOfficeRuntimeSource?,
        versionProbe: ExternalOfficeVersionProbe?
    ) {
        self.available = available
        self.kind = kind
        self.version = version
        self.executableURL = executableURL
        self.source = source
        self.versionProbe = versionProbe
    }

    public static let unavailable = ExternalOfficeRuntimeSnapshot(
        available: false,
        kind: nil,
        version: nil,
        executableURL: nil,
        source: nil,
        versionProbe: nil
    )
}

/// Performs narrow, side-effect-light runtime discovery for LibreOffice and
/// OpenOffice style `soffice` executables ahead of future conversion support.
public struct ExternalOfficeRuntimeDetector: Sendable {
    /// Keeps each filesystem probe explicit so tests and future callers can
    /// verify ordering without mutating global process environment.
    public struct Candidate: Equatable, Sendable {
        public let executableURL: URL
        public let kind: ExternalOfficeRuntimeKind?
        public let source: ExternalOfficeRuntimeSource

        public init(
            executableURL: URL,
            kind: ExternalOfficeRuntimeKind?,
            source: ExternalOfficeRuntimeSource
        ) {
            self.executableURL = executableURL
            self.kind = kind
            self.source = source
        }
    }

    /// Carries all external inputs for detection so production behavior stays
    /// deterministic and tests can use temporary fake executables.
    public struct Configuration: Sendable {
        public var explicitExecutableURL: URL?
        public var environment: [String: String]
        public var commonApplicationCandidates: [Candidate]
        public var versionProbeTimeoutSeconds: TimeInterval
        public var maxVersionProbeOutputBytes: Int

        public init(
            explicitExecutableURL: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            commonApplicationCandidates: [Candidate] = Candidate.defaultApplicationCandidates,
            versionProbeTimeoutSeconds: TimeInterval = 2.0,
            maxVersionProbeOutputBytes: Int = 4_096
        ) {
            self.explicitExecutableURL = explicitExecutableURL
            self.environment = environment
            self.commonApplicationCandidates = commonApplicationCandidates
            self.versionProbeTimeoutSeconds = versionProbeTimeoutSeconds
            self.maxVersionProbeOutputBytes = maxVersionProbeOutputBytes
        }
    }

    /// Preferred environment knobs for a user or integration test that wants
    /// to point Osaurus at a specific office runtime.
    public static let environmentExecutableKeys = [
        "OSAURUS_OFFICE_RUNTIME_URL",
        "OSAURUS_OFFICE_RUNTIME_PATH",
    ]

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func detect() async -> ExternalOfficeRuntimeSnapshot {
        for candidate in orderedCandidates() {
            if let snapshot = await probe(candidate) {
                return snapshot
            }
        }
        return .unavailable
    }

    private func orderedCandidates() -> [Candidate] {
        var candidates: [Candidate] = []

        if let explicitExecutableURL = configuration.explicitExecutableURL {
            candidates.append(
                Candidate(
                    executableURL: explicitExecutableURL,
                    kind: Self.kindHint(from: explicitExecutableURL),
                    source: .explicitURL
                )
            )
        }

        for key in Self.environmentExecutableKeys {
            guard let value = configuration.environment[key],
                let url = Self.executableURL(fromEnvironmentValue: value)
            else {
                continue
            }
            candidates.append(
                Candidate(
                    executableURL: url,
                    kind: Self.kindHint(from: url),
                    source: .environmentVariable(name: key)
                )
            )
        }

        candidates.append(contentsOf: configuration.commonApplicationCandidates)
        candidates.append(contentsOf: pathCandidates())
        return candidates
    }

    private func pathCandidates() -> [Candidate] {
        guard let path = configuration.environment["PATH"] else {
            return []
        }

        return
            path
            .split(separator: ":", omittingEmptySubsequences: true)
            .compactMap { directory in
                let directoryPath = String(directory)
                guard directoryPath.hasPrefix("/") else {
                    return nil
                }

                let executableURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
                    .appendingPathComponent("soffice")
                    .standardizedFileURL
                return Candidate(
                    executableURL: executableURL,
                    kind: Self.kindHint(from: executableURL),
                    source: .searchPath
                )
            }
    }

    private func probe(
        _ candidate: Candidate
    ) async -> ExternalOfficeRuntimeSnapshot? {
        let executableURL = candidate.executableURL.standardizedFileURL
        guard Self.isExecutableFile(executableURL) else {
            return nil
        }

        let probeResult = await Self.runVersionProbe(
            executableURL: executableURL,
            timeoutSeconds: configuration.versionProbeTimeoutSeconds,
            maxOutputBytes: configuration.maxVersionProbeOutputBytes
        )
        let parsed = probeResult.output.flatMap(Self.parseVersionOutput)

        return ExternalOfficeRuntimeSnapshot(
            available: true,
            kind: parsed?.kind ?? candidate.kind ?? Self.kindHint(from: executableURL),
            version: parsed?.version,
            executableURL: executableURL,
            source: candidate.source,
            versionProbe: probeResult.metadata
        )
    }

    private static func executableURL(fromEnvironmentValue value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            guard url.isFileURL else {
                return nil
            }
            return url.standardizedFileURL
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = url.path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    static func parseVersionOutput(_ output: String) -> ParsedVersion? {
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOutput.isEmpty else {
            return nil
        }

        let lowercasedOutput = normalizedOutput.lowercased()
        let kind: ExternalOfficeRuntimeKind?
        if lowercasedOutput.contains("libreoffice") {
            kind = .libreOffice
        } else if lowercasedOutput.contains("openoffice") {
            kind = .openOffice
        } else {
            kind = nil
        }

        let version =
            normalizedOutput
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .compactMap { versionPrefix(in: String($0)) }
            .first

        if kind == nil, version == nil {
            return nil
        }
        return ParsedVersion(kind: kind, version: version)
    }

    private static func versionPrefix(in token: String) -> String? {
        guard let first = token.unicodeScalars.first,
            CharacterSet.decimalDigits.contains(first)
        else {
            return nil
        }

        var result = String.UnicodeScalarView()
        var sawDot = false
        for scalar in token.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "."
                || scalar == "-" || scalar == "_"
            {
                if scalar == "." {
                    sawDot = true
                }
                result.append(scalar)
            } else {
                break
            }
        }

        let version = String(result).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return sawDot && !version.isEmpty ? version : nil
    }

    private static func kindHint(from url: URL) -> ExternalOfficeRuntimeKind? {
        let lowercasedPath = url.path.lowercased()
        if lowercasedPath.contains("libreoffice") {
            return .libreOffice
        }
        if lowercasedPath.contains("openoffice") {
            return .openOffice
        }
        return nil
    }

    private static func runVersionProbe(
        executableURL: URL,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int
    ) async -> VersionProbeResult {
        await Task.detached(priority: .utility) {
            runVersionProbeSynchronously(
                executableURL: executableURL,
                timeoutSeconds: timeoutSeconds,
                maxOutputBytes: maxOutputBytes
            )
        }.value
    }

    private static func runVersionProbeSynchronously(
        executableURL: URL,
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int
    ) -> VersionProbeResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalOfficeRuntime-\(UUID().uuidString).version")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            return VersionProbeResult(
                metadata: ExternalOfficeVersionProbe(
                    status: .launchFailed,
                    capturedOutputBytes: 0,
                    outputWasTruncated: false
                ),
                output: nil
            )
        }
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let inputHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { try? inputHandle?.close() }
        process.standardInput = inputHandle

        do {
            try process.run()
        } catch {
            return VersionProbeResult(
                metadata: ExternalOfficeVersionProbe(
                    status: .launchFailed,
                    capturedOutputBytes: 0,
                    outputWasTruncated: false
                ),
                output: nil
            )
        }

        if waitForExit(process, timeoutSeconds: timeoutSeconds) == false {
            stop(process)
            let captured = capturedOutput(at: outputURL, maxBytes: maxOutputBytes)
            return VersionProbeResult(
                metadata: ExternalOfficeVersionProbe(
                    status: .timedOut,
                    capturedOutputBytes: captured.bytes,
                    outputWasTruncated: captured.truncated
                ),
                output: nil
            )
        }

        let captured = capturedOutput(at: outputURL, maxBytes: maxOutputBytes)
        return VersionProbeResult(
            metadata: ExternalOfficeVersionProbe(
                status: .exited(status: process.terminationStatus),
                capturedOutputBytes: captured.bytes,
                outputWasTruncated: captured.truncated
            ),
            output: process.terminationStatus == 0 && captured.truncated == false
                ? captured.text : nil
        )
    }

    private static func waitForExit(
        _ process: Process,
        timeoutSeconds: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 0))
        while process.isRunning {
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: min(0.01, max(0.001, deadline.timeIntervalSinceNow)))
        }
        return true
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else {
            return
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private static func capturedOutput(
        at url: URL,
        maxBytes: Int
    ) -> CapturedOutput {
        let readLimit = max(0, maxBytes)
        guard readLimit > 0,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return CapturedOutput(text: "", bytes: 0, truncated: false)
        }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: readLimit + 1)) ?? Data()
        let truncated = data.count > readLimit
        let limitedData = truncated ? Data(data.prefix(readLimit)) : data
        return CapturedOutput(
            text: String(data: limitedData, encoding: .utf8) ?? "",
            bytes: limitedData.count,
            truncated: truncated
        )
    }
}

extension ExternalOfficeRuntimeDetector.Candidate {
    /// Default macOS app bundle probes keep production discovery useful
    /// without adding a runtime dependency or launching conversions.
    public static let defaultApplicationCandidates: [Self] = [
        .init(
            executableURL: URL(
                fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            ),
            kind: .libreOffice,
            source: .applicationBundle
        ),
        .init(
            executableURL: URL(
                fileURLWithPath: "/Applications/OpenOffice.app/Contents/MacOS/soffice"
            ),
            kind: .openOffice,
            source: .applicationBundle
        ),
    ]
}

struct ParsedVersion: Equatable, Sendable {
    let kind: ExternalOfficeRuntimeKind?
    let version: String?
}

private struct VersionProbeResult: Sendable {
    let metadata: ExternalOfficeVersionProbe
    let output: String?
}

private struct CapturedOutput: Sendable {
    let text: String
    let bytes: Int
    let truncated: Bool
}
