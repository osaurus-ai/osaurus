//
//  SandboxPluginRegisterTool.swift
//  osaurus
//
//  Builtin sandbox tool for hot-registering agent-created plugins.
//  Reads plugin.json from the agent's plugins/ directory, packages
//  on-disk files, and hands the payload to `SandboxPluginRegistration`
//  which performs the shared validate -> save -> install -> hot-register
//  pipeline used by both this tool and the host-API endpoint.
//

import Foundation

struct SandboxPluginRegisterTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_plugin_register"
    let description =
        "Register a sandbox plugin you created. Reads `plugin.json` from your "
        + "`plugins/{plugin_id}/` directory, installs dependencies, and makes tools available "
        + "immediately in this session. The plugin must already be written to disk before this call."

    let agentId: String
    let agentName: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "plugin_id": .object([
                    "type": .string("string"),
                    "description": .string("Plugin directory name under `plugins/` (e.g. `notion`)."),
                ])
            ]),
            "required": .array([.string("plugin_id")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pluginIdReq = requireString(
            args,
            "plugin_id",
            expected: "plugin directory name under `plugins/`",
            tool: name
        )
        guard case .value(let pluginId) = pluginIdReq else {
            return pluginIdReq.failureEnvelope ?? ""
        }

        switch loadPlugin(pluginId: pluginId) {
        case .envelope(let envelope):
            return envelope
        case .plugin(let plugin):
            return await runRegistration(plugin: plugin)
        }
    }

    // MARK: - Registration

    private func runRegistration(plugin: SandboxPlugin) async -> String {
        do {
            let outcome = try await SandboxPluginRegistration.register(
                plugin: plugin,
                agentId: agentId,
                source: .agentTool
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "plugin_id": outcome.plugin.id,
                    "plugin_name": outcome.plugin.name,
                    "tools": outcome.registeredTools.map {
                        ["name": $0.name, "description": $0.description]
                    },
                ]
            )
        } catch let error as SandboxPluginRegistrationError {
            return ToolEnvelope.failure(
                kind: error.toolEnvelopeKind,
                message: error.message,
                tool: name,
                retryable: error.retryable
            )
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Plugin registration failed: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
    }

    // MARK: - File Loading

    /// Either the parsed + packaged plugin, or a fully-formed failure
    /// envelope ready to return straight from `execute`.
    private enum LoadPluginResult {
        case plugin(SandboxPlugin)
        case envelope(String)
    }

    /// Reads `plugin.json` and packages every readable text file under
    /// the plugin directory.
    private func loadPlugin(pluginId: String) -> LoadPluginResult {
        let pluginDir = OsaurusPaths.containerWorkspace()
            .appendingPathComponent("agents/\(agentName)/plugins/\(pluginId)")
        let pluginFile = pluginDir.appendingPathComponent("plugin.json")

        guard FileManager.default.fileExists(atPath: pluginFile.path) else {
            return failure(
                kind: .executionError,
                message: "plugin.json not found at plugins/\(pluginId)/plugin.json"
            )
        }

        let plugin: SandboxPlugin
        do {
            let data = try Data(contentsOf: pluginFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            plugin = try decoder.decode(SandboxPlugin.self, from: data)
        } catch {
            // `localizedDescription` on a DecodingError is the generic "The
            // data couldn't be read because it isn't in the correct format."
            // — observed live driving a model into four identical blind
            // retries. Name the actual defect (bad JSON syntax with the
            // parser's position detail, or the missing/mistyped key and its
            // path) so a single fixed rewrite is possible.
            return failure(
                kind: .invalidArgs,
                message: "Invalid plugin.json: \(Self.decodeFailureDetail(error))"
            )
        }

        // Package text files in the directory (excluding plugin.json) into
        // plugin.files so the install mechanism can seed them correctly.
        // Binary files are rejected up-front: `plugin.files` is `[String:
        // String]` so they would silently disappear on a library-driven
        // reinstall, leaving the agent with a half-broken plugin.
        let collected = collectFiles(in: pluginDir)
        if !collected.binary.isEmpty {
            let list = collected.binary.sorted().joined(separator: ", ")
            return failure(
                kind: .invalidArgs,
                message:
                    "Binary files in `plugins/\(pluginId)/` cannot be packaged "
                    + "into a sandbox plugin (`plugin.files` is text-only). "
                    + "Either remove them, regenerate them at install time in `setup`, "
                    + "or fetch them from a setup-allowlisted host. Offending files: \(list)."
            )
        }

        var merged = plugin.files ?? [:]
        // Authored entries in plugin.json win over auto-discovered files.
        for (path, content) in collected.text where merged[path] == nil {
            merged[path] = content
        }
        var packaged = plugin
        packaged.files = merged.isEmpty ? nil : merged
        return .plugin(packaged)
    }

    private func failure(kind: ToolEnvelope.Kind, message: String) -> LoadPluginResult {
        .envelope(
            ToolEnvelope.failure(
                kind: kind,
                message: message,
                tool: name,
                retryable: false
            )
        )
    }

    /// Actionable text for a `plugin.json` decode failure. `DecodingError`
    /// cases name the offending key/type and its coding path; anything else
    /// (typically `NSCocoaErrorDomain` 3840 for malformed JSON) carries the
    /// parser's position detail in `debugDescription`/`userInfo` — e.g.
    /// "Badly formed object around line 20, column 26" for an unescaped
    /// quote inside a string value.
    static func decodeFailureDetail(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let joined = codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? key.stringValue
            }.joined(separator: ".")
            return joined.isEmpty ? "(root)" : joined
        }
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "missing required key `\(key.stringValue)` at \(path(context.codingPath))."
        case let DecodingError.typeMismatch(type, context):
            return "wrong type at \(path(context.codingPath)) — expected \(type)."
        case let DecodingError.valueNotFound(type, context):
            return "null/missing value at \(path(context.codingPath)) — expected \(type)."
        case let DecodingError.dataCorrupted(context):
            let underlying = (context.underlyingError as NSError?)?
                .userInfo[NSDebugDescriptionErrorKey] as? String
            let detail = underlying ?? context.debugDescription
            return "malformed JSON — \(detail) Check for unescaped quotes/newlines in string values."
        default:
            let ns = error as NSError
            let debug = ns.userInfo[NSDebugDescriptionErrorKey] as? String
            return debug ?? ns.localizedDescription
        }
    }

    /// Recursively collects regular files under `directory`. Text files are
    /// returned keyed by their path relative to `directory`; UTF-8 decode
    /// failures land in `binary` so the caller can surface them.
    private func collectFiles(in directory: URL) -> (text: [String: String], binary: [String]) {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return ([:], []) }

        var text: [String: String] = [:]
        var binary: [String] = []
        let basePath = directory.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }

            let relativePath = String(
                fileURL.standardizedFileURL.path.dropFirst(basePath.count + 1)
            )
            if relativePath == "plugin.json" { continue }

            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                text[relativePath] = content
            } else {
                binary.append(relativePath)
            }
        }
        return (text, binary)
    }
}
