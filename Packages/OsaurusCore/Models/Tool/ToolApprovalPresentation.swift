//
//  ToolApprovalPresentation.swift
//  osaurus
//
//  What the approval sheet says, built from the raw request: a plain action
//  title instead of the tool name, the workflow step's reason, the exact
//  command (or the arguments one click away), the protections that are
//  actually enforced, and the risk signals the app read from the command.
//
//  Pure so the copy is unit tested. Every "Enforced" row must be backed by
//  real routing or configuration passed in here; nothing is claimed from a
//  default the call does not use.
//

import Foundation

struct ToolApprovalPresentation: Equatable, Sendable {

    /// Sandbox facts that bound what a VM call can do.
    struct SandboxFacts: Equatable, Sendable {
        enum Network: Equatable, Sendable {
            case open
            /// Only the agent's approved domains.
            case limited
            case none
            /// Not resolvable for this call (e.g. a workflow environment).
            case unknown
        }

        var cpus: Int
        var memoryGB: Int
        var network: Network
    }

    /// Where a path on this Mac sits for a workflow run.
    enum PathOrigin: Equatable, Sendable {
        /// The run's own workspace, which Osaurus creates and keeps.
        case runWorkspace
        /// Elsewhere in the Osaurus data folder.
        case osaurusData
        /// The working folder of the agent the run or step works as.
        case workingFolder
        /// Picked in the run form or a dialog, bound in setup, or allowed
        /// while the run went.
        case chosen
        /// In none of the run's folders.
        case outside

        var isOsaurusManaged: Bool { self == .runWorkspace || self == .osaurusData }

        var tag: String {
            switch self {
            case .runWorkspace: L("Osaurus · run workspace")
            case .osaurusData: L("Osaurus data")
            case .workingFolder: L("Agent's working folder")
            case .chosen: L("Chosen for this run")
            case .outside: L("Outside this run's folders")
            }
        }

        var explanation: String {
            switch self {
            case .runWorkspace: L("This run's own workspace. Osaurus creates it and keeps it with the run.")
            case .osaurusData: L("Inside the Osaurus data folder.")
            case .workingFolder: L("The working folder of the agent this step runs as.")
            case .chosen: L("A folder or file this run was given: picked when it started, bound in setup, or allowed while it ran.")
            case .outside: L("Not in any of this run's folders. The step can't use it unless you allow that folder.")
            }
        }
    }

    /// One path on this Mac, in full, with where it sits for the run.
    struct PathEntry: Equatable, Sendable, Identifiable {
        /// "From" / "To" for a copy; nil for a single path.
        var role: String?
        var url: URL
        var origin: PathOrigin

        var id: String { (role ?? "") + "\u{0}" + url.path }
        /// The full path with the home folder as `~`.
        var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
    }

    /// The scopes a workflow run's file tools are held to, read from the
    /// run's bound execution context.
    struct WorkflowFacts: Equatable, Sendable {
        struct Place: Equatable, Sendable {
            var name: String
            var writes: Bool
            var url: URL? = nil
            var origin: PathOrigin = .chosen
        }

        /// Each folder or file on this Mac the run may use, its workspace first.
        var places: [Place]
        /// Replacing a file that's already on this Mac asks first.
        var asksBeforeReplacing: Bool
        /// Where a step's relative paths land. Nil when its file tools have
        /// no folder on this Mac.
        var folderRoot: URL? = nil
        /// `/workspace/...` paths go to the sandbox, not this Mac.
        var sandboxPathsRouteToVM: Bool = false

        /// `granted` are the run's host paths; `writable` the roots saves are
        /// held to (nil: saves aren't narrowed); `workspace` the run's own;
        /// `folderRoot` the folder relative paths resolve in.
        static func make(
            granted: [URL], writable: [URL]?, workspace: URL?, folderRoot: URL? = nil, asksBeforeReplacing: Bool,
            sandboxPathsRouteToVM: Bool = false, osaurusRoot: URL = OsaurusPaths.root()
        ) -> WorkflowFacts {
            let grantedPaths = granted.map(\.standardized.path)
            let writablePaths = writable.map { $0.map(\.standardized.path) }
            let workspacePath = workspace?.standardized.path
            let rootPath = folderRoot?.standardized.path
            let osaurusPath = osaurusRoot.standardized.path
            func origin(_ path: String) -> PathOrigin {
                if path == workspacePath { return .runWorkspace }
                if inside(path, osaurusPath) { return .osaurusData }
                if path == rootPath { return .workingFolder }
                return .chosen
            }
            var places: [Place] = []
            var seen: Set<String> = []
            func add(_ path: String, name: String, writes: Bool) {
                guard seen.insert(path).inserted else { return }
                places.append(
                    Place(name: name, writes: writes, url: URL(fileURLWithPath: path), origin: origin(path)))
            }
            if let workspace, let workspacePath, grantedPaths.contains(workspacePath) {
                add(workspacePath, name: WorkflowAccessScope.displayName(workspace), writes: true)
            }
            for (url, path) in zip(granted, grantedPaths) {
                let writes = writablePaths.map { roots in roots.contains { inside(path, $0) } } ?? true
                add(path, name: WorkflowAccessScope.displayName(url), writes: writes)
            }
            // Relative paths and paths under the folder root resolve there
            // without a grant, and saves there aren't narrowed.
            if let folderRoot, let rootPath, !grantedPaths.contains(where: { inside(rootPath, $0) }) {
                add(rootPath, name: WorkflowAccessScope.displayName(folderRoot), writes: true)
            }
            for path in writablePaths ?? [] where path != workspacePath && !grantedPaths.contains(path) {
                guard grantedPaths.contains(where: { inside(path, $0) }) else { continue }
                add(path, name: WorkflowHostWrite.displayName(URL(fileURLWithPath: path), roots: granted), writes: true)
            }
            return WorkflowFacts(
                places: places, asksBeforeReplacing: asksBeforeReplacing, folderRoot: folderRoot,
                sandboxPathsRouteToVM: sandboxPathsRouteToVM)
        }

        static func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

        /// The places beyond the run's own workspace.
        var placesBeyondWorkspace: [Place] { places.filter { $0.origin != .runWorkspace } }

        /// "dinos (read), dinos/png (write)".
        var accessList: String {
            placesBeyondWorkspace.map { $0.writes ? L("\($0.name) (write)") : L("\($0.name) (read)") }
                .joined(separator: ", ")
        }

        /// Every place with a known path, workspace first.
        var pathEntries: [PathEntry] {
            places.compactMap { place in place.url.map { PathEntry(role: nil, url: $0, origin: place.origin) } }
        }

        /// A tool's path argument as the run's file tools resolve it on this
        /// Mac (`FolderToolHelpers.resolvePath`): `~/` is home, relative is
        /// under the folder root. Nil when it doesn't land on this Mac.
        func resolve(_ raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let folderRoot, !trimmed.isEmpty else { return nil }
            if sandboxPathsRouteToVM, trimmed.hasPrefix("/workspace") { return nil }
            let expanded =
                trimmed == "~" || trimmed.hasPrefix("~/") ? (trimmed as NSString).expandingTildeInPath : trimmed
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardized }
            return folderRoot.appendingPathComponent(expanded).standardized
        }

        /// The innermost place holding `url` decides; none is `.outside`.
        func origin(of url: URL) -> PathOrigin {
            let path = url.standardized.path
            var best: (length: Int, origin: PathOrigin)?
            for place in places {
                guard let root = place.url?.standardized.path, Self.inside(path, root) else { continue }
                if root.count > (best?.length ?? -1) { best = (root.count, place.origin) }
            }
            return best?.origin ?? .outside
        }
    }

    struct Guarantee: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Enforced by the sandbox or the runtime; tagged "Enforced".
            case enforced
            /// Not a protection: the call reaches this Mac.
            case caution
            /// Neutral fact about where the call runs.
            case note
        }

        let kind: Kind
        let icon: String
        let title: String
        let detail: String
        /// The folders the row is about, each in full.
        var paths: [PathEntry] = []
    }

    let toolName: String
    let title: String
    let icon: String
    /// Who is waiting: the agent in a chat, or a workflow step.
    let subtitle: String
    /// The workflow step's purpose, quoted under the title.
    let reason: String?
    /// Plain prose shown under the action (a caller's own explanation, or
    /// the first sentence of an uncurated tool's description).
    let summary: String?
    /// One line, paths shortened.
    let preview: String?
    /// The `path` argument as given, for Copy Path when it can't be resolved.
    let rawPath: String?
    /// The paths a workflow file step uses on this Mac, resolved in full.
    let targets: [PathEntry]
    /// The exact command for shell tools (shown in full), or the arguments
    /// as pretty JSON for everything else (behind "Show details").
    let fullDetail: String?
    let isShell: Bool
    let guarantees: [Guarantee]
    /// Nil for tools that are not shell commands: there is nothing to scan.
    let risk: ShellCommandRiskScanner.Report?
    /// The lease menu item. The lease (`ToolPermissionRunScope`) ends with
    /// the agent's reply in a chat, or with the workflow run inside one.
    let leaseActionTitle: String

    // MARK: - Build

    static func make(
        toolName: String,
        description: String,
        descriptionIsForModel: Bool,
        argumentsJSON: String,
        surface: ToolExecutionSurface?,
        stepReason: String?,
        sandbox: SandboxFacts?,
        workflow: WorkflowFacts? = nil
    ) -> ToolApprovalPresentation {
        let arguments = parseArguments(argumentsJSON)
        let isShell = ToolDisplayName.shellToolNames.contains(toolName)
        let titled = ToolDisplayName.approvalTitle(for: toolName, arguments: argumentsJSON)
        let command = isShell ? (arguments["command"] as? String) : nil
        let background = (arguments["background"] as? Bool) == true

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String?
        if trimmedDescription.isEmpty {
            summary = nil
        } else if !descriptionIsForModel {
            summary = trimmedDescription
        } else {
            summary = titled.curated ? nil : firstSentence(ofModelText: trimmedDescription)
        }

        let preview: String?
        let fullDetail: String?
        if let command {
            preview = commandPreview(command)
            fullDetail = command
        } else {
            preview = (arguments["path"] as? String).map { shortenedPath($0) }
            fullDetail = prettyArguments(argumentsJSON)
        }

        let rawPath = command == nil ? (arguments["path"] as? String) : nil
        var targets: [PathEntry] = []
        if let workflow, surface != .sandboxVM, workflowScopedFileTools.contains(toolName) {
            let keys: [(String, String?)] =
                arguments["source"] != nil || arguments["destination"] != nil
                ? [("source", L("From")), ("destination", L("To"))] : [("path", nil)]
            targets = keys.compactMap { key, role in
                guard let raw = arguments[key] as? String, let url = workflow.resolve(raw) else { return nil }
                return PathEntry(role: role, url: url, origin: workflow.origin(of: url))
            }
        }

        let network = sandbox?.network ?? .unknown
        let risk = command.map {
            ShellCommandRiskScanner.scan(
                command: $0, surface: surface, networkAvailable: network != .none, background: background)
        }

        return ToolApprovalPresentation(
            toolName: toolName,
            title: titled.title,
            icon: icon(for: toolName, surface: surface),
            subtitle: stepReason != nil
                ? L("A workflow step is waiting for your approval.")
                : L("The agent is waiting for your approval."),
            reason: stepReason.flatMap(cleanReason),
            summary: summary,
            preview: preview,
            rawPath: rawPath,
            targets: targets,
            fullDetail: fullDetail,
            isShell: isShell,
            guarantees: guarantees(
                toolName: toolName, surface: surface, isShell: isShell, sandbox: sandbox, workflow: workflow,
                idleTimeout: background ? nil : intArgument(arguments["timeout"])),
            risk: risk,
            leaseActionTitle: stepReason != nil
                ? L("For the Rest of This Run") : L("For the Rest of This Reply")
        )
    }

    // MARK: - Guarantees

    /// File tools a workflow run holds to its folders (`FolderToolHelpers.resolvePath`).
    static let workflowScopedFileTools = WorkflowAccessScope.readTools.union(WorkflowAccessScope.writeTools)

    private static func guarantees(
        toolName: String, surface: ToolExecutionSurface?, isShell: Bool, sandbox: SandboxFacts?,
        workflow: WorkflowFacts?, idleTimeout: Int?
    ) -> [Guarantee] {
        var rows: [Guarantee] = []
        let workflowFileTool = workflow != nil && workflowScopedFileTools.contains(toolName)
        switch surface {
        case .sandboxVM:
            rows.append(
                Guarantee(
                    kind: .enforced, icon: "shield", title: L("Inside the sandbox only"),
                    detail: L("It sees only the sandbox's own folders, not the rest of your Mac.")))
            if workflow != nil {
                rows.append(
                    Guarantee(
                        kind: .enforced, icon: "eye.slash", title: L("Can't see the folders you chose"),
                        detail: L("Only files a workflow step copied into the sandbox are there.")))
            }
            if let sandbox {
                rows.append(
                    Guarantee(
                        kind: .enforced, icon: "memorychip",
                        title: sandbox.cpus == 1
                            ? L("Up to 1 CPU and \(sandbox.memoryGB) GB memory")
                            : L("Up to \(sandbox.cpus) CPUs and \(sandbox.memoryGB) GB memory"),
                        detail: L("The most the whole sandbox can use.")))
                switch sandbox.network {
                case .none:
                    rows.append(
                        Guarantee(
                            kind: .enforced, icon: "wifi.slash", title: L("No internet access"),
                            detail: L("The sandbox can't reach the internet.")))
                case .limited:
                    rows.append(
                        Guarantee(
                            kind: .enforced, icon: "network.badge.shield.half.filled",
                            title: L("Internet limited to approved sites"),
                            detail: L("Only the sites in this agent's Sandbox settings can be reached.")))
                case .open, .unknown:
                    break
                }
            }
        case .nativeHost:
            // A shell command reports this as a risk signal instead; a
            // workflow's file tool lists the folders it is held to below.
            if !isShell, !workflowFileTool {
                rows.append(
                    Guarantee(
                        kind: .caution, icon: "desktopcomputer", title: L("Runs on your Mac"),
                        detail: ToolExecutionSurface.nativeHost.consentDetail))
            }
        case .remoteServer:
            rows.append(
                Guarantee(
                    kind: .note, icon: "network", title: L("Runs on a remote server"),
                    detail: ToolExecutionSurface.remoteServer.consentDetail))
        case nil:
            break
        }
        if workflowFileTool, let workflow, surface != .sandboxVM {
            rows.append(
                Guarantee(
                    kind: .enforced, icon: "folder",
                    title: workflow.placesBeyondWorkspace.isEmpty
                        ? L("Only this run's workspace") : L("Access to \(workflow.accessList)"),
                    detail: L("This run's file steps can't read or save anywhere else on your Mac without asking you."),
                    paths: workflow.pathEntries))
            if WorkflowAccessScope.writeTools.contains(toolName) {
                if workflow.asksBeforeReplacing {
                    rows.append(
                        Guarantee(
                            kind: .enforced, icon: "arrow.triangle.2.circlepath", title: L("Asks before replacing a file"),
                            detail: L("If a file is already there, you're asked once per folder before it's replaced.")))
                }
                rows.append(
                    Guarantee(
                        kind: .note, icon: "trash.slash", title: L("No file deletion"),
                        detail: L("This tool creates and changes files; it doesn't delete them.")))
            }
        }
        if isShell, let idleTimeout, idleTimeout > 0 {
            rows.append(
                Guarantee(
                    kind: .enforced, icon: "clock",
                    title: L("Stopped after \(idleTimeout) seconds without output"),
                    detail: L("The command is ended if it goes quiet for that long.")))
        }
        return rows
    }

    // MARK: - Pieces

    private static func icon(for toolName: String, surface: ToolExecutionSurface?) -> String {
        if ToolDisplayName.shellToolNames.contains(toolName) { return "terminal.fill" }
        if toolName.hasPrefix("file_") || toolName.hasPrefix("sandbox_") && toolName.hasSuffix("_file") {
            return "doc.text.fill"
        }
        if surface == .remoteServer { return "network" }
        return "wrench.and.screwdriver.fill"
    }

    private static func cleanReason(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func intArgument(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// Pretty JSON without `\/` escapes; nil when there are no arguments.
    static func prettyArguments(_ json: String) -> String? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return trimmed.isEmpty ? nil : trimmed }
        if let dict = object as? [String: Any], dict.isEmpty { return nil }
        if let array = object as? [Any], array.isEmpty { return nil }
        guard
            let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return trimmed }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// One line: whitespace collapsed, long paths shortened to their last
    /// two parts, capped at `limit` characters.
    static func commandPreview(_ command: String, limit: Int = 72) -> String {
        let words = command.split(whereSeparator: { $0.isWhitespace }).map { shortenedPath(String($0)) }
        let line = words.joined(separator: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }

    /// `/workspace/runs/convert-1/main.py` → `…/convert-1/main.py`. URLs and
    /// short paths are left alone.
    static func shortenedPath(_ word: String) -> String {
        guard word.contains("/"), !word.contains("://") else { return word }
        let quotes = CharacterSet(charactersIn: "\"'")
        let core = word.trimmingCharacters(in: quotes)
        let parts = core.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2 else { return word }
        let leading = word.hasPrefix("\"") || word.hasPrefix("'") ? String(word.prefix(1)) : ""
        let trailing = word.hasSuffix("\"") || word.hasSuffix("'") ? String(word.suffix(1)) : ""
        let tailSlash = core.hasSuffix("/") ? "/" : ""
        return leading + "…/" + parts.suffix(2).joined(separator: "/") + tailSlash + trailing
    }

    /// The first sentence of a description written for the model, with
    /// markdown emphasis and code ticks removed.
    static func firstSentence(ofModelText text: String) -> String? {
        let firstParagraph = text.components(separatedBy: "\n\n").first ?? text
        var plain = firstParagraph.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        if let end = plain.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            plain = String(plain[..<end.upperBound])
        }
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 200 ? String(trimmed.prefix(199)) + "…" : trimmed
    }
}
