//
//  Config.swift
//  osaurus
//
//  `osaurus config` — CLI companion for the declarative configuration
//  surface (`osaurus_config` / the loopback-only `/admin/config/*`
//  endpoints). Export the current Osaurus state as YAML, dry-run a
//  document against it, or apply one.
//
//  Security notes:
//   - The endpoints are loopback-only on the server side; this command
//     always targets 127.0.0.1.
//   - High-risk applies (prune deletions, screen/browser grants, channel
//     write enables, new MCP endpoints, ...) are rejected by the server
//     with the risk list until re-sent with confirmation — the CLI
//     surfaces that as an explicit `--yes` flag, mirroring the in-app
//     approval card.
//   - Secrets never travel through documents; provider creation opens
//     the credential sheet in the app.
//

import Foundation

public struct ConfigCommand: Command {
    public static let name = "config"

    public static func execute(args: [String]) async {
        guard let sub = args.first else {
            printUsage()
            exit(EXIT_FAILURE)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "export":
            await runExport(rest)
        case "schema":
            await runSchema(rest)
        case "plan":
            await runPlanOrApply(rest, apply: false)
        case "apply":
            await runPlanOrApply(rest, apply: true)
        case "help", "-h", "--help":
            printUsage()
            exit(EXIT_SUCCESS)
        default:
            fputs("Unknown config subcommand: \(sub)\n\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - export

    private static func runExport(_ args: [String]) async {
        var outputPath: String?
        var format = "yaml"
        var index = 0
        while index < args.count {
            switch args[index] {
            case "-o", "--output":
                index += 1
                guard index < args.count else {
                    fputs("--output requires a file path\n", stderr)
                    exit(EXIT_FAILURE)
                }
                outputPath = args[index]
            case "--format":
                index += 1
                guard index < args.count, ["yaml", "json"].contains(args[index].lowercased())
                else {
                    fputs("--format requires yaml or json\n", stderr)
                    exit(EXIT_FAILURE)
                }
                format = args[index].lowercased()
            default:
                fputs("Unknown option: \(args[index])\n", stderr)
                exit(EXIT_FAILURE)
            }
            index += 1
        }

        let port = await ServerControl.ensureServerReadyOrExit()
        let response = await request(
            port: port, path: "/admin/config/export?format=\(format)", body: nil)
        guard let document = response[format] as? String else {
            failFromResponse(response)
        }
        if let outputPath {
            do {
                try Data(document.utf8).write(
                    to: URL(fileURLWithPath: outputPath), options: .atomic)
                print("Exported configuration to \(outputPath)")
            } catch {
                fputs("Could not write \(outputPath): \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        } else {
            print(document)
        }
        exit(EXIT_SUCCESS)
    }

    // MARK: - schema

    private static func runSchema(_ args: [String]) async {
        var format = "yaml"
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--format":
                index += 1
                guard index < args.count, ["yaml", "json"].contains(args[index].lowercased())
                else {
                    fputs("--format requires yaml or json\n", stderr)
                    exit(EXIT_FAILURE)
                }
                format = args[index].lowercased()
            default:
                fputs("Unknown option: \(args[index])\n", stderr)
                exit(EXIT_FAILURE)
            }
            index += 1
        }

        let port = await ServerControl.ensureServerReadyOrExit()
        let response = await request(
            port: port, path: "/admin/config/schema?format=\(format)", body: nil)
        if format == "json" {
            guard let schema = response["json_schema"] as? [String: Any],
                let data = try? JSONSerialization.data(
                    withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
            else {
                failFromResponse(response)
            }
            print(String(decoding: data, as: UTF8.self))
        } else {
            guard let schema = response["schema"] as? String else {
                failFromResponse(response)
            }
            print(schema)
        }
        exit(EXIT_SUCCESS)
    }

    // MARK: - plan / apply

    private static func runPlanOrApply(_ args: [String], apply: Bool) async {
        var filePath: String?
        var prune = false
        var confirm = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--prune":
                prune = true
            case "--yes", "-y":
                confirm = true
            default:
                if args[index].hasPrefix("-") {
                    fputs("Unknown option: \(args[index])\n", stderr)
                    exit(EXIT_FAILURE)
                }
                guard filePath == nil else {
                    fputs("Only one document file may be given\n", stderr)
                    exit(EXIT_FAILURE)
                }
                filePath = args[index]
            }
            index += 1
        }
        guard let filePath else {
            fputs("Usage: osaurus config \(apply ? "apply" : "plan") <file.yaml> [--prune]\n", stderr)
            exit(EXIT_FAILURE)
        }
        // Server-side documents are capped at 512 KB (`OsaurusConfigTool
        // .maxDocumentBytes`); enforce the same limit here BEFORE loading the
        // file so a mistaken path (e.g. a model file) can't balloon the CLI.
        let maxDocumentBytes = 512 * 1024
        let fileURL = URL(fileURLWithPath: filePath)
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size]
            as? Int, size > maxDocumentBytes
        {
            fputs(
                "\(filePath) is \(size / 1024) KB — configuration documents are capped at "
                    + "\(maxDocumentBytes / 1024) KB.\n", stderr)
            exit(EXIT_FAILURE)
        }
        let yaml: String
        do {
            yaml = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            fputs("Could not read \(filePath): \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        let port = await ServerControl.ensureServerReadyOrExit()
        var body: [String: Any] = ["yaml": yaml, "prune": prune]
        if apply && confirm { body["confirm_high_risk"] = true }
        let path = apply ? "/admin/config/apply" : "/admin/config/plan"
        let response = await request(port: port, path: path, body: body)

        if let error = response["error"] as? [String: Any] {
            if let message = error["message"] as? String { fputs("\(message)\n", stderr) }
            if let issues = error["issues"] as? [String] {
                for issue in issues { fputs("  • \(issue)\n", stderr) }
            }
            exit(EXIT_FAILURE)
        }

        if !apply {
            if let summary = response["summary"] as? String { print(summary) }
            if response["high_risk"] as? Bool == true {
                print("\n! This plan contains high-risk changes — apply will require --yes.")
            }
            exit(EXIT_SUCCESS)
        }

        if response["status"] as? String == "high_risk_confirmation_required" {
            fputs("This document contains high-risk changes:\n", stderr)
            for risk in (response["risks"] as? [String]) ?? [] {
                fputs("  ! \(risk)\n", stderr)
            }
            if let summary = response["summary"] as? String {
                fputs("\nPlan:\n\(summary)\n", stderr)
            }
            fputs("\nRe-run with --yes to apply.\n", stderr)
            exit(EXIT_FAILURE)
        }

        if response["status"] as? String == "no_changes" {
            print(response["summary"] as? String ?? "No changes.")
            exit(EXIT_SUCCESS)
        }

        // Exit codes are script contracts: 0 = fully converged, 1 = at least
        // one change failed or was cancelled, 3 = applied but at least one
        // change needs a step finished in the app (secrets never travel
        // through this surface, so that state is expected — but a script
        // must be able to tell it apart from full convergence).
        var failures = 0
        var pendingUserActions = 0
        for row in (response["results"] as? [[String: Any]]) ?? [] {
            let section = row["section"] as? String ?? "?"
            let target = row["target"] as? String ?? "?"
            let status = row["status"] as? String ?? "?"
            var line = "\(statusSymbol(status)) \(section)/\(target): \(status)"
            if let message = row["message"] as? String { line += " — \(message)" }
            print(line)
            if status == "failed" || status == "cancelled" { failures += 1 }
            if status == "needs_user_action" { pendingUserActions += 1 }
        }
        if let note = response["note"] as? String { print("note: \(note)") }
        if failures > 0 { exit(EXIT_FAILURE) }
        if pendingUserActions > 0 { exit(3) }
        exit(EXIT_SUCCESS)
    }

    private static func statusSymbol(_ status: String) -> String {
        switch status {
        case "done": return "✓"
        case "started": return "▶"
        case "failed", "cancelled": return "✗"
        case "needs_user_action": return "…"
        default: return "•"
        }
    }

    // MARK: - HTTP

    /// GET (nil body) or POST (JSON body) against the loopback admin
    /// endpoint, returning the parsed JSON object. Exits on transport
    /// errors; HTTP-level errors are returned for the caller to render.
    private static func request(
        port: Int, path: String, body: [String: Any]?
    ) async -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            fputs("Invalid URL\n", stderr)
            exit(EXIT_FAILURE)
        }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            request.httpMethod = "GET"
        }
        // Apply can start downloads and open in-app credential sheets that
        // wait on the user; keep a generous ceiling.
        request.timeoutInterval = 600

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                fputs("Unexpected response from server\n", stderr)
                exit(EXIT_FAILURE)
            }
            return object
        } catch {
            fputs("Could not reach the Osaurus server: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func failFromResponse(_ response: [String: Any]) -> Never {
        if let error = response["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            fputs("\(message)\n", stderr)
        } else {
            fputs("Unexpected response from server\n", stderr)
        }
        exit(EXIT_FAILURE)
    }

    private static func printUsage() {
        print(
            """
            osaurus config - declarative Osaurus configuration

            Usage:
              osaurus config export [-o file] [--format yaml|json]
                                      Print (or save) the current configuration.
                                      Secrets are never included.
              osaurus config schema [--format yaml|json]
                                      Print the document schema (YAML reference or
                                      machine-readable JSON Schema).
              osaurus config plan <file> [--prune]
                                      Dry-run: show what applying the document would change.
                                      The file may be YAML or JSON.
              osaurus config apply <file> [--prune] [--yes]
                                      Apply the document. --prune deletes entries not listed
                                      in the document's declared sections (destructive).
                                      High-risk changes (prune deletions, screen/browser
                                      grants, relay exposure, channel write enables, new
                                      MCP endpoints, ...) are refused until confirmed
                                      with --yes.

            Documents are merge-by-default: keys absent from the document are left
            unchanged; explicit null clears an override. Entities match by name.

            Exit codes (apply): 0 = fully applied; 1 = a change failed or was
            cancelled; 3 = applied, but a step must be finished in the Osaurus
            app (e.g. credentials — secrets never travel through documents).
            """
        )
    }
}
