//
//  StorageLocationStandards.swift
//  osaurus
//
//  Storage-location standards audit for issue #1422.
//
//  Osaurus currently keeps its app data in `~/.osaurus/` (see
//  `OsaurusPaths`), which follows neither Apple's file-system guidance
//  (`~/Library/Application Support/...`) nor the XDG base-directory spec
//  (`~/.local/share/...`). Relocating the root is a data-safety decision —
//  the Keychain data-encryption key is paired with the existing tree, the
//  HKDF salt sidecar lives inside it, sandbox tooling references
//  `~/.osaurus` literally, and plugin/container trees can be large — so this
//  module deliberately performs **no migration**. It only classifies the
//  current layout and reports stable reason codes through
//  `/admin/cache-stats` so users and maintainers can see exactly where data
//  lives and why. Classification is a pure function over `Inputs`; the live
//  probe is read-only and never mutates the filesystem.
//

import Foundation
import OsaurusRepository

public enum StorageLocationStandards {

    // MARK: - Model

    /// Where the active app-data root was resolved from.
    public enum RootSource: String, Sendable {
        case standard
        case testOverride = "test_override"
        case environmentOverride = "environment_override"
        /// A non-Default Space under `~/.osaurus-spaces/`.
        case space
    }

    /// Classification of the active app-data root against platform
    /// storage-location conventions.
    public enum RootClassification: String, Sendable {
        case appleApplicationSupport = "apple_application_support"
        case homeDotDirectory = "home_dot_directory"
        case testOverride = "test_override"
        case environmentOverride = "environment_override"
        case space
        case custom
    }

    /// Classification of the model-weights root, reported separately from
    /// the app-data root because user-managed weights are home-visible by
    /// design today.
    public enum ModelsRootClassification: String, Sendable {
        case applicationSupport = "application_support"
        case homeVisible = "home_visible"
        case externalOrCustom = "external_or_custom"
    }

    /// Stable, machine-readable reason codes. These are part of the
    /// diagnostic surface — do not rename existing raw values.
    public enum ReasonCode: String, CaseIterable, Sendable {
        case rootHomeDotDirectoryNotAppleSpec = "root_home_dot_directory_not_apple_spec"
        case rootOverriddenForTests = "root_overridden_for_tests"
        case rootEnvironmentOverride = "root_environment_override"
        case rootCustomLocation = "root_custom_location"
        case rootSpace = "root_space"
        case legacyApplicationSupportRootPresent = "legacy_application_support_root_present"
        case migrationDecisionPending = "migration_decision_pending"
        case modelsRootHomeVisibleByDesign = "models_root_home_visible_by_design"
    }

    public enum Severity: String, Sendable {
        case info
        case warning
    }

    /// One audited fact with a stable code and a human-readable explanation.
    public struct Finding: Equatable, Sendable {
        public let code: ReasonCode
        public let severity: Severity
        public let message: String

        public init(code: ReasonCode, severity: Severity, message: String) {
            self.code = code
            self.severity = severity
            self.message = message
        }
    }

    /// Everything the pure classifier needs. Built by `currentInputs()` in
    /// production; built by hand in tests.
    public struct Inputs: Equatable, Sendable {
        public let activeRootPath: String
        public let rootSource: RootSource
        public let homeDirectoryPath: String
        public let applicationSupportPath: String?
        public let legacyApplicationSupportRootPath: String?
        public let legacyApplicationSupportRootPresent: Bool
        public let legacyApplicationSupportMergeMarkerPath: String?
        public let legacyApplicationSupportMergeMarked: Bool
        public let appleSpecCandidateRootPath: String?
        public let appleSpecCandidateRootPresent: Bool
        public let modelsRootPath: String

        public init(
            activeRootPath: String,
            rootSource: RootSource,
            homeDirectoryPath: String,
            applicationSupportPath: String?,
            legacyApplicationSupportRootPath: String?,
            legacyApplicationSupportRootPresent: Bool,
            legacyApplicationSupportMergeMarkerPath: String?,
            legacyApplicationSupportMergeMarked: Bool,
            appleSpecCandidateRootPath: String?,
            appleSpecCandidateRootPresent: Bool,
            modelsRootPath: String
        ) {
            self.activeRootPath = activeRootPath
            self.rootSource = rootSource
            self.homeDirectoryPath = homeDirectoryPath
            self.applicationSupportPath = applicationSupportPath
            self.legacyApplicationSupportRootPath = legacyApplicationSupportRootPath
            self.legacyApplicationSupportRootPresent = legacyApplicationSupportRootPresent
            self.legacyApplicationSupportMergeMarkerPath = legacyApplicationSupportMergeMarkerPath
            self.legacyApplicationSupportMergeMarked = legacyApplicationSupportMergeMarked
            self.appleSpecCandidateRootPath = appleSpecCandidateRootPath
            self.appleSpecCandidateRootPresent = appleSpecCandidateRootPresent
            self.modelsRootPath = modelsRootPath
        }
    }

    /// Audit result. `reasonCodes` mirrors `findings` for compact consumers.
    public struct Report: Equatable, Sendable {
        public let classification: RootClassification
        public let specCompliant: Bool
        public let activeRootPath: String
        public let appleSpecCandidateRootPath: String?
        public let appleSpecCandidateRootPresent: Bool
        public let legacyApplicationSupportRootPath: String?
        public let legacyApplicationSupportRootPresent: Bool
        public let legacyApplicationSupportMergeMarkerPath: String?
        public let legacyApplicationSupportMergeMarked: Bool
        public let modelsRootPath: String
        public let modelsRootClassification: ModelsRootClassification
        public let findings: [Finding]

        public var reasonCodes: [String] {
            findings.map { $0.code.rawValue }
        }

        public var summary: String {
            let compliance = specCompliant ? "apple-spec" : "non-compliant"
            let legacy = legacyApplicationSupportRootPresent ? "present" : "absent"
            return "root=\(classification.rawValue) (\(compliance)); "
                + "legacy_root=\(legacy); "
                + "models_root=\(modelsRootClassification.rawValue)"
        }

        public init(
            classification: RootClassification,
            specCompliant: Bool,
            activeRootPath: String,
            appleSpecCandidateRootPath: String?,
            appleSpecCandidateRootPresent: Bool,
            legacyApplicationSupportRootPath: String?,
            legacyApplicationSupportRootPresent: Bool,
            legacyApplicationSupportMergeMarkerPath: String?,
            legacyApplicationSupportMergeMarked: Bool,
            modelsRootPath: String,
            modelsRootClassification: ModelsRootClassification,
            findings: [Finding]
        ) {
            self.classification = classification
            self.specCompliant = specCompliant
            self.activeRootPath = activeRootPath
            self.appleSpecCandidateRootPath = appleSpecCandidateRootPath
            self.appleSpecCandidateRootPresent = appleSpecCandidateRootPresent
            self.legacyApplicationSupportRootPath = legacyApplicationSupportRootPath
            self.legacyApplicationSupportRootPresent = legacyApplicationSupportRootPresent
            self.legacyApplicationSupportMergeMarkerPath = legacyApplicationSupportMergeMarkerPath
            self.legacyApplicationSupportMergeMarked = legacyApplicationSupportMergeMarked
            self.modelsRootPath = modelsRootPath
            self.modelsRootClassification = modelsRootClassification
            self.findings = findings
        }
    }

    // MARK: - Live probe (read-only)

    /// Name of the legacy pre-`~/.osaurus` root under Application Support.
    public static let legacyApplicationSupportFolderName = "com.dinoki.osaurus"

    /// Proposed Apple-spec folder name under Application Support. Reported
    /// as a candidate only; nothing is created or moved.
    public static let appleSpecCandidateFolderName = "Osaurus"

    /// Gather live inputs. Read-only: performs `fileExists` probes plus the
    /// same root resolution `OsaurusPaths.root()` already performed for the
    /// running process; it never creates, copies, or deletes anything.
    public static func currentInputs(fileManager fm: FileManager = .default) -> Inputs {
        let testRootOverride = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rootSource: RootSource
        if OsaurusPaths.overrideRoot != nil {
            rootSource = .testOverride
        } else if testRootOverride?.isEmpty == false {
            rootSource = .environmentOverride
        } else if !SpaceRegistry.isDefaultActive {
            rootSource = .space
        } else {
            rootSource = .standard
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let legacy = support?.appendingPathComponent(
            legacyApplicationSupportFolderName,
            isDirectory: true
        )
        let candidate = support?.appendingPathComponent(
            appleSpecCandidateFolderName,
            isDirectory: true
        )
        let activeRoot = OsaurusPaths.root()
        let mergeMarker = OsaurusPaths.legacyApplicationSupportMergeMarker(for: activeRoot)
        return Inputs(
            activeRootPath: activeRoot.path,
            rootSource: rootSource,
            homeDirectoryPath: fm.homeDirectoryForCurrentUser.path,
            applicationSupportPath: support?.path,
            legacyApplicationSupportRootPath: legacy?.path,
            legacyApplicationSupportRootPresent: legacy.map { fm.fileExists(atPath: $0.path) }
                ?? false,
            legacyApplicationSupportMergeMarkerPath: mergeMarker.path,
            legacyApplicationSupportMergeMarked: fm.fileExists(atPath: mergeMarker.path),
            appleSpecCandidateRootPath: candidate?.path,
            appleSpecCandidateRootPresent: candidate.map { fm.fileExists(atPath: $0.path) }
                ?? false,
            modelsRootPath: DirectoryPickerService.effectiveModelsDirectory().path
        )
    }

    /// Convenience: live probe + pure classification.
    public static func currentReport(fileManager: FileManager = .default) -> Report {
        audit(currentInputs(fileManager: fileManager))
    }

    // MARK: - Pure classification

    public static func audit(_ inputs: Inputs) -> Report {
        let classification = classifyRoot(inputs)
        let modelsClassification = classifyModelsRoot(inputs)
        var findings: [Finding] = []

        switch classification {
        case .appleApplicationSupport:
            break
        case .homeDotDirectory:
            findings.append(
                Finding(
                    code: .rootHomeDotDirectoryNotAppleSpec,
                    severity: .warning,
                    message:
                        "App data root \(inputs.activeRootPath) is a home dot-directory. "
                        + "Apple's file-system guidance places app data under "
                        + "~/Library/Application Support; the XDG equivalent is "
                        + "~/.local/share. See docs/STORAGE.md (Storage Location Standards)."
                )
            )
        case .testOverride:
            findings.append(
                Finding(
                    code: .rootOverriddenForTests,
                    severity: .info,
                    message:
                        "Storage root is overridden via OsaurusPaths.overrideRoot for tests; "
                        + "spec compliance was not assessed."
                )
            )
        case .environmentOverride:
            findings.append(
                Finding(
                    code: .rootEnvironmentOverride,
                    severity: .info,
                    message:
                        "Storage root is overridden via OSAURUS_TEST_ROOT; "
                        + "spec compliance was not assessed."
                )
            )
        case .space:
            findings.append(
                Finding(
                    code: .rootSpace,
                    severity: .info,
                    message:
                        "Storage root \(inputs.activeRootPath) belongs to a non-Default Space "
                        + "under ~/.osaurus-spaces; spec compliance was not assessed."
                )
            )
        case .custom:
            findings.append(
                Finding(
                    code: .rootCustomLocation,
                    severity: .info,
                    message:
                        "Storage root \(inputs.activeRootPath) is neither the default home "
                        + "dot-directory nor under Application Support."
                )
            )
        }

        if inputs.legacyApplicationSupportRootPresent {
            let legacyPath =
                inputs.legacyApplicationSupportRootPath
                ?? legacyApplicationSupportFolderName
            let markerPath =
                inputs.legacyApplicationSupportMergeMarkerPath
                ?? OsaurusPaths.legacyApplicationSupportMergeMarkerName
            let severity: Severity = inputs.legacyApplicationSupportMergeMarked ? .info : .warning
            let message: String
            if inputs.legacyApplicationSupportMergeMarked {
                message =
                    "Legacy root \(legacyPath) still exists, but one-shot migration marker "
                    + "\(markerPath) is present. OsaurusPaths will not re-merge it into "
                    + "the active root on future launches."
            } else {
                message =
                    "Legacy root \(legacyPath) still exists and one-shot migration marker "
                    + "\(markerPath) is missing. OsaurusPaths will copy or merge it into "
                    + "the active root once, then write the marker so future launches do "
                    + "not resurrect stale legacy files."
            }
            findings.append(
                Finding(
                    code: .legacyApplicationSupportRootPresent,
                    severity: severity,
                    message: message
                )
            )
        }

        if classification == .homeDotDirectory || inputs.legacyApplicationSupportRootPresent {
            findings.append(
                Finding(
                    code: .migrationDecisionPending,
                    severity: .info,
                    message:
                        "Relocating the storage root is deferred pending a maintainer "
                        + "decision: the Keychain data-encryption key is paired with the "
                        + "current tree, the HKDF salt sidecar lives inside it, sandbox "
                        + "tooling references ~/.osaurus literally, and plugin/container "
                        + "trees can be large."
                )
            )
        }

        let usesStandardRoot = classification != .testOverride && classification != .environmentOverride
        if usesStandardRoot && modelsClassification == .homeVisible {
            findings.append(
                Finding(
                    code: .modelsRootHomeVisibleByDesign,
                    severity: .info,
                    message:
                        "Model weights root \(inputs.modelsRootPath) is a home-visible "
                        + "folder (user-managed weights by design); it is a separate "
                        + "decision from the app-data root."
                )
            )
        }

        return Report(
            classification: classification,
            specCompliant: classification == .appleApplicationSupport,
            activeRootPath: inputs.activeRootPath,
            appleSpecCandidateRootPath: inputs.appleSpecCandidateRootPath,
            appleSpecCandidateRootPresent: inputs.appleSpecCandidateRootPresent,
            legacyApplicationSupportRootPath: inputs.legacyApplicationSupportRootPath,
            legacyApplicationSupportRootPresent: inputs.legacyApplicationSupportRootPresent,
            legacyApplicationSupportMergeMarkerPath: inputs.legacyApplicationSupportMergeMarkerPath,
            legacyApplicationSupportMergeMarked: inputs.legacyApplicationSupportMergeMarked,
            modelsRootPath: inputs.modelsRootPath,
            modelsRootClassification: modelsClassification,
            findings: findings
        )
    }

    // MARK: - JSON

    /// Snake-case JSON object for `/admin/cache-stats`. Mirrors the
    /// `memory_safety` block conventions (NSNull for absent optionals).
    public static func jsonObject(for report: Report) -> [String: Any] {
        [
            "classification": report.classification.rawValue,
            "spec_compliant": report.specCompliant,
            "active_root": report.activeRootPath,
            "apple_spec_candidate_root": report.appleSpecCandidateRootPath as Any? ?? NSNull(),
            "apple_spec_candidate_root_present": report.appleSpecCandidateRootPresent,
            "legacy_application_support_root": report.legacyApplicationSupportRootPath as Any?
                ?? NSNull(),
            "legacy_application_support_root_present": report.legacyApplicationSupportRootPresent,
            "legacy_application_support_merge_marker":
                report.legacyApplicationSupportMergeMarkerPath as Any? ?? NSNull(),
            "legacy_application_support_merge_marked": report.legacyApplicationSupportMergeMarked,
            "models_root": report.modelsRootPath,
            "models_root_classification": report.modelsRootClassification.rawValue,
            "reason_codes": report.reasonCodes,
            "findings": report.findings.map { finding in
                [
                    "code": finding.code.rawValue,
                    "severity": finding.severity.rawValue,
                    "message": finding.message,
                ]
            },
            "summary": report.summary,
        ]
    }

    // MARK: - Helpers

    private static func classifyRoot(_ inputs: Inputs) -> RootClassification {
        switch inputs.rootSource {
        case .testOverride:
            return .testOverride
        case .environmentOverride:
            return .environmentOverride
        case .space:
            return .space
        case .standard:
            break
        }
        let activeRootIsInApplicationSupport =
            inputs.applicationSupportPath.map { isSubpath(inputs.activeRootPath, of: $0) } ?? false
        if activeRootIsInApplicationSupport {
            return .appleApplicationSupport
        }
        let root = URL(fileURLWithPath: normalizedPath(inputs.activeRootPath))
        let rootParentPath = root.deletingLastPathComponent().path
        let normalizedHomePath = normalizedPath(inputs.homeDirectoryPath)
        if root.lastPathComponent.hasPrefix(".") && rootParentPath == normalizedHomePath {
            return .homeDotDirectory
        }
        return .custom
    }

    private static func classifyModelsRoot(_ inputs: Inputs) -> ModelsRootClassification {
        let modelsRootIsInApplicationSupport =
            inputs.applicationSupportPath.map { isSubpath(inputs.modelsRootPath, of: $0) } ?? false
        if modelsRootIsInApplicationSupport {
            return .applicationSupport
        }
        if isSubpath(inputs.modelsRootPath, of: inputs.homeDirectoryPath) {
            return .homeVisible
        }
        return .externalOrCustom
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isSubpath(_ path: String, of parent: String) -> Bool {
        let child = normalizedPath(path)
        let base = normalizedPath(parent)
        if child == base {
            return true
        }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return child.hasPrefix(prefix)
    }
}
