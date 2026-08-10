//
//  Doctor.swift
//  OsaurusCLI
//
//  Read-only installation and server-start diagnostics.
//

import Foundation

public struct DoctorCommand: Command {
    public static let name = "doctor"

    struct Options: Equatable {
        let port: Int?
        let json: Bool
        let redact: Bool
        let verifySignatures: Bool
    }

    enum ArgumentError: Error, Equatable {
        case invalid(String)
    }

    public static func execute(args: [String]) async {
        let options: Options
        do {
            options = try parseOptions(args)
        } catch let error as ArgumentError {
            let detail: String
            switch error {
            case .invalid(let message):
                detail = message
            }
            fputs("osaurus doctor: \(detail)\n", stderr)
            fputs(
                "Usage: osaurus doctor [--port 1...65535] [--json] [--redact] [--verify-signatures]\n",
                stderr
            )
            exit(EXIT_FAILURE)
        } catch {
            fputs("osaurus doctor: invalid arguments\n", stderr)
            exit(EXIT_FAILURE)
        }

        let report = await InstallationDiagnostics.collect(
            requestedPort: options.port,
            includeSignatureChecks: options.verifySignatures
        )
        let output = options.redact ? report.redacted() : report
        if options.json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(output)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw EncodingError.invalidValue(
                        data,
                        .init(codingPath: [], debugDescription: "JSON output was not UTF-8")
                    )
                }
                print(text)
            } catch {
                fputs("osaurus doctor: could not encode diagnostic JSON\n", stderr)
                exit(EXIT_FAILURE)
            }
        } else {
            print(render(output))
        }
        let usable = report.diagnosis == .healthy || report.diagnosis == .serverNotRunning
        exit(usable ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    static func parseOptions(_ args: [String]) throws -> Options {
        var port: Int?
        var json = false
        var redact = false
        var verifySignatures = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--port" where index + 1 < args.count:
                guard let value = Int(args[index + 1]), (1 ... 65_535).contains(value) else {
                    throw ArgumentError.invalid("--port must be an integer from 1 through 65535")
                }
                port = value
                index += 2
            case "--port":
                throw ArgumentError.invalid("--port requires a value")
            case "--json":
                json = true
                index += 1
            case "--redact":
                redact = true
                index += 1
            case "--verify-signatures":
                verifySignatures = true
                index += 1
            default:
                throw ArgumentError.invalid("unknown argument `\(args[index])`")
            }
        }
        return Options(
            port: port,
            json: json,
            redact: redact,
            verifySignatures: verifySignatures
        )
    }

    public static func render(_ report: InstallationDiagnosticReport) -> String {
        var lines = [
            "Osaurus installation doctor",
            "Diagnosis: \(report.diagnosis.rawValue)",
            "CLI: \(report.cliPath) (\(versionLabel(report.cliVersion, build: report.cliBuild)))",
            "Server: http://127.0.0.1:\(report.requestedPort) — \(report.serverHealthy ? "healthy" : "unavailable")",
        ]
        if let owner = report.portOwner { lines.append("Port owner: \(owner)") }
        if report.apps.isEmpty {
            lines.append("Apps: none discovered")
        } else {
            lines.append("Apps:")
            for app in report.apps {
                let markers = [app.isCompanion ? "companion" : nil, app.isRunning ? "running" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                lines.append(
                    "- \(app.path) (\(versionLabel(app.version, build: app.build)))"
                        + (markers.isEmpty ? "" : " [\(markers)]")
                        + " signature=\(app.signature.rawValue) notarization=\(app.notarization.rawValue)"
                )
            }
        }
        lines.append(
            "Models: \(report.modelCountComplete ? "" : "at least ")\(report.modelCount) at \(report.modelRoot)"
                + " [\(report.modelRootSource)]"
                + (report.modelRootReadable ? "" : " (not readable)")
        )
        lines.append("Next step: \(report.recommendation)")
        return lines.joined(separator: "\n")
    }

    private static func versionLabel(_ version: String?, build: String?) -> String {
        let version = version ?? "development/unproven"
        guard let build, !build.isEmpty else { return version }
        return "\(version), build \(build)"
    }
}
