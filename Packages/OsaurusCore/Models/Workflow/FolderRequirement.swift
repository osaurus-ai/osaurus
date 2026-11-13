//
//  FolderRequirement.swift
//  osaurus
//
//  A folder a workflow's steps read from or write to that is the same on
//  every run (an invoices folder, a downloads destination). Declared on
//  the definition by the Architect (`declare_folder`), carried in the
//  template's requirements, and bound to a real folder on each Mac in the
//  setup wizard. Steps name it as `{{folders.<key>}}`; the bound folder is
//  one of the paths the run's file tools may use. Only the key, label, and
//  the author's path hint travel with the template, never a bound path.
//

import Foundation

public struct FolderRequirement: Codable, Equatable, Sendable, Identifiable {

    public enum Access: String, Codable, Sendable, CaseIterable {
        /// Steps only read files there.
        case read
        /// Steps create or change files there.
        case write

        public var displayName: String {
            switch self {
            case .read: return L("Reads files")
            case .write: return L("Saves files")
            }
        }
    }

    /// Binding-safe identifier: `{{folders.<key>}}`.
    public var key: String
    public var label: String
    public var help: String?
    public var access: Access
    /// The folder the author used, shown as a suggestion when binding.
    public var hint: PathHint?

    public var id: String { key }

    public init(key: String, label: String, help: String? = nil, access: Access = .write, hint: PathHint? = nil) {
        self.key = key
        self.label = label
        self.help = help
        self.access = access
        self.hint = hint
    }

    enum CodingKeys: String, CodingKey { case key, label, help, access, hint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        help = try c.decodeIfPresent(String.self, forKey: .help)
        access = try c.decodeIfPresent(Access.self, forKey: .access) ?? .write
        hint = try c.decodeIfPresent(PathHint.self, forKey: .hint)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(help, forKey: .help)
        try c.encode(access, forKey: .access)
        try c.encodeIfPresent(hint, forKey: .hint)
    }

    /// Validation problems a definition or draft op must not carry.
    public var issues: [String] {
        var out: [String] = []
        if !Self.isValidKey(key) {
            out.append(
                "folder `\(key)`: the key must start with a letter and use only letters, digits, and `_`, like `invoices` or `save_to`")
        }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("folder `\(key)`: give it a label the person will recognize, like \"Invoices folder\"")
        }
        return out
    }

    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return key.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// Upsert by key, keeping the declared order.
    public static func upserting(_ folder: FolderRequirement, in list: [FolderRequirement]) -> [FolderRequirement] {
        var out = list
        if let index = out.firstIndex(where: { $0.key == folder.key }) {
            out[index] = folder
        } else {
            out.append(folder)
        }
        return out
    }

    /// The folder to grant for a path a step tried to use: the path itself
    /// when it is a directory, else its parent.
    public static func grantRoot(for path: String) -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}
