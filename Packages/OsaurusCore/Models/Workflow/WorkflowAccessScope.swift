//
//  WorkflowAccessScope.swift
//  osaurus
//
//  What a workflow touches on this Mac, read from its definition: the
//  folders and files the person picks or binds, what its steps read from
//  and save into each, whether its shell work runs in the sandbox, and the
//  steps whose reach no folder limits. One model feeds both the run's
//  write enforcement (`resolved`) and every sentence the app says about
//  access (Designer, permission sheet, run form, listings), so the copy
//  cannot claim less than the runtime allows.
//

import Foundation

public struct WorkflowAccessScope: Equatable, Sendable {

    /// Where a folder or file comes from.
    public enum SourceRef: Hashable, Sendable {
        /// A `format: folder|file` property of the input schema.
        case input(String)
        /// A `folder` / `file` field of a dialog step.
        case dialog(node: String, field: String)
        /// A declared folder, bound once in setup (`{{folders.<key>}}`).
        case folder(String)
    }

    public struct Source: Equatable, Sendable, Identifiable {
        public var ref: SourceRef
        /// The field or folder label, as the person sees it.
        public var label: String
        public var isFile: Bool
        /// A step reads from it.
        public var reads: Bool
        /// Paths relative to the source that steps save into. "" is the
        /// whole folder; "png" a subfolder; "report.pdf" one file.
        public var writeSubpaths: [String]
        /// A step overwrites or edits files that already exist there.
        public var replaces: Bool

        public var id: String {
            switch ref {
            case .input(let key): return "input:\(key)"
            case .dialog(let node, let field): return "dialog:\(node).\(field)"
            case .folder(let key): return "folder:\(key)"
            }
        }

        public var writes: Bool { !writeSubpaths.isEmpty }
        public var writesAnywhere: Bool { writeSubpaths.contains("") }
    }

    public var sources: [Source]
    /// Shell and Python steps run in the workflow's sandbox.
    public var runsInSandbox: Bool
    /// Steps whose reach on this Mac no folder limits: Mac-control tools,
    /// AppleScript, plugin and MCP tools, other agents and workflows. Named
    /// as the person would recognize them.
    public var hostReach: [String]
    /// A tool step reads or saves at a path computed at run time, so the run
    /// asks to allow that folder.
    public var asksToRead: Bool
    public var asksToWrite: Bool
    public var mayAskForMoreFolders: Bool { asksToRead || asksToWrite }

    public init(
        sources: [Source] = [], runsInSandbox: Bool = false, hostReach: [String] = [],
        asksToRead: Bool = false, asksToWrite: Bool = false
    ) {
        self.sources = sources
        self.runsInSandbox = runsInSandbox
        self.hostReach = hostReach
        self.asksToRead = asksToRead
        self.asksToWrite = asksToWrite
    }

    public var replaces: Bool { sources.contains(where: \.replaces) }
    /// No folder beyond `sources` is reachable without asking, and no step
    /// reaches the Mac outside them.
    public var isContained: Bool { hostReach.isEmpty && !mayAskForMoreFolders }

    // MARK: - Derivation

    static let readTools: Set<String> = ["file_read", "file_search", "file_tree", "share_artifact", "detect_pii"]
    static let writeTools: Set<String> = ["file_write", "file_edit", "file_copy", "redact_file"]
    static let replaceTools: Set<String> = ["file_edit", "redact_file"]
    /// `file_undo` takes back recorded changes wherever they were made, which
    /// can remove a file, so it is named rather than summed into a folder.
    static let unconfinedTools: Set<String> = WorkflowStepRisk.macTools.union(["applescript", "computer_use", "file_undo"])

    public static func derive(_ definition: WorkflowDefinition) -> WorkflowAccessScope {
        var builder = Builder(definition: definition)
        for node in definition.nodes { builder.visit(node) }
        return builder.finish()
    }

    /// Whether `node` reads or saves files on this Mac beyond the run's
    /// workspace, or calls a tool that acts on the Mac directly.
    public static func touchesMac(_ node: WorkflowNode, in definition: WorkflowDefinition) -> Bool {
        var builder = Builder(definition: definition)
        builder.visit(node)
        return builder.touchedMac
    }

    private struct Builder {
        var sources: [Source] = []
        var hostReach: [String] = []
        var agenticReads = false
        var agenticWrites = false
        var agenticReplaces = false
        /// A save whose target is computed at run time.
        var untracedWrite = false
        var untracedRead = false
        var touchedMac = false
        var declaredWrite: Set<String> = []
        let definition: WorkflowDefinition
        /// Dialog node id -> its folder and file field keys.
        var dialogFields: [String: Set<String>] = [:]

        init(definition: WorkflowDefinition) {
            self.definition = definition
            let schema = definition.inputSchema.objectValue ?? [:]
            let props = schema["properties"]?.objectValue ?? [:]
            for key in WorkflowDraftPatcher.fieldOrder(definition.inputSchema) {
                guard let prop = props[key]?.objectValue, let format = prop["format"]?.stringValue,
                    format == "folder" || format == "file"
                else { continue }
                sources.append(
                    Source(
                        ref: .input(key), label: prop["title"]?.stringValue ?? WorkflowAccessScope.humanized(key),
                        isFile: format == "file", reads: false, writeSubpaths: [], replaces: false))
            }
            for node in definition.nodes {
                guard case .dialog(let spec)? = node.kind else { continue }
                for field in spec.fields where field.type == .folder || field.type == .file {
                    dialogFields[node.id, default: []].insert(field.key)
                    sources.append(
                        Source(
                            ref: .dialog(node: node.id, field: field.key), label: field.label,
                            isFile: field.type == .file, reads: false, writeSubpaths: [], replaces: false))
                }
            }
            for folder in definition.folders {
                if folder.access == .write { declaredWrite.insert(folder.key) }
                sources.append(
                    Source(
                        ref: .folder(folder.key), label: folder.label, isFile: false, reads: folder.access == .read,
                        writeSubpaths: [], replaces: false))
            }
        }

        mutating func reach(_ name: String) {
            if !hostReach.contains(name) { hostReach.append(name) }
        }

        mutating func visit(_ node: WorkflowNode) {
            switch node.kind {
            case .tool(let spec):
                tool(spec.tool, input: node.input)
            case .inference(let spec):
                if case .agentic(let tools, _) = spec.mode {
                    for ref in tools { agenticTool(ref) }
                }
            case .map(let spec):
                visit(spec.body(parentID: node.id))
            case .workflow(let spec):
                reach(L("the “\(spec.workflow)” workflow"))
            case .agent(let spec):
                reach(L("the agent \(spec.agent)"))
            default:
                break
            }
        }

        mutating func unconfined(_ ref: ToolRef) -> Bool {
            if let plugin = ref.plugin, !plugin.isEmpty {
                reach(ref.name)
                touchedMac = true
                return true
            }
            if let server = ref.server, !server.isEmpty {
                reach(L("\(ref.name) (\(server))"))
                return true
            }
            if WorkflowAccessScope.unconfinedTools.contains(ref.name.lowercased()) {
                reach(ref.name)
                touchedMac = true
                return true
            }
            return false
        }

        mutating func agenticTool(_ ref: ToolRef) {
            if unconfined(ref) { return }
            let name = ref.name.lowercased()
            if WorkflowAccessScope.readTools.contains(name) { agenticReads = true }
            if WorkflowAccessScope.writeTools.contains(name) {
                agenticWrites = true
                agenticReads = true
            }
            if !sources.isEmpty, WorkflowAccessScope.readTools.contains(name) || WorkflowAccessScope.writeTools.contains(name) {
                touchedMac = true
            }
            if name == "file_edit" || name == "file_copy" { agenticReplaces = true }
        }

        mutating func tool(_ ref: ToolRef, input: WorkflowBinding) {
            if unconfined(ref) { return }
            let name = ref.name.lowercased()
            let fields = input.fieldTemplates ?? [:]
            switch name {
            case "file_copy":
                if let source = fields["source"] { use(source, write: false, replaces: false) }
                if let destination = fields["destination"] {
                    use(destination, write: true, replaces: Self.overwrites(input))
                }
            case _ where WorkflowAccessScope.writeTools.contains(name):
                if let path = fields["path"] {
                    use(path, write: true, replaces: WorkflowAccessScope.replaceTools.contains(name))
                }
            case _ where WorkflowAccessScope.readTools.contains(name):
                if let path = fields["path"] { use(path, write: false, replaces: false) }
            default:
                break
            }
        }

        static func overwrites(_ input: WorkflowBinding) -> Bool {
            switch input {
            case .values(let values):
                switch values["overwrite"] {
                case .bool(let flag)?: return flag
                case .string(let text)?: return text != "false"
                default: return false
                }
            case .object(let object):
                guard let text = object["overwrite"] else { return false }
                return text.trimmingCharacters(in: .whitespaces) != "false"
            case .template:
                return false
            }
        }

        /// Records one path argument against the source it starts in.
        mutating func use(_ template: String, write: Bool, replaces: Bool) {
            switch WorkflowAccessScope.target(of: template, dialogFields: dialogFields) {
            case .internal:
                return
            case .dynamic:
                touchedMac = true
                if write { untracedWrite = true } else { untracedRead = true }
            case .source(let ref, let subpath):
                touchedMac = true
                guard let index = sources.firstIndex(where: { $0.ref == ref }) else {
                    if write { untracedWrite = true } else { untracedRead = true }
                    return
                }
                if write {
                    if !sources[index].writeSubpaths.contains(subpath) {
                        sources[index].writeSubpaths.append(subpath)
                    }
                    if replaces || sources[index].isFile { sources[index].replaces = true }
                } else {
                    sources[index].reads = true
                }
            }
        }

        func finish() -> WorkflowAccessScope {
            var out = sources
            for index in out.indices {
                if agenticReads { out[index].reads = true }
                if agenticWrites { out[index].writeSubpaths = [""] }
                // A folder declared for saving, whose save targets aren't all
                // written out, stays writable as a whole: it was allowed so.
                if case .folder(let key) = out[index].ref, declaredWrite.contains(key),
                    out[index].writeSubpaths.isEmpty || untracedWrite
                {
                    out[index].writeSubpaths = [""]
                }
                if agenticReplaces { out[index].replaces = true }
                // A narrower subpath under a whole-folder write adds nothing.
                if out[index].writesAnywhere { out[index].writeSubpaths = [""] }
                out[index].writeSubpaths.sort()
            }
            return WorkflowAccessScope(
                sources: out, runsInSandbox: definition.usesSandbox, hostReach: hostReach,
                asksToRead: untracedRead, asksToWrite: untracedWrite)
        }
    }

    enum Target: Equatable {
        /// The run workspace or the working folder: the run's own files.
        case `internal`
        /// Known only at run time.
        case dynamic
        case source(SourceRef, subpath: String)
    }

    /// Which source a path template starts in, and the literal part of the
    /// path below it. `{{input.folder}}/png/{{item.name}}.png` is `png` of
    /// the `folder` input; `{{input.folder}}/report.pdf` is `report.pdf`.
    static func target(of template: String, dialogFields: [String: Set<String>]) -> Target {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{{") else {
            // Relative paths land in the run's own folder; a literal absolute
            // path is outside every declared source.
            return trimmed.hasPrefix("/") || trimmed.hasPrefix("~") ? .dynamic : .internal
        }
        guard let close = trimmed.range(of: "}}") else { return .dynamic }
        let raw = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2) ..< close.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let rest = String(trimmed[close.upperBound...])
        let ref: SourceRef
        switch BindingRenderer.parse(reference: raw) {
        case .input(let path)? where !path.isEmpty && !path.contains("."):
            ref = .input(path)
        case .folder(let key)?:
            ref = .folder(key)
        case .node(let id, let path)? where dialogFields[id]?.contains(path) == true:
            ref = .dialog(node: id, field: path)
        case .run(field: "workspace")?:
            return .internal
        default:
            return .dynamic
        }
        guard rest.isEmpty || rest.hasPrefix("/") else { return .dynamic }
        var literal: [String] = []
        for component in rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component.contains("{{") || component == ".." { break }
            if component == "." { continue }
            literal.append(component)
        }
        return .source(ref, subpath: literal.joined(separator: "/"))
    }

    static func humanized(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    // MARK: - Resolution

    /// One source with the real folder or file it names in a run.
    public struct Resolved: Equatable, Sendable {
        public var source: Source
        public var url: URL
        /// Every folder or file steps may save into: `url` joined with each
        /// write subpath.
        public var writableURLs: [URL]

        public var name: String { WorkflowAccessScope.displayName(url) }
        public var writableNames: [String] {
            writableURLs.map { target in
                target == url ? name : name + "/" + String(target.path.dropFirst(url.path.count + 1))
            }
        }
    }

    /// Sources bound to real paths: the run's input, the answered dialogs'
    /// outputs, and the folders bound in setup. Unbound sources are left out.
    public func resolved(
        input: JSONValue, dialogOutputs: [String: JSONValue], boundFolders: [String: String]
    ) -> [Resolved] {
        sources.compactMap { source in
            let raw: String?
            switch source.ref {
            case .input(let key): raw = input.objectValue?[key]?.stringValue
            case .dialog(let node, let field): raw = dialogOutputs[node]?.objectValue?[field]?.stringValue
            case .folder(let key): raw = boundFolders[key]
            }
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else {
                return nil
            }
            let url = URL(fileURLWithPath: path).standardized
            let writable = source.writeSubpaths.map { sub in
                sub.isEmpty ? url : url.appendingPathComponent(sub).standardized
            }
            return Resolved(source: source, url: url, writableURLs: writable)
        }
    }

    static func displayName(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? url.path : name
    }
}

// MARK: - Copy

extension WorkflowAccessScope {

    /// The icons and words every surface uses for where work happens.
    public enum Place: String, Sendable {
        case mac, sandbox

        public var title: String {
            switch self {
            case .mac: return L("Your Mac")
            case .sandbox: return L("Sandbox")
            }
        }

        public var systemImage: String {
            switch self {
            case .mac: return "laptopcomputer"
            case .sandbox: return "shippingbox"
            }
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public enum Verb: String, Sendable {
            case reads, writes, deletes, replaces, alsoUses
        }

        public var verb: Verb
        public var title: String
        public var value: String

        public var id: String { verb.rawValue }

        public var systemImage: String {
            switch verb {
            case .reads: return "doc.text.magnifyingglass"
            case .writes: return "square.and.arrow.down"
            case .deletes: return "trash.slash"
            case .replaces: return "arrow.triangle.2.circlepath"
            case .alsoUses: return "exclamationmark.triangle"
            }
        }
    }

    private var pickedSources: [Source] {
        sources.filter { if case .folder = $0.ref { false } else { true } }
    }

    /// "folder you pick", "“Invoices”", "file you pick".
    func shortName(_ source: Source) -> String {
        switch source.ref {
        case .folder:
            return L("“\(source.label)”")
        case .input, .dialog:
            let alone = pickedSources.filter { $0.isFile == source.isFile }.count == 1
            if alone { return source.isFile ? L("file you pick") : L("folder you pick") }
            return L("“\(source.label)”")
        }
    }

    /// "the folder you choose", "your “Invoices” folder".
    func longName(_ source: Source) -> String {
        switch source.ref {
        case .folder:
            return L("your “\(source.label)” folder")
        case .input, .dialog:
            let alone = pickedSources.filter { $0.isFile == source.isFile }.count == 1
            if alone { return source.isFile ? L("the file you choose") : L("the folder you choose") }
            return L("the “\(source.label)” you choose")
        }
    }

    static func isFileName(_ subpath: String) -> Bool {
        guard let last = subpath.split(separator: "/").last else { return false }
        return last.contains(".")
    }

    func shortWriteTarget(_ source: Source, _ subpath: String) -> String {
        if subpath.isEmpty {
            return source.reads ? L("anywhere in the \(shortName(source))") : shortName(source)
        }
        let suffix = sources.filter(\.writes).count > 1 ? L(" in \(shortName(source))") : ""
        return Self.isFileName(subpath) ? subpath + suffix : L("\(subpath) subfolder") + suffix
    }

    /// Reads / Writes / Deletes, plus Replaces and Also uses when they apply.
    public var rows: [Row] {
        var rows: [Row] = []
        let read = sources.filter(\.reads).map(shortName) + (asksToRead ? [L("a folder it asks for")] : [])
        rows.append(Row(verb: .reads, title: L("Reads"), value: read.isEmpty ? L("nothing") : read.joined(separator: ", ")))
        let writes =
            sources.flatMap { source in source.writeSubpaths.map { shortWriteTarget(source, $0) } }
            + (asksToWrite ? [L("a folder it asks for")] : [])
        rows.append(
            Row(verb: .writes, title: L("Writes"), value: writes.isEmpty ? L("nothing") : writes.joined(separator: ", ")))
        rows.append(
            Row(
                verb: .deletes, title: L("Deletes"),
                value: hostReach.isEmpty ? L("nothing") : L("nothing through its file steps")))
        let replaced = sources.filter(\.replaces).map(shortName)
        if !replaced.isEmpty {
            rows.append(
                Row(
                    verb: .replaces, title: L("Replaces"),
                    value: L("files in \(replaced.joined(separator: ", ")), after asking you")))
        }
        if !hostReach.isEmpty {
            rows.append(
                Row(
                    verb: .alsoUses, title: L("Also uses"),
                    value: L("\(hostReach.joined(separator: ", ")), not limited to these folders")))
        }
        return rows
    }

    /// The one line a listing, install sheet, or card shows.
    /// "Reads a folder you choose · saves results to a png folder inside it · works in the sandbox".
    public var oneLine: String {
        var parts: [String] = []
        let readSources = sources.filter(\.reads)
        for source in readSources {
            parts.append(L("reads \(Self.article(longName(source)))"))
        }
        for source in sources where source.writes {
            let inside = source.reads && readSources.count == 1
            for sub in source.writeSubpaths {
                if inside {
                    if sub.isEmpty {
                        parts.append(L("may save anywhere inside it"))
                    } else if Self.isFileName(sub) {
                        parts.append(L("saves \(sub) inside it"))
                    } else {
                        parts.append(L("saves results to a \(sub) folder inside it"))
                    }
                } else if sub.isEmpty {
                    parts.append(L("saves to \(Self.article(longName(source)))"))
                } else {
                    parts.append(L("saves to \(sub) in \(longName(source))"))
                }
            }
        }
        if asksToRead { parts.append(L("reads a folder it asks for")) }
        if asksToWrite { parts.append(L("saves to a folder it asks for")) }
        if parts.isEmpty { parts.append(L("doesn't use your files")) }
        if replaces { parts.append(L("replaces files after asking")) }
        if runsInSandbox { parts.append(L("works in the sandbox")) }
        if !hostReach.isEmpty { parts.append(L("also uses \(hostReach.joined(separator: ", "))")) }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// What the Architect says once the design is ready.
    public var architectSentence: String {
        var clauses: [String] = []
        let readSources = sources.filter(\.reads)
        let reads = readSources.map(longName) + (asksToRead ? [L("a folder it asks you for")] : [])
        if !reads.isEmpty {
            clauses.append(L("read \(reads.joined(separator: " and "))"))
        }
        if runsInSandbox { clauses.append(L("do its work in the sandbox")) }
        var saves: [String] = []
        for source in sources where source.writes {
            for sub in source.writeSubpaths {
                if sub.isEmpty {
                    saves.append(source.reads ? L("anywhere inside \(longName(source))") : longName(source))
                } else if Self.isFileName(sub) {
                    saves.append(L("\(sub) in \(longName(source))"))
                } else {
                    saves.append(L("a \(sub) subfolder of \(longName(source))"))
                }
            }
        }
        if asksToWrite { saves.append(L("a folder it asks you for")) }
        if !saves.isEmpty { clauses.append(L("save results to \(saves.joined(separator: " and "))")) }
        var sentence: String
        if clauses.isEmpty {
            sentence = L("This workflow doesn't read or save files on your Mac.")
        } else {
            sentence = L("This workflow will \(Self.list(clauses)).")
        }
        if replaces { sentence += L(" It asks before replacing a file that's already there.") }
        if !hostReach.isEmpty {
            sentence += L(" It also uses \(Self.list(hostReach)), which aren't limited to these folders.")
        } else if !mayAskForMoreFolders {
            sentence += L(" It won't touch anything else.")
        }
        return sentence
    }

    /// The caption under a picked folder or file in the run form.
    public func caption(forInput key: String) -> String? {
        guard let source = sources.first(where: { $0.ref == .input(key) }) else { return nil }
        if source.isFile {
            return source.replaces ? L("This file may be changed. You'll be asked first.") : L("Only read; it isn't changed.")
        }
        guard source.writes else { return source.reads ? L("Only read; nothing in it is changed.") : nil }
        if source.writesAnywhere { return L("Results may be saved anywhere inside it.") }
        let targets = source.writeSubpaths.map { sub in
            Self.isFileName(sub) ? L("as \(sub)") : L("to a \(sub) folder")
        }
        return L("Results will be saved \(targets.joined(separator: " and ")) inside it.")
    }

    /// Input key -> caption, for each picked folder or file the run form shows.
    public var inputCaptions: [String: String] {
        var out: [String: String] = [:]
        for source in sources {
            guard case .input(let key) = source.ref, let caption = caption(forInput: key) else { continue }
            out[key] = caption
        }
        return out
    }

    /// "the folder you choose" → "a folder you choose"; named sources keep theirs.
    static func article(_ phrase: String) -> String {
        switch phrase {
        case L("the folder you choose"): return L("a folder you choose")
        case L("the file you choose"): return L("a file you choose")
        default: return phrase
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + L(" and ") + items[1]
        default: return items.dropLast().joined(separator: ", ") + L(", and ") + items[items.count - 1]
        }
    }

    /// Foundation form for Architect tool results.
    public var payload: [String: Any] {
        [
            "sentence": architectSentence,
            "summary": oneLine,
            "rows": rows.map { ["title": $0.title, "value": $0.value] },
            "runs_in_sandbox": runsInSandbox,
        ]
    }
}
