//
//  ProjectSkillService.swift
//  osaurus
//
//  Discovers project-local Agent Skills without copying them into the global
//  skill library. Discovery is bounded and fail-closed because a selected
//  workspace is not automatically a trusted source of executable content.
//

import CryptoKit
import Darwin
import Foundation
import Observation

private enum ProjectSkillScopeSequence {
    nonisolated(unsafe) static var value: UInt64 = 0
    nonisolated static let lock = NSLock()

    static func next() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }
}

enum ProjectSkillSource: String, CaseIterable, Sendable {
    case osaurus = ".osaurus/skills"
    case agents = ".agents/skills"
    case claude = ".claude/skills"

    var trustLabel: String {
        switch self {
        case .osaurus: return "Project-local Osaurus skill"
        case .agents: return "Agent Skills compatible project skill"
        case .claude: return "Claude-compatible project skill"
        }
    }
}

enum ProjectSkillStatus: Equatable, Sendable {
    case available
    case rejected(String)

    var rejectionReason: String? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }
}

struct ProjectSkillFile: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case reference
        case helper
        case asset
        case other
    }

    var id: String { relativePath }
    let relativePath: String
    let kind: Kind
    let size: Int64
    let contentHash: String
}

struct ProjectSkillRecord: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let source: ProjectSkillSource
    let skillDirectory: String
    let instructionFile: String
    let instructions: String
    let approvalHash: String
    let files: [ProjectSkillFile]
    var status: ProjectSkillStatus

    var references: [ProjectSkillFile] { files.filter { $0.kind == .reference } }
    var helpers: [ProjectSkillFile] { files.filter { $0.kind == .helper } }
    var assets: [ProjectSkillFile] { files.filter { $0.kind == .asset } }
}

struct ProjectSkillScanResult: Equatable, Sendable {
    let rootIdentity: String
    let records: [ProjectSkillRecord]
    let diagnostics: [String]
}

struct ProjectSkillScanner: Sendable {
    struct Limits: Sendable {
        var maxDiscoveryEntries = 512
        var maxSkillDepth = 3
        var maxPackageFiles = 128
        var maxPackageDepth = 5
        var maxInstructionBytes: Int64 = 128 * 1024
        var maxPackageFileBytes: Int64 = 2 * 1024 * 1024
        var maxPackageBytes: Int64 = 8 * 1024 * 1024

        static let standard = Limits()
    }

    let limits: Limits
    let targetValidationHook: (@Sendable () -> Void)?

    init(
        limits: Limits = .standard,
        targetValidationHook: (@Sendable () -> Void)? = nil
    ) {
        self.limits = limits
        self.targetValidationHook = targetValidationHook
    }

    func scan(root rawRoot: URL) -> ProjectSkillScanResult {
        let root = rawRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootIdentity = Self.rootIdentity(root)
        var records: [ProjectSkillRecord] = []
        var diagnostics: [String] = []

        for source in ProjectSkillSource.allCases {
            let sourceRoot = root.appendingPathComponent(source.rawValue, isDirectory: true)
            guard FileManager.default.fileExists(atPath: sourceRoot.path) else { continue }
            guard !Self.containsSymlink(from: root, through: sourceRoot) else {
                diagnostics.append("Rejected symlinked project skill root: \(source.rawValue)")
                continue
            }
            let result = discover(source: source, sourceRoot: sourceRoot, projectRoot: root)
            records.append(contentsOf: result.records)
            diagnostics.append(contentsOf: result.diagnostics)
        }

        let groups = Dictionary(grouping: records.indices) {
            records[$0].name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for (name, indices) in groups where !name.isEmpty && indices.count > 1 {
            let ids = indices.map { records[$0].id }.sorted().joined(separator: ", ")
            for index in indices {
                records[index].status = .rejected("Ambiguous duplicate skill name; conflicts with: \(ids)")
            }
            diagnostics.append("Rejected duplicate project skill name '\(name)': \(ids)")
        }

        return ProjectSkillScanResult(
            rootIdentity: rootIdentity,
            records: records.sorted { $0.id < $1.id },
            diagnostics: diagnostics.sorted()
        )
    }

    func revalidate(root rawRoot: URL, record: ProjectSkillRecord) -> ProjectSkillRecord {
        targetValidationHook?()
        let root = rawRoot.standardizedFileURL.resolvingSymlinksInPath()
        let sourceRoot = root.appendingPathComponent(record.source.rawValue, isDirectory: true)
        let skillDirectory = root.appendingPathComponent(record.skillDirectory, isDirectory: true)
        let instructionURL = skillDirectory.appendingPathComponent("SKILL.md")
        let relativeDirectory = Self.relativePath(skillDirectory, under: sourceRoot)
        let depth = relativeDirectory.split(separator: "/").count

        guard
            Self.isLexicallyContained(sourceRoot, by: root),
            Self.isLexicallyContained(skillDirectory, by: sourceRoot),
            depth > 0,
            depth <= limits.maxSkillDepth,
            Self.capabilityID(source: record.source, skillDirectory: relativeDirectory) == record.id,
            Self.relativePath(instructionURL, under: root) == record.instructionFile,
            !Self.containsSymlink(from: root, through: skillDirectory)
        else {
            return rejectedTarget(record, reason: "Project skill path or root identity changed")
        }

        return inspectSkill(
            id: record.id,
            source: record.source,
            projectRoot: root,
            skillDirectory: skillDirectory,
            instructionURL: instructionURL
        )
    }

    private func rejectedTarget(_ record: ProjectSkillRecord, reason: String) -> ProjectSkillRecord {
        ProjectSkillRecord(
            id: record.id,
            name: record.name,
            description: "",
            source: record.source,
            skillDirectory: record.skillDirectory,
            instructionFile: record.instructionFile,
            instructions: "",
            approvalHash: "",
            files: [],
            status: .rejected(reason)
        )
    }

    private func discover(
        source: ProjectSkillSource,
        sourceRoot: URL,
        projectRoot: URL
    ) -> (records: [ProjectSkillRecord], diagnostics: [String]) {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        else {
            return ([], ["Could not enumerate \(source.rawValue)"])
        }

        var records: [ProjectSkillRecord] = []
        var diagnostics: [String] = []
        var inspected = 0

        for case let url as URL in enumerator {
            inspected += 1
            if inspected > limits.maxDiscoveryEntries {
                diagnostics.append("Stopped scanning \(source.rawValue) after \(limits.maxDiscoveryEntries) entries")
                break
            }

            let relative = Self.relativePath(url, under: sourceRoot)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                enumerator.skipDescendants()
                diagnostics.append("Rejected unreadable project skill entry: \(source.rawValue)/\(relative)")
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                diagnostics.append("Rejected symlinked project skill entry: \(source.rawValue)/\(relative)")
                if url.lastPathComponent == "SKILL.md" {
                    let skillDirectory = url.deletingLastPathComponent()
                    records.append(
                        rejectedSymlinkRecord(
                            source: source,
                            projectRoot: projectRoot,
                            skillDirectory: skillDirectory,
                            instructionURL: url
                        )
                    )
                }
                continue
            }
            let depth = relative.split(separator: "/").count
            if depth > limits.maxSkillDepth + 1 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "SKILL.md" else { continue }

            let skillDirectory = url.deletingLastPathComponent()
            let directoryRelative = Self.relativePath(skillDirectory, under: sourceRoot)
            let id = Self.capabilityID(source: source, skillDirectory: directoryRelative)
            records.append(
                inspectSkill(
                    id: id,
                    source: source,
                    projectRoot: projectRoot,
                    skillDirectory: skillDirectory,
                    instructionURL: url
                )
            )
            enumerator.skipDescendants()
        }
        return (records, diagnostics)
    }

    private func rejectedSymlinkRecord(
        source: ProjectSkillSource,
        projectRoot: URL,
        skillDirectory: URL,
        instructionURL: URL
    ) -> ProjectSkillRecord {
        let directoryRelative = Self.relativePath(
            skillDirectory,
            under: projectRoot.appendingPathComponent(source.rawValue, isDirectory: true)
        )
        return ProjectSkillRecord(
            id: Self.capabilityID(source: source, skillDirectory: directoryRelative),
            name: skillDirectory.lastPathComponent,
            description: "",
            source: source,
            skillDirectory: Self.relativePath(skillDirectory, under: projectRoot),
            instructionFile: Self.relativePath(instructionURL, under: projectRoot),
            instructions: "",
            approvalHash: "",
            files: [],
            status: .rejected("Symlinked SKILL.md is not allowed")
        )
    }

    private func inspectSkill(
        id: String,
        source: ProjectSkillSource,
        projectRoot: URL,
        skillDirectory: URL,
        instructionURL: URL
    ) -> ProjectSkillRecord {
        func rejected(_ reason: String, name: String? = nil, files: [ProjectSkillFile] = []) -> ProjectSkillRecord {
            ProjectSkillRecord(
                id: id,
                name: name ?? skillDirectory.lastPathComponent,
                description: "",
                source: source,
                skillDirectory: Self.relativePath(skillDirectory, under: projectRoot),
                instructionFile: Self.relativePath(instructionURL, under: projectRoot),
                instructions: "",
                approvalHash: "",
                files: files,
                status: .rejected(reason)
            )
        }

        guard Self.isContained(instructionURL, by: projectRoot) else {
            return rejected("SKILL.md resolves outside the selected project")
        }
        let instructionValues: URLResourceValues
        do {
            instructionValues = try instructionURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            return rejected("SKILL.md metadata could not be read")
        }
        guard instructionValues.isSymbolicLink != true else {
            return rejected("Symlinked SKILL.md is not allowed")
        }
        guard instructionValues.isRegularFile == true else {
            return rejected("SKILL.md is not a regular file")
        }
        let instructionSize = Int64(instructionValues.fileSize ?? 0)
        guard instructionSize <= limits.maxInstructionBytes else {
            return rejected("SKILL.md exceeds the \(limits.maxInstructionBytes)-byte instruction limit")
        }
        guard
            let instructionData = try? Self.readBoundedFile(
                instructionURL,
                maximumBytes: limits.maxInstructionBytes
            ),
            let markdown = String(data: instructionData, encoding: .utf8)
        else {
            return rejected("SKILL.md is not readable UTF-8")
        }
        let parsed: Skill
        do {
            parsed = try Skill.parseAnyFormat(from: markdown)
        } catch {
            return rejected("SKILL.md metadata is invalid: \(error.localizedDescription)")
        }
        let normalizedName = parsed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return rejected("Skill name is empty") }

        let inventory = inspectPackage(
            skillDirectory: skillDirectory,
            projectRoot: projectRoot,
            instructionURL: instructionURL
        )
        if let rejection = inventory.rejection {
            return rejected(rejection, name: normalizedName, files: inventory.files)
        }

        return ProjectSkillRecord(
            id: id,
            name: normalizedName,
            description: parsed.description,
            source: source,
            skillDirectory: Self.relativePath(skillDirectory, under: projectRoot),
            instructionFile: Self.relativePath(instructionURL, under: projectRoot),
            instructions: parsed.instructions,
            approvalHash: Self.approvalHash(markdown: markdown, files: inventory.files),
            files: inventory.files,
            status: .available
        )
    }

    private func inspectPackage(
        skillDirectory: URL,
        projectRoot: URL,
        instructionURL: URL
    ) -> (files: [ProjectSkillFile], rejection: String?) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: skillDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        else { return ([], "Could not enumerate skill package") }

        var files: [ProjectSkillFile] = []
        var count = 0
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            let relativeToSkill = Self.relativePath(url, under: skillDirectory)
            let depth = relativeToSkill.split(separator: "/").count
            if depth > limits.maxPackageDepth {
                return (files, "Skill package exceeds the \(limits.maxPackageDepth)-level depth limit")
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
                )
            } catch {
                enumerator.skipDescendants()
                return (files, "Package entry '\(relativeToSkill)' metadata could not be read")
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                return (files, "Symlinked package entry '\(relativeToSkill)' is not allowed")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                return (files, "Package entry '\(relativeToSkill)' is not a regular file")
            }
            if url.standardizedFileURL == instructionURL.standardizedFileURL { continue }

            count += 1
            if count > limits.maxPackageFiles {
                return (files, "Skill package exceeds the \(limits.maxPackageFiles)-file limit")
            }
            let size = Int64(values.fileSize ?? 0)
            guard size <= limits.maxPackageFileBytes else {
                return (files, "Package entry '\(relativeToSkill)' exceeds the \(limits.maxPackageFileBytes)-byte file limit")
            }
            totalBytes += size
            guard totalBytes <= limits.maxPackageBytes else {
                return (files, "Skill package exceeds the \(limits.maxPackageBytes)-byte total limit")
            }
            guard let data = try? Self.readBoundedFile(url, maximumBytes: limits.maxPackageFileBytes) else {
                return (files, "Package entry '\(relativeToSkill)' could not be hashed")
            }
            guard data.count == size else {
                return (files, "Package entry '\(relativeToSkill)' changed while being hashed")
            }
            files.append(
                ProjectSkillFile(
                    relativePath: Self.relativePath(url, under: projectRoot),
                    kind: Self.fileKind(relativeToSkill),
                    size: size,
                    contentHash: Self.contentHash(data)
                )
            )
        }
        return (files.sorted { $0.relativePath < $1.relativePath }, nil)
    }

    private static func fileKind(_ relativePath: String) -> ProjectSkillFile.Kind {
        let top = relativePath.split(separator: "/").first?.lowercased()
        switch top {
        case "references": return .reference
        case "scripts", "helpers": return .helper
        case "assets", "templates": return .asset
        default: return .other
        }
    }

    static func capabilityID(source: ProjectSkillSource, skillDirectory: String) -> String {
        let encoded = skillDirectory.split(separator: "/", omittingEmptySubsequences: true)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? String(component)
            }
            .joined(separator: "/")
        return "project-skill/\(source.rawValue)/\(encoded)"
    }

    static func rootIdentity(_ root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func approvalHash(markdown: String, files: [ProjectSkillFile]) -> String {
        var material = "SKILL.md\0\(contentHash(Data(markdown.utf8)))\n"
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            material += "\(file.relativePath)\0\(file.kind.rawValue)\0\(file.size)\0\(file.contentHash)\n"
        }
        return contentHash(Data(material.utf8))
    }

    static func relativePath(_ url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return url.lastPathComponent }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    static func isContained(_ url: URL, by root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return resolvedURL.starts(with: resolvedRoot)
    }

    static func isLexicallyContained(_ url: URL, by root: URL) -> Bool {
        url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
    }

    static func containsSymlink(from root: URL, through descendant: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard descendantComponents.starts(with: rootComponents) else { return true }

        var current = root.standardizedFileURL
        for component in descendantComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                return true
            }
            if values.isSymbolicLink == true { return true }
        }
        return false
    }

    private static func readBoundedFile(_ url: URL, maximumBytes: Int64) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EFTYPE) }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw POSIXError(.EFBIG) }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            guard Int64(data.count + count) <= maximumBytes else { throw POSIXError(.EFBIG) }
            data.append(buffer, count: count)
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard
            before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            Int64(data.count) == after.st_size,
            after.st_size <= maximumBytes
        else { throw POSIXError(.EBUSY) }
        return data
    }
}

actor ProjectSkillSessionStore {
    static let shared = ProjectSkillSessionStore()

    struct Grant: Equatable, Sendable {
        let generation: UInt64
        let rootIdentity: String
        var skillIDs: Set<String>
    }

    private var grants: [String: Grant] = [:]
    private var activeGeneration: UInt64 = 0
    private var activeRootIdentity: String?

    func activate(generation: UInt64, rootIdentity: String?) {
        guard generation >= activeGeneration else { return }
        if generation > activeGeneration || rootIdentity != activeRootIdentity {
            grants.removeAll()
        }
        activeGeneration = generation
        activeRootIdentity = rootIdentity
    }

    func record(
        sessionID: String,
        generation: UInt64,
        rootIdentity: String,
        skillID: String
    ) -> Bool {
        guard
            !sessionID.isEmpty,
            generation == activeGeneration,
            rootIdentity == activeRootIdentity
        else { return false }
        if var grant = grants[sessionID],
            grant.generation == generation,
            grant.rootIdentity == rootIdentity {
            grant.skillIDs.insert(skillID)
            grants[sessionID] = grant
        } else {
            grants[sessionID] = Grant(
                generation: generation,
                rootIdentity: rootIdentity,
                skillIDs: [skillID]
            )
        }
        return true
    }

    func grant(sessionID: String) -> Grant? { grants[sessionID] }
}

@Observable
@MainActor
final class ProjectSkillManager {
    static let shared = ProjectSkillManager()

    private(set) var root: URL?
    private(set) var rootIdentity: String?
    private(set) var records: [ProjectSkillRecord] = []
    private(set) var diagnostics: [String] = []
    private(set) var enabledIDs: Set<String> = []
    private(set) var staleApprovalIDs: Set<String> = []
    private(set) var isRefreshing = false

    private let scanner: ProjectSkillScanner
    private let defaults: UserDefaults
    private var scanGeneration = UUID()
    private var scopeGeneration: UInt64 = 0
    private var approvedContentHashes: [String: String] = [:]

    init(scanner: ProjectSkillScanner = ProjectSkillScanner(), defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.defaults = defaults
    }

    var availableRecords: [ProjectSkillRecord] {
        records.filter { $0.status == .available }
    }

    func prepareForFolder(_ newRoot: URL?) {
        scanGeneration = UUID()
        scopeGeneration = ProjectSkillScopeSequence.next()
        root = newRoot?.standardizedFileURL.resolvingSymlinksInPath()
        rootIdentity = root.map(ProjectSkillScanner.rootIdentity)
        records = []
        diagnostics = []
        approvedContentHashes = rootIdentity.map(loadApprovals) ?? [:]
        enabledIDs = []
        staleApprovalIDs = []
        isRefreshing = newRoot != nil
        let generation = scopeGeneration
        let identity = rootIdentity
        Task {
            await ProjectSkillSessionStore.shared.activate(
                generation: generation,
                rootIdentity: identity
            )
        }
    }

    func activate(_ newRoot: URL?) async {
        prepareForFolder(newRoot)
        await refresh()
    }

    func refresh() async {
        guard let root else {
            isRefreshing = false
            return
        }
        let generation = scanGeneration
        isRefreshing = true
        let result = await Task.detached(priority: .utility) { [scanner] in
            scanner.scan(root: root)
        }.value
        guard generation == scanGeneration, self.root?.standardizedFileURL == root.standardizedFileURL else { return }
        rootIdentity = result.rootIdentity
        records = result.records
        diagnostics = result.diagnostics
        let available = Set(result.records.filter { $0.status == .available }.map(\.id))
        let currentHashes = Dictionary(
            uniqueKeysWithValues: result.records.map { ($0.id, $0.approvalHash) }
        )
        staleApprovalIDs = Set(
            approvedContentHashes.compactMap { id, hash in
                guard available.contains(id), currentHashes[id] != hash else { return nil }
                return id
            }
        )
        enabledIDs = Set(
            approvedContentHashes.compactMap { id, hash in
                currentHashes[id] == hash && available.contains(id) ? id : nil
            }
        )
        if !staleApprovalIDs.isEmpty {
            diagnostics.append(
                "Project skill content changed after approval; review and re-enable: "
                    + staleApprovalIDs.sorted().joined(separator: ", ")
            )
        }
        isRefreshing = false
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, id: String) async -> Bool {
        guard let record = records.first(where: { $0.id == id && $0.status == .available }) else {
            return false
        }
        guard enabled else {
            approvedContentHashes.removeValue(forKey: id)
            enabledIDs.remove(id)
            staleApprovalIDs.remove(id)
            saveApprovals()
            return true
        }

        guard let root, let rootIdentity else { return false }
        let generation = scopeGeneration
        let liveRecord = await Task.detached(priority: .userInitiated) { [scanner] in
            scanner.revalidate(root: root, record: record)
        }.value
        guard
            generation == scopeGeneration,
            self.root?.standardizedFileURL == root.standardizedFileURL,
            self.rootIdentity == rootIdentity
        else { return false }
        guard liveRecord == record, liveRecord.status == .available else {
            if let index = records.firstIndex(where: { $0.id == id }) {
                records[index] = liveRecord
            }
            revokeApproval(id: id)
            return false
        }

        approvedContentHashes[id] = liveRecord.approvalHash
        enabledIDs.insert(id)
        staleApprovalIDs.remove(id)
        saveApprovals()
        return true
    }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    func search(
        query: String,
        limit: Int,
        agentID: UUID?
    ) -> [(record: ProjectSkillRecord, score: Float)] {
        guard limit > 0 else { return [] }
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return availableRecords
            .filter { enabledIDs.contains($0.id) && isAgentGranted($0.id, agentID: agentID) }
            .compactMap { record -> (ProjectSkillRecord, Float)? in
                let name = record.name.lowercased()
                let description = record.description.lowercased()
                let paths = record.files.map(\.relativePath).joined(separator: " ").lowercased()
                var score: Float = 0
                for term in terms {
                    if name == term { score += 4 } else if name.contains(term) { score += 2 }
                    if description.contains(term) { score += 1 }
                    if paths.contains(term) { score += 0.5 }
                }
                let maximum = Float(terms.count) * 5.5
                return score > 0 ? (record, min(score / maximum, 1)) : nil
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1
            }
            .prefix(limit)
            .map { $0 }
    }

    func record(id: String) -> ProjectSkillRecord? {
        records.first { $0.id == id }
    }

    func load(
        id: String,
        sessionID: String,
        agentID: UUID?
    ) async -> Result<String, ProjectSkillLoadError> {
        guard let root, let rootIdentity else { return .failure(.noProject) }
        guard let record = record(id: id) else { return .failure(.notFound) }
        guard record.status == .available else {
            return .failure(.rejected(record.status.rejectionReason ?? "Project skill is unavailable"))
        }
        guard enabledIDs.contains(id) else { return .failure(.notEnabled) }
        guard isAgentGranted(id, agentID: agentID) else { return .failure(.notGrantedToAgent) }
        guard !sessionID.isEmpty else { return .failure(.missingSession) }
        guard approvedContentHashes[id] == record.approvalHash else {
            revokeApproval(id: id)
            return .failure(.approvalChanged)
        }

        let generation = scopeGeneration
        await ProjectSkillSessionStore.shared.activate(
            generation: generation,
            rootIdentity: rootIdentity
        )
        let recorded = await ProjectSkillSessionStore.shared.record(
            sessionID: sessionID,
            generation: generation,
            rootIdentity: rootIdentity,
            skillID: id
        )
        guard recorded else { return .failure(.projectChanged) }

        // Re-read the bounded package after all actor hops and render only this
        // freshly hashed snapshot. A changed SKILL.md, helper, reference,
        // asset, inventory entry, or symlink therefore cannot be loaded under
        // an approval granted to older bytes.
        let liveRecord = await Task.detached(priority: .userInitiated) { [scanner] in
            scanner.revalidate(root: root, record: record)
        }.value
        guard
            generation == scopeGeneration,
            self.root?.standardizedFileURL == root.standardizedFileURL,
            self.rootIdentity == rootIdentity,
            enabledIDs.contains(id),
            isAgentGranted(id, agentID: agentID)
        else { return .failure(.projectChanged) }
        guard
            liveRecord.status == .available,
            liveRecord.approvalHash == record.approvalHash,
            approvedContentHashes[id] == liveRecord.approvalHash
        else {
            revokeApproval(id: id)
            return .failure(.approvalChanged)
        }
        return .success(Self.render(liveRecord))
    }

    func isAgentGranted(_ id: String, agentID: UUID?) -> Bool {
        guard let agentID, let rootIdentity else { return false }
        guard Self.canUseProjectSkills(AgentManager.shared.agent(for: agentID)) else {
            return false
        }
        let key = agentGrantKey(rootIdentity: rootIdentity, skillID: id)
        return AgentManager.shared.effectiveEnabledSkillNames(for: agentID)?.contains(key) == true
    }

    func setAgentGranted(_ granted: Bool, id: String, agentID: UUID) {
        guard Self.canUseProjectSkills(AgentManager.shared.agent(for: agentID)) else { return }
        if AgentManager.shared.effectiveEnabledSkillNames(for: agentID) == nil {
            AgentManager.shared.seedEnabledCapabilitiesIfNeeded(
                for: agentID,
                defaultToolNames: ToolRegistry.shared.listTools().filter(\.enabled).map(\.name),
                defaultSkillNames: SkillManager.shared.skills.filter(\.enabled).map(\.name)
            )
        }
        var names = Set(AgentManager.shared.effectiveEnabledSkillNames(for: agentID) ?? [])
        guard let rootIdentity else { return }
        let key = agentGrantKey(rootIdentity: rootIdentity, skillID: id)
        if granted { names.insert(key) } else { names.remove(key) }
        AgentManager.shared.updateEnabledSkillNames(Array(names), for: agentID)
    }

    func agentGrantKey(rootIdentity: String, skillID: String) -> String {
        "project-grant/\(rootIdentity)/\(skillID)"
    }

    static func canUseProjectSkills(_ agent: Agent?) -> Bool {
        guard let agent else { return false }
        return agent.id != Agent.defaultId && !agent.isBuiltIn
    }

    static func render(_ record: ProjectSkillRecord) -> String {
        var lines = [
            "## Project Skill: \(record.name)",
            "Source: \(record.source.rawValue)",
            "Capability ID: \(record.id)",
        ]
        if !record.description.isEmpty { lines.append("\n*\(record.description)*") }
        lines.append("\n\(record.instructions)")
        lines.append("\nLoading a project skill never executes package files or bypasses workspace permissions.")
        if !record.files.isEmpty {
            lines.append("\n### Project-relative package inventory")
            lines.append("These paths are inventory only. Loading this skill never executes helpers. Read or run a path only through the existing workspace tools and their permission policy.")
            for file in record.files {
                lines.append("- [\(file.kind.rawValue)] \(file.relativePath) (\(file.size) bytes)")
            }
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private func defaultsKey(_ rootIdentity: String) -> String {
        "ProjectSkillGrants.\(rootIdentity)"
    }

    private func loadApprovals(_ rootIdentity: String) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey(rootIdentity)) as? [String: String] ?? [:]
    }

    private func saveApprovals() {
        guard let rootIdentity else { return }
        defaults.set(approvedContentHashes, forKey: defaultsKey(rootIdentity))
    }

    private func revokeApproval(id: String) {
        approvedContentHashes.removeValue(forKey: id)
        enabledIDs.remove(id)
        staleApprovalIDs.insert(id)
        saveApprovals()
        let message = "Project skill content changed after approval; review and re-enable: \(id)"
        if !diagnostics.contains(message) { diagnostics.append(message) }
    }
}

enum ProjectSkillLoadError: Error, Equatable, Sendable {
    case noProject
    case notFound
    case notEnabled
    case notGrantedToAgent
    case missingSession
    case projectChanged
    case approvalChanged
    case rejected(String)

    var message: String {
        switch self {
        case .noProject: return "No working directory is selected."
        case .notFound: return "Project skill was not found in the active working directory."
        case .notEnabled: return "Project skill is not enabled for this project."
        case .notGrantedToAgent: return "Project skill is not enabled for this agent."
        case .missingSession: return "Project skills require an active chat session."
        case .projectChanged: return "The working directory changed while the project skill was loading. Try again."
        case .approvalChanged: return "Project skill files changed after approval. Review and enable the package again."
        case .rejected(let reason): return reason
        }
    }
}
