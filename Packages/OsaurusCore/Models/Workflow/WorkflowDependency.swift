//
//  WorkflowDependency.swift
//  osaurus
//
//  A package a workflow's shell steps need that the sandbox base image
//  does not ship: one entry per package manager (`apk`, `pip`, `npm`) with
//  the package specifiers and the command names expected on PATH after
//  installing them. Declared on the definition by the Architect
//  (`declare_dependency`), carried in the template's requirements, and
//  installed into the workflow's own sandbox environment by the setup
//  wizard. A workflow that declares any dependency runs its shell steps in
//  the sandbox.
//

import Foundation

public struct WorkflowDependency: Codable, Equatable, Sendable, Identifiable {

    public enum Manager: String, Codable, Sendable, CaseIterable {
        /// Alpine system packages, installed root-wide. Linux VM only.
        case apk
        /// Python packages, installed into the environment's venv.
        case pip
        /// Node packages, installed into the environment's npm workspace.
        case npm

        public var displayName: String {
            switch self {
            case .apk: return L("System package")
            case .pip: return L("Python package")
            case .npm: return L("Node package")
            }
        }

        /// `apk` needs the Alpine rootfs; the Seatbelt backend has none.
        public var requiresLinuxVM: Bool { self == .apk }
    }

    public var manager: Manager
    /// Package specifiers as the manager accepts them (`yt-dlp`, `numpy==2.0`).
    public var packages: [String]
    /// Commands the install must put on PATH (`yt-dlp`, `ffmpeg`). Setup
    /// verifies each one after installing; empty when the dependency is a
    /// library only.
    public var binaries: [String]

    public var id: String { manager.rawValue }

    public init(manager: Manager, packages: [String], binaries: [String] = []) {
        self.manager = manager
        self.packages = packages
        self.binaries = binaries
    }

    enum CodingKeys: String, CodingKey { case manager, packages, binaries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manager = try c.decode(Manager.self, forKey: .manager)
        packages = try c.decodeIfPresent([String].self, forKey: .packages) ?? []
        binaries = try c.decodeIfPresent([String].self, forKey: .binaries) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(manager, forKey: .manager)
        try c.encode(packages, forKey: .packages)
        if !binaries.isEmpty { try c.encode(binaries, forKey: .binaries) }
    }

    /// Requirement row value for one package: `pip:yt-dlp`.
    public static func requirementValue(manager: Manager, package: String) -> String {
        "\(manager.rawValue):\(package)"
    }

    /// One-line label for lists: "yt-dlp (Python package)".
    public var summary: String {
        "\(packages.joined(separator: ", ")) (\(manager.displayName))"
    }

    /// Validation problems a definition or draft op must not carry. Package
    /// specifiers follow the same rules as `sandbox_install`; binaries are
    /// bare command names.
    public var issues: [String] {
        var out: [String] = []
        do {
            _ = try SandboxPackageRequest.normalize(packages)
        } catch {
            out.append("\(manager.rawValue) dependency: \(error.localizedDescription)")
        }
        // `sandbox_install` quotes specifiers, so it tolerates these; in a
        // declaration they only ever mean a shell fragment or two packages
        // pasted into one entry.
        for package in packages where package.unicodeScalars.contains(where: Self.notInSpecifier.contains) {
            out.append(
                "\(manager.rawValue) dependency: `\(package)` is not a package specifier. List each package as its own entry, like `yt-dlp` or `numpy>=2`.")
        }
        for binary in binaries {
            let trimmed = binary.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains("/") || trimmed.contains(" ") {
                out.append("\(manager.rawValue) dependency: binary `\(binary)` must be a bare command name, like `yt-dlp`")
            }
        }
        return out
    }

    private static let notInSpecifier = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";&|`$'\"\\"))

    /// Upsert by manager: the dependencies with `dependency` replacing the
    /// entry for its manager, or removed when it lists no packages.
    public static func upserting(_ dependency: WorkflowDependency, in list: [WorkflowDependency]) -> [WorkflowDependency] {
        var out = list.filter { $0.manager != dependency.manager }
        if !dependency.packages.isEmpty {
            if let index = list.firstIndex(where: { $0.manager == dependency.manager }) {
                out.insert(dependency, at: min(index, out.count))
            } else {
                out.append(dependency)
            }
        }
        return out
    }
}
