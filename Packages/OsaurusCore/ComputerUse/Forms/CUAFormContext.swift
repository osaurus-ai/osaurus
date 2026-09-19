import Darwin
import Foundation

enum CUAFormsError: LocalizedError, Sendable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

struct CUAFormEntity: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var label: String
    var value: String
    var source: String?

    var option: String { "fill \(label): \(value)" }
}

struct CUAFormProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var entities: [CUAFormEntity] = []

    func validatedEntities() throws -> [CUAFormEntity] {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.utf8.count <= 160, (1 ... 64).contains(entities.count)
        else { throw CUAFormsError.invalid("Name the profile and provide 1–64 fields.") }
        var labels = Set<String>()
        var encodedOptions = Set<[UInt8]>()
        for entity in entities {
            let label = entity.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label == entity.label, label.utf8.count <= 160,
                !entity.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                entity.value.utf8.count <= 1024,
                !label.contains(where: { $0.isNewline }),
                !entity.value.contains(where: { $0.isNewline })
            else {
                throw CUAFormsError.invalid("Each field needs a single-line label and value (160/1024 byte limits).")
            }
            guard labels.insert(label.lowercased()).inserted else {
                throw CUAFormsError.invalid("Resolve duplicate field labels before saving.")
            }
            guard encodedOptions.insert(Array(entity.option.utf8.prefix(96))).inserted else {
                throw CUAFormsError.invalid(
                    "Two fields become identical at the scorer's 96-byte limit. Shorten their labels."
                )
            }
        }
        return entities
    }
}

/// A user-created grant belongs to the executing agent, not its parent or
/// sibling. Creating it explicitly permits values in page/chat/model context.
struct CUAFormAgentGrant: Codable, Equatable, Sendable {
    let agentID: UUID
    var profileID: UUID
}

struct CUAFormsConfiguration: Codable, Equatable, Sendable {
    var version = 1
    var enabled = false
    var modelDirectory: String?
    var selectedProfileID: UUID?
    var profiles: [CUAFormProfile] = []
    // Optional for backwards-compatible decoding of manual-only profiles.
    var agentGrants: [CUAFormAgentGrant]?

    func validate() throws {
        guard version == 1, profiles.count <= 16,
            Set(profiles.map(\.id)).count == profiles.count,
            modelDirectory.map({ $0.utf8.count <= 4096 }) ?? true,
            selectedProfileID.map({ id in profiles.contains { $0.id == id } }) ?? true
        else { throw CUAFormsError.invalid("Invalid form-context configuration.") }
        for profile in profiles { _ = try profile.validatedEntities() }
        let grants = agentGrants ?? []
        guard grants.count <= 128, Set(grants.map(\.agentID)).count == grants.count,
            grants.allSatisfy({ grant in profiles.contains { $0.id == grant.profileID } })
        else { throw CUAFormsError.invalid("Form profile grants must name unique agents and existing profiles.") }
    }
}

/// Owns this feature's explicit local data. A saved profile alone never grants
/// an agent access. No profile is injected into prompts or general memory.
actor CUAFormContextStore {
    private let directory: URL

    init(directory: URL = OsaurusPaths.formContexts()) { self.directory = directory }

    func load() throws -> CUAFormsConfiguration {
        let file = directory.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return CUAFormsConfiguration() }
        let config = try JSONDecoder().decode(
            CUAFormsConfiguration.self,
            from: CUAFormsFile.read(file, limit: 2 * 1024 * 1024)
        )
        try config.validate()
        return config
    }

    func save(_ config: CUAFormsConfiguration) throws {
        try config.validate()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CUAFormsError.invalid("The form-context directory must be a real private directory.")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("profiles.json")
        let data = try JSONEncoder().encode(config)
        // Directory permissions protect even the atomic writer's temporary file.
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Immutable, run-owned authority. Re-reading settings may revoke this grant,
/// but must never substitute another profile or silently widen its scope.
struct CUAFormsRunContext: Equatable, Sendable {
    let agentID: UUID
    let profile: CUAFormProfile
    let modelDirectory: String

    static func resolve(configuration: CUAFormsConfiguration, agentID: UUID) throws -> Self? {
        try configuration.validate()
        guard configuration.enabled,
            let grant = configuration.agentGrants?.first(where: { $0.agentID == agentID }),
            let profile = configuration.profiles.first(where: { $0.id == grant.profileID }),
            let directory = configuration.modelDirectory, !directory.isEmpty
        else { return nil }
        return Self(agentID: agentID, profile: profile, modelDirectory: directory)
    }

    func validateCurrent(_ configuration: CUAFormsConfiguration) throws {
        guard try Self.resolve(configuration: configuration, agentID: agentID) == self else {
            throw CUAFormsError.invalid("Form access or context changed. Start a new run after reviewing settings.")
        }
    }
}

enum CUAFormsFile {
    /// Bounded regular-file read, no FIFO/device/symlink and no check-then-open
    /// race. Callers pass only user-selected files or app-owned configuration.
    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL else { throw CUAFormsError.invalid("Choose a local file.") }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CUAFormsError.invalid("Cannot open the selected local file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size >= 0, info.st_size <= limit
        else { throw CUAFormsError.invalid("Expected a regular file within the documented size limit.") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == info.st_size, data.count <= limit else {
            throw CUAFormsError.invalid("The selected file changed or exceeded its size limit while reading.")
        }
        return data
    }
}

enum CUAFormContextImport {
    /// Candidates only: nothing is persisted or made available to a form until
    /// the user reviews and saves. No OCR, inferred identity, or LLM extraction.
    static func candidates(from text: String, source: String) throws -> [CUAFormEntity] {
        guard text.utf8.count <= 1_000_000 else {
            throw CUAFormsError.invalid("Document text exceeds the 1 MB form-context import limit.")
        }
        let pattern = #"^\s*([A-Za-z][A-Za-z0-9 .'/#&()-]{1,40}?)\s*[:\u2013-]\s+(.+?)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var pairs = Set<String>()
        var result: [CUAFormEntity] = []
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                let labelRange = Range(match.range(at: 1), in: line),
                let valueRange = Range(match.range(at: 2), in: line)
            else { continue }
            let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
            let value = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
            // Do not silently truncate a real value and later type bad data.
            guard value.utf8.count <= 1024 else {
                throw CUAFormsError.invalid("An imported field exceeds 1024 bytes; shorten it before import.")
            }
            if pairs.insert(label + "\u{0}" + value).inserted {
                result.append(CUAFormEntity(label: label, value: value, source: source))
            }
            guard result.count <= 64 else {
                throw CUAFormsError.invalid("More than 64 fields were found. Import a smaller document.")
            }
        }
        guard !result.isEmpty else {
            throw CUAFormsError.invalid(
                "No Label: value fields found. Scanned PDFs need OCR elsewhere; enter fields manually."
            )
        }
        return result
    }

    static func document(_ url: URL) async throws -> [CUAFormEntity] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "txt" || ext == "md" {
            let data = try CUAFormsFile.read(url, limit: 1_000_000)
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw CUAFormsError.invalid("Text imports must be UTF-8.")
            }
            text = decoded
        } else {
            // Bound/validate the file before handing it to existing adapters.
            _ = try CUAFormsFile.read(url, limit: DocumentTextExtractionCache.maxDocumentBytes)
            let extracted = try await DocumentTextExtractionCache.shared.units(for: url)
            text = extracted.units.map(\.text).joined(separator: "\n")
        }
        try Task.checkCancellation()
        return try candidates(from: text, source: url.lastPathComponent)
    }
}
