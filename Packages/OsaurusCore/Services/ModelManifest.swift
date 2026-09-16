import Foundation

/// The optional publisher contract shared by discovery, downloads and runtime admission.
/// Absence is a legacy bundle; an unreadable or malformed present file is not absence.
struct ModelManifest: Equatable, Sendable {
    static let filename = "osaurus.json"
    static let maximumBytes = 65_536
    static let pendingUpdateFilename = ".osaurus-update-in-progress"

    let requiredOsaurusVersion: String?
    let modelVersion: String?

    struct Failure: LocalizedError, Equatable, Sendable {
        enum Reason: String, Sendable {
            case invalidManifest, requiresOsaurusUpdate, unknownOsaurusVersion, incompleteModelUpdate
        }
        let reason: Reason
        let message: String
        var errorDescription: String? { message }
    }

    enum Local: Equatable, Sendable {
        case absent
        case present(ModelManifest)
        case invalid(Failure)

        var manifest: ModelManifest? {
            if case .present(let manifest) = self { return manifest }
            return nil
        }
    }

    static var hostVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static func decode(_ data: Data) throws -> ModelManifest {
        guard data.count <= maximumBytes else { throw invalid("The file exceeds 64 KiB.") }
        struct Fields: Decodable {
            let required_osaurus_version: String
            let model_version: String
        }
        let fields: Fields
        do { fields = try JSONDecoder().decode(Fields.self, from: data) } catch {
            throw invalid("Expected a JSON object with string version fields.")
        }
        if Version(fields.required_osaurus_version) == nil {
            throw invalid("required_osaurus_version must be a semantic version, such as 0.25.0.")
        }
        if !isDecimal(fields.model_version) {
            throw invalid("model_version must be a non-negative decimal revision string, such as 1.")
        }
        return ModelManifest(
            requiredOsaurusVersion: fields.required_osaurus_version,
            modelVersion: fields.model_version
        )
    }

    static func read(at directory: URL) -> Local {
        let url = directory.appendingPathComponent(filename)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return .present(try decode(handle.read(upToCount: maximumBytes + 1) ?? Data()))
        } catch let error as Failure {
            return .invalid(error)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
                nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
            {
                return .absent
            }
            return .invalid(invalid("The file could not be read."))
        }
    }

    static func invalid(_ detail: String) -> Failure {
        Failure(
            reason: .invalidManifest,
            message: "Invalid osaurus.json. \(detail) Repair the model or contact its publisher."
        )
    }

    func compatibilityFailure(hostVersion: String) -> Failure? {
        guard let requiredOsaurusVersion else { return nil }
        guard let required = Version(requiredOsaurusVersion) else {
            return Self.invalid("Invalid required_osaurus_version.")
        }
        guard let current = Version(hostVersion, allowShort: true) else {
            return Failure(
                reason: .unknownOsaurusVersion,
                message:
                    "This model requires Osaurus \(requiredOsaurusVersion) or later, but this app's version could not be read. Install a versioned Osaurus build."
            )
        }
        guard current < required else { return nil }
        return Failure(
            reason: .requiresOsaurusUpdate,
            message:
                "This model requires Osaurus \(requiredOsaurusVersion) or later; this app is \(hostVersion). Update Osaurus before loading this model."
        )
    }

    static func loadFailure(at directory: URL, hostVersion: String = hostVersion) -> Failure? {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(pendingUpdateFilename).path) {
            return Failure(
                reason: .incompleteModelUpdate,
                message: "This model's update did not finish. Resume the download or use Repair before loading it."
            )
        }
        switch read(at: directory) {
        case .absent: return nil
        case .present(let manifest): return manifest.compatibilityFailure(hostVersion: hostVersion)
        case .invalid(let failure): return failure
        }
    }

    static func validateLoad(at directory: URL, hostVersion: String = hostVersion) throws {
        if let failure = loadFailure(at: directory, hostVersion: hostVersion) { throw failure }
    }

    /// Only explicit Repair may remove a sidecar no longer advertised by the
    /// pinned repository, after every remaining file has been verified/restored.
    @discardableResult
    static func removeObsoleteManifest(at directory: URL, advertised: Bool, explicitRepair: Bool) throws -> Bool {
        guard explicitRepair, !advertised else { return false }
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular || type == .typeSymbolicLink
        else {
            throw invalid("osaurus.json is not a file.")
        }
        try FileManager.default.removeItem(at: url)
        return true
    }

    /// Publisher revisions are decimal counters, not lexicographic strings or app versions.
    /// Missing/unknown revisions do not imply that an installed model is version zero.
    func isNewer(than installed: ModelManifest) -> Bool {
        guard let remote = modelVersion, let local = installed.modelVersion else { return false }
        return Self.decimalLess(local, remote)
    }

    private static func isDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48 ... 57).contains($0) }
    }

    private static func decimalLess(_ lhs: String, _ rhs: String) -> Bool {
        let l = lhs.drop(while: { $0 == "0" }), r = rhs.drop(while: { $0 == "0" })
        return l.count == r.count ? l.lexicographicallyPrecedes(r) : l.count < r.count
    }

    /// Strict SemVer precedence, with one/two component Apple bundle versions accepted
    /// only for the host. Numeric identifiers compare without machine-integer overflow.
    struct Version: Comparable, Sendable {
        let core: [String]
        let prerelease: [String]

        init?(_ string: String, allowShort: Bool = false) {
            let parts = string.split(separator: "+", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            if parts.count == 2, !Self.validIdentifiers(String(parts[1]), prerelease: false) { return nil }
            let pre = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            var core = pre[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (allowShort ? (1 ... 3).contains(core.count) : core.count == 3),
                core.allSatisfy({ ModelManifest.isDecimal($0) && ($0 == "0" || !$0.hasPrefix("0")) })
            else { return nil }
            while core.count < 3 { core.append("0") }
            self.core = core
            if pre.count == 2 {
                guard Self.validIdentifiers(String(pre[1]), prerelease: true) else { return nil }
                prerelease = pre[1].split(separator: ".").map(String.init)
            } else {
                prerelease = []
            }
        }

        private static func validIdentifiers(_ value: String, prerelease: Bool) -> Bool {
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
                guard !part.isEmpty,
                    part.utf8.allSatisfy({
                        (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45
                    })
                else { return false }
                return !prerelease || !ModelManifest.isDecimal(String(part)) || part == "0" || !part.hasPrefix("0")
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            for (l, r) in zip(lhs.core, rhs.core) where l != r { return ModelManifest.decimalLess(l, r) }
            if lhs.prerelease.isEmpty { return false }
            if rhs.prerelease.isEmpty { return true }
            for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
                let ln = ModelManifest.isDecimal(l), rn = ModelManifest.isDecimal(r)
                if ln && rn { return ModelManifest.decimalLess(l, r) }
                if ln != rn { return ln }
                return l < r
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }
}
