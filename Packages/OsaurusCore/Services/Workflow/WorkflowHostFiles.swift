//
//  WorkflowHostFiles.swift
//  osaurus
//
//  What a workflow run does to files on this Mac outside its workspace:
//  replacing an existing file waits for the person's approval (once per
//  run per folder, or always), and every file a step creates or replaces
//  is journaled on the run for its result summary.
//

import Foundation

/// Whether the run may replace `file`, which already exists in the granted
/// folder `folder`. Asks the person when the run has not been allowed yet;
/// false when they decline or nobody can be asked.
typealias WorkflowReplaceApproval = @Sendable (_ folder: URL, _ file: URL) async throws -> Bool

struct WorkflowHostFileHooks: Sendable {
    /// The run's own workspace: files there are never gated or journaled.
    var workspace: URL
    var approveReplace: WorkflowReplaceApproval
    var record: @Sendable (_ file: URL, _ replaced: Bool) async -> Void
}

/// A file a workflow run created or replaced on this Mac.
public struct WorkflowHostWrite: Codable, Equatable, Sendable {
    public var path: String
    public var replaced: Bool

    public init(path: String, replaced: Bool) {
        self.path = path
        self.replaced = replaced
    }
}

extension WorkflowHostWrite {

    /// One line per folder: "Created 12 PNGs in dinos/png", "Replaced 2
    /// files in dinos". `root` names folders relative to the folder the
    /// person picked when the path is inside it.
    public struct Summary: Equatable, Sendable, Identifiable {
        public var folder: URL
        public var text: String
        /// The files to select in Finder.
        public var files: [URL]

        public var id: String { folder.path + text }
    }

    public static func summaries(_ writes: [WorkflowHostWrite], roots: [URL] = []) -> [Summary] {
        var latest: [String: Bool] = [:]
        var order: [String] = []
        // A file created and then rewritten in the same run was still created.
        for write in writes where latest[write.path] == nil {
            order.append(write.path)
            latest[write.path] = write.replaced
        }
        var groups: [String: (created: [URL], replaced: [URL])] = [:]
        var folders: [String] = []
        for path in order {
            let url = URL(fileURLWithPath: path)
            let folder = url.deletingLastPathComponent().path
            if groups[folder] == nil { folders.append(folder) }
            if latest[path] == true {
                groups[folder, default: ([], [])].replaced.append(url)
            } else {
                groups[folder, default: ([], [])].created.append(url)
            }
        }
        var out: [Summary] = []
        for folder in folders {
            guard let group = groups[folder] else { continue }
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            let name = displayName(folderURL, roots: roots)
            if !group.created.isEmpty {
                out.append(
                    Summary(
                        folder: folderURL, text: L("Created \(noun(group.created)) in \(name)"), files: group.created))
            }
            if !group.replaced.isEmpty {
                out.append(
                    Summary(
                        folder: folderURL, text: L("Replaced \(noun(group.replaced)) in \(name)"),
                        files: group.replaced))
            }
        }
        return out
    }

    /// "12 PNGs", "1 PDF", "3 files".
    static func noun(_ files: [URL]) -> String {
        let extensions = Set(files.map { $0.pathExtension.lowercased() })
        if extensions.count == 1, let ext = extensions.first, !ext.isEmpty, ext.count <= 5 {
            let kind = ext.uppercased()
            return files.count == 1 ? L("1 \(kind)") : L("\(files.count) \(kind)s")
        }
        return files.count == 1 ? L("1 file") : L("\(files.count) files")
    }

    /// `dinos/png` when the folder is inside the picked `dinos`, else its name.
    static func displayName(_ folder: URL, roots: [URL]) -> String {
        let path = folder.standardized.path
        for root in roots {
            let rootPath = root.standardized.path
            let rootName = WorkflowAccessScope.displayName(root)
            if path == rootPath { return rootName }
            if path.hasPrefix(rootPath + "/") { return rootName + "/" + path.dropFirst(rootPath.count + 1) }
        }
        return WorkflowAccessScope.displayName(folder)
    }
}
