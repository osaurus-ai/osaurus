//
//  SandboxProvisioningDiagnostics.swift
//  osaurus
//
//  Host-side preflight for the sandbox provisioning paths and prerequisites.
//

import Foundation

public enum SandboxProvisioningReadiness: String, Codable, Sendable {
    case ready
    case needsSetup = "needs_setup"
    case blocked
    case unproven

    public var label: String {
        switch self {
        case .ready: L("Ready")
        case .needsSetup: L("Needs setup")
        case .blocked: L("Blocked")
        case .unproven: L("Unproven")
        }
    }
}

public enum SandboxProvisioningRootSource: String, Codable, Sendable {
    case defaultHome = "default_home"
    case testOverride = "test_override"
    case environmentOverride = "environment_override"
}

public enum SandboxProvisioningConfigurationSource: String, Codable, Sendable {
    case loaded
    case missingUsingDefaults = "missing_using_defaults"
    case invalidUsingDefaults = "invalid_using_defaults"
}

public enum SandboxProvisioningLocationID: String, Codable, Sendable, CaseIterable {
    case root
    case configDirectory = "config_directory"
    case configFile = "config_file"
    case cacheDirectory = "cache_directory"
    case temporaryDirectory = "temporary_directory"
    case containerRoot = "container_root"
    case containerWorkspace = "container_workspace"
    case containerAgents = "container_agents"
    case containerShared = "container_shared"
    case containerKernelDirectory = "container_kernel_directory"
    case containerKernelFile = "container_kernel_file"
    case containerInitFSFile = "container_initfs_file"
    case containerStateDirectory = "container_state_directory"
    case containerRootFSFile = "container_rootfs_file"
    case bridgeSocket = "bridge_socket"
}

public enum SandboxProvisioningLocationKind: String, Codable, Sendable {
    case directory
    case file
    case socket
}

public enum SandboxProvisioningLocationStage: String, Codable, Sendable {
    case hostStorage = "host_storage"
    case provisioningAsset = "provisioning_asset"
    case runtime
}

public enum SandboxProvisioningLocationStatus: String, Codable, Sendable {
    case ready
    case missing
    case wrongType = "wrong_type"
    case notWritable = "not_writable"
    case notReadable = "not_readable"
    case emptyFile = "empty_file"
    case unproven
}

public enum SandboxProvisioningFindingSeverity: String, Codable, Sendable {
    case ok
    case info
    case warning
    case blocked
}

public enum SandboxProvisioningFindingStatus: String, Codable, Sendable {
    case passed
    case missing
    case failed
    case unproven
}

public enum SandboxProvisioningFindingCode: String, Codable, Sendable, CaseIterable {
    case rootOverrideActive = "root_override_active"
    case sandboxUnavailable = "sandbox_unavailable"
    case unsupportedArchitecture = "unsupported_architecture"
    case configMissing = "config_missing"
    case configInvalid = "config_invalid"
    case setupIncomplete = "setup_incomplete"
    case locationMissing = "location_missing"
    case locationWrongType = "location_wrong_type"
    case locationNotWritable = "location_not_writable"
    case locationNotReadable = "location_not_readable"
    case locationEmpty = "location_empty"
    case volumeFreeSpaceLow = "volume_free_space_low"
    case volumeFreeSpaceUnproven = "volume_free_space_unproven"
}

public struct SandboxProvisioningConfigurationSnapshot: Codable, Sendable, Equatable {
    public let path: String
    public let source: SandboxProvisioningConfigurationSource
    public let cpus: Int
    public let memoryGB: Int
    public let network: String
    public let autoStart: Bool
    public let setupComplete: Bool
    public let error: String?
}

public struct SandboxProvisioningLocation: Codable, Sendable, Equatable, Identifiable {
    public let id: SandboxProvisioningLocationID
    public let title: String
    public let path: String
    public let kind: SandboxProvisioningLocationKind
    public let stage: SandboxProvisioningLocationStage
    public let status: SandboxProvisioningLocationStatus
    public let exists: Bool
    public let readable: Bool?
    public let writable: Bool?
    public let fileSizeBytes: Int64?
    public let volumeFreeBytes: Int64?
    public let volumeTotalBytes: Int64?
    public let detail: String
    public let repairSuggestion: String?
}

public struct SandboxProvisioningFinding: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let code: SandboxProvisioningFindingCode
    public let severity: SandboxProvisioningFindingSeverity
    public let status: SandboxProvisioningFindingStatus
    public let title: String
    public let detail: String
    public let repairSuggestion: String
    public let locationID: SandboxProvisioningLocationID?
    public let path: String?
}

public struct SandboxProvisioningReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let overallReadiness: SandboxProvisioningReadiness
    public let rootSource: SandboxProvisioningRootSource
    public let osMajorVersion: Int
    public let isAppleSilicon: Bool
    public let minimumColdProvisionFreeBytes: Int64
    public let configuration: SandboxProvisioningConfigurationSnapshot
    public let locations: [SandboxProvisioningLocation]
    public let findings: [SandboxProvisioningFinding]

    public var blockingFindings: [SandboxProvisioningFinding] {
        findings.filter { $0.severity == .blocked }
    }

    public var warningFindings: [SandboxProvisioningFinding] {
        findings.filter { $0.severity == .warning }
    }

    public func jsonString(prettyPrinted: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public var plainTextReport: String {
        let timestamp = ISO8601DateFormatter().string(from: generatedAt)
        var lines: [String] = [
            "Sandbox Provisioning Diagnostics",
            "Generated: \(timestamp)",
            "Readiness: \(overallReadiness.rawValue)",
            "Root source: \(rootSource.rawValue)",
            "OS major: \(osMajorVersion)",
            "Apple Silicon: \(isAppleSilicon ? "yes" : "no")",
            "Minimum cold-provision free space: \(Self.formatBytes(minimumColdProvisionFreeBytes))",
            "",
            "Configuration:",
            "- path: \(configuration.path)",
            "- source: \(configuration.source.rawValue)",
            "- cpus: \(configuration.cpus)",
            "- memory_gb: \(configuration.memoryGB)",
            "- network: \(configuration.network)",
            "- auto_start: \(configuration.autoStart)",
            "- setup_complete: \(configuration.setupComplete)",
        ]
        if let error = configuration.error {
            lines.append("- error: \(error)")
        }

        lines.append("")
        lines.append("Findings:")
        if findings.isEmpty {
            lines.append("- none")
        } else {
            for finding in findings {
                lines.append(
                    "- [\(finding.severity.rawValue)/\(finding.status.rawValue)] \(finding.code.rawValue): \(finding.title)"
                )
                lines.append("  detail: \(finding.detail)")
                if let path = finding.path {
                    lines.append("  path: \(path)")
                }
                lines.append("  repair: \(finding.repairSuggestion)")
            }
        }

        lines.append("")
        lines.append("Locations:")
        for location in locations {
            var row = "- [\(location.status.rawValue)] \(location.id.rawValue): \(location.path)"
            if let free = location.volumeFreeBytes {
                row += " (free: \(Self.formatBytes(free)))"
            }
            lines.append(row)
            if !location.detail.isEmpty {
                lines.append("  detail: \(location.detail)")
            }
            if let repair = location.repairSuggestion {
                lines.append("  repair: \(repair)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(bytes) \(units[index])"
        }
        return String(format: "%.1f %@", value, units[index])
    }
}

public enum SandboxProvisioningDiagnostics {
    public static let schemaVersion = 1
    public static let defaultMinimumColdProvisionFreeBytes: Int64 = 12 * 1024 * 1024 * 1024

    public static func makeReport(
        generatedAt: Date = Date(),
        minimumColdProvisionFreeBytes: Int64 = defaultMinimumColdProvisionFreeBytes,
        operatingSystemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        isAppleSilicon: Bool = defaultIsAppleSilicon,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager fm: FileManager = .default
    ) -> SandboxProvisioningReport {
        let rootSource = resolvedRootSource(environment: environment)
        let specs = locationSpecs()
        var locations: [SandboxProvisioningLocation] = []
        var findings: [SandboxProvisioningFinding] = []

        if rootSource != .defaultHome {
            findings.append(
                finding(
                    code: .rootOverrideActive,
                    severity: .info,
                    status: .passed,
                    title: L("Custom sandbox root is active"),
                    detail: L("Diagnostics are using \(OsaurusPaths.root().standardizedFileURL.path)."),
                    repairSuggestion:
                        L("Unset OSAURUS_TEST_ROOT or clear OsaurusPaths.overrideRoot to return to the default root."),
                    locationID: .root,
                    path: OsaurusPaths.root().standardizedFileURL.path
                )
            )
        }

        if operatingSystemMajorVersion < 26 {
            findings.append(
                finding(
                    code: .sandboxUnavailable,
                    severity: .blocked,
                    status: .failed,
                    title: L("macOS version does not support sandbox provisioning"),
                    detail:
                        L(
                            "The sandbox requires macOS 26 or later; this host reports macOS \(operatingSystemMajorVersion)."
                        ),
                    repairSuggestion: L("Run Osaurus sandbox provisioning on macOS 26 or later."),
                    locationID: nil,
                    path: nil
                )
            )
        }

        if !isAppleSilicon {
            findings.append(
                finding(
                    code: .unsupportedArchitecture,
                    severity: .blocked,
                    status: .failed,
                    title: L("Apple Silicon is required"),
                    detail: L("The sandbox image and Containerization runtime are supported on Apple Silicon."),
                    repairSuggestion: L("Run sandbox provisioning on an Apple Silicon Mac."),
                    locationID: nil,
                    path: nil
                )
            )
        }

        let configuration = loadConfigurationSnapshot(fileManager: fm)
        switch configuration.source {
        case .loaded:
            break
        case .missingUsingDefaults:
            findings.append(
                finding(
                    code: .configMissing,
                    severity: .info,
                    status: .missing,
                    title: L("Sandbox configuration file is missing"),
                    detail: L("Osaurus will use default sandbox settings until a config file is saved."),
                    repairSuggestion: L("Open Sandbox settings or run setup to write \(configuration.path)."),
                    locationID: .configFile,
                    path: configuration.path
                )
            )
        case .invalidUsingDefaults:
            findings.append(
                finding(
                    code: .configInvalid,
                    severity: .warning,
                    status: .failed,
                    title: L("Sandbox configuration could not be decoded"),
                    detail: configuration.error ?? L("The config file is invalid JSON or has an incompatible shape."),
                    repairSuggestion: L("Fix or remove \(configuration.path), then save Sandbox settings again."),
                    locationID: .configFile,
                    path: configuration.path
                )
            )
        }

        if !configuration.setupComplete {
            findings.append(
                finding(
                    code: .setupIncomplete,
                    severity: .warning,
                    status: .missing,
                    title: L("Sandbox setup has not completed"),
                    detail: L("The setupComplete flag is false, so tool and agent startup still require provisioning."),
                    repairSuggestion:
                        L("Use Set Up Sandbox from the Sandbox tab and rerun this preflight after it finishes."),
                    locationID: .configFile,
                    path: configuration.path
                )
            )
        }

        for spec in specs {
            let result = checkLocation(spec: spec, fileManager: fm)
            locations.append(result.location)
            findings.append(contentsOf: result.findings)
        }

        findings.append(
            contentsOf: volumeFindings(
                locations: locations,
                minimumColdProvisionFreeBytes: minimumColdProvisionFreeBytes
            )
        )

        let readiness = classifyReadiness(findings: findings)
        return SandboxProvisioningReport(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            overallReadiness: readiness,
            rootSource: rootSource,
            osMajorVersion: operatingSystemMajorVersion,
            isAppleSilicon: isAppleSilicon,
            minimumColdProvisionFreeBytes: minimumColdProvisionFreeBytes,
            configuration: configuration,
            locations: locations,
            findings: findings
        )
    }

    public static var defaultIsAppleSilicon: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }

    private struct LocationSpec {
        let id: SandboxProvisioningLocationID
        let title: String
        let url: URL
        let kind: SandboxProvisioningLocationKind
        let stage: SandboxProvisioningLocationStage
        let missingSeverity: SandboxProvisioningFindingSeverity
        let requiresWritable: Bool
        let includeVolumeStats: Bool
        let minimumFileBytes: Int64?
    }

    private struct LocationCheckResult {
        let location: SandboxProvisioningLocation
        let findings: [SandboxProvisioningFinding]
    }

    private static func locationSpecs() -> [LocationSpec] {
        let containerState = OsaurusPaths.container()
            .appendingPathComponent("containers/osaurus-sandbox", isDirectory: true)
        return [
            LocationSpec(
                id: .root,
                title: L("Osaurus root"),
                url: OsaurusPaths.root(),
                kind: .directory,
                stage: .hostStorage,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: true,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .configDirectory,
                title: L("Configuration directory"),
                url: OsaurusPaths.config(),
                kind: .directory,
                stage: .hostStorage,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .configFile,
                title: L("Sandbox configuration"),
                url: OsaurusPaths.sandboxConfigFile(),
                kind: .file,
                stage: .hostStorage,
                missingSeverity: .info,
                requiresWritable: true,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .cacheDirectory,
                title: L("Cache directory"),
                url: OsaurusPaths.cache(),
                kind: .directory,
                stage: .hostStorage,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: true,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .temporaryDirectory,
                title: L("Temporary directory"),
                url: FileManager.default.temporaryDirectory,
                kind: .directory,
                stage: .hostStorage,
                missingSeverity: .blocked,
                requiresWritable: true,
                includeVolumeStats: true,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .containerRoot,
                title: L("Container root"),
                url: OsaurusPaths.container(),
                kind: .directory,
                stage: .provisioningAsset,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: true,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .containerWorkspace,
                title: L("Workspace mount"),
                url: OsaurusPaths.containerWorkspace(),
                kind: .directory,
                stage: .provisioningAsset,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .containerAgents,
                title: L("Agent workspace root"),
                url: OsaurusPaths.containerAgentsDir(),
                kind: .directory,
                stage: .provisioningAsset,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .containerShared,
                title: L("Shared workspace"),
                url: OsaurusPaths.containerSharedDir(),
                kind: .directory,
                stage: .provisioningAsset,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .containerKernelDirectory,
                title: L("Kernel asset directory"),
                url: OsaurusPaths.containerKernelDir(),
                kind: .directory,
                stage: .provisioningAsset,
                missingSeverity: .warning,
                requiresWritable: true,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .containerKernelFile,
                title: L("Kernel asset"),
                url: OsaurusPaths.containerKernelFile(),
                kind: .file,
                stage: .provisioningAsset,
                missingSeverity: .warning,
                requiresWritable: false,
                includeVolumeStats: false,
                minimumFileBytes: 1
            ),
            LocationSpec(
                id: .containerInitFSFile,
                title: L("Init filesystem asset"),
                url: OsaurusPaths.containerInitFSFile(),
                kind: .file,
                stage: .provisioningAsset,
                missingSeverity: .warning,
                requiresWritable: false,
                includeVolumeStats: false,
                minimumFileBytes: 1
            ),
            LocationSpec(
                id: .containerStateDirectory,
                title: L("Container state directory"),
                url: containerState,
                kind: .directory,
                stage: .runtime,
                missingSeverity: .info,
                requiresWritable: true,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
            LocationSpec(
                id: .containerRootFSFile,
                title: L("Warm restart rootfs"),
                url: containerState.appendingPathComponent("rootfs.ext4"),
                kind: .file,
                stage: .runtime,
                missingSeverity: .warning,
                requiresWritable: false,
                includeVolumeStats: false,
                minimumFileBytes: 1
            ),
            LocationSpec(
                id: .bridgeSocket,
                title: L("Host bridge socket"),
                url: OsaurusPaths.container().appendingPathComponent("bridge.sock"),
                kind: .socket,
                stage: .runtime,
                missingSeverity: .info,
                requiresWritable: false,
                includeVolumeStats: false,
                minimumFileBytes: nil
            ),
        ]
    }

    private static func checkLocation(
        spec: LocationSpec,
        fileManager fm: FileManager
    ) -> LocationCheckResult {
        let url = spec.url.standardizedFileURL
        let path = url.path
        var isDirectory = ObjCBool(false)
        let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
        var findings: [SandboxProvisioningFinding] = []
        var readable: Bool?
        var writable: Bool?
        var fileSizeBytes: Int64?
        var status: SandboxProvisioningLocationStatus = .ready
        var detail = ""
        var repair: String?

        let volume = spec.includeVolumeStats ? volumeStats(for: url, fileManager: fm) : (nil, nil)

        guard exists else {
            let parent = nearestExistingDirectory(for: url.deletingLastPathComponent(), fileManager: fm)
            let parentWritable = parent.map { probeDirectoryWritable($0, fileManager: fm).passed } ?? false
            writable = parentWritable
            status = .missing
            detail =
                parentWritable
                ? L("Path is missing; parent directory is writable.")
                : L("Path is missing and no writable parent directory was proven.")
            repair = repairSuggestionForMissing(kind: spec.kind, path: path)
            let severity: SandboxProvisioningFindingSeverity =
                parentWritable ? spec.missingSeverity : .blocked
            let code: SandboxProvisioningFindingCode =
                parentWritable ? .locationMissing : .locationNotWritable
            findings.append(
                finding(
                    code: code,
                    severity: severity,
                    status: parentWritable ? .missing : .failed,
                    title: L("\(spec.title) is missing"),
                    detail: detail,
                    repairSuggestion: repair ?? L("Create or repair \(path)."),
                    locationID: spec.id,
                    path: path
                )
            )
            return LocationCheckResult(
                location: location(
                    spec: spec,
                    url: url,
                    status: status,
                    exists: false,
                    readable: readable,
                    writable: writable,
                    fileSizeBytes: fileSizeBytes,
                    volume: volume,
                    detail: detail,
                    repair: repair
                ),
                findings: findings
            )
        }

        switch spec.kind {
        case .directory:
            guard isDirectory.boolValue else {
                status = .wrongType
                detail = L("Expected a directory but found a file or other non-directory item.")
                repair = L("Move or remove \(path), then create the directory with mkdir -p \"\(path)\".")
                findings.append(wrongTypeFinding(spec: spec, detail: detail, repair: repair, path: path))
                break
            }
            readable = fm.isReadableFile(atPath: path)
            if spec.requiresWritable {
                let probe = probeDirectoryWritable(url, fileManager: fm)
                writable = probe.passed
                if !probe.passed {
                    status = .notWritable
                    detail = probe.detail
                    repair = permissionRepair(path: path)
                    findings.append(
                        finding(
                            code: .locationNotWritable,
                            severity: .blocked,
                            status: .failed,
                            title: L("\(spec.title) is not writable"),
                            detail: detail,
                            repairSuggestion: repair ?? permissionRepair(path: path),
                            locationID: spec.id,
                            path: path
                        )
                    )
                } else {
                    detail = L("Directory exists and accepted a write probe.")
                }
            } else {
                writable = fm.isWritableFile(atPath: path)
                detail = L("Directory exists.")
            }
        case .file:
            guard !isDirectory.boolValue else {
                status = .wrongType
                detail = L("Expected a file but found a directory.")
                repair = L("Move or remove the directory at \(path), then rerun sandbox setup.")
                findings.append(wrongTypeFinding(spec: spec, detail: detail, repair: repair, path: path))
                break
            }
            readable = fm.isReadableFile(atPath: path)
            writable = spec.requiresWritable ? fm.isWritableFile(atPath: path) : nil
            fileSizeBytes = fileSize(at: url, fileManager: fm)
            if readable == false {
                status = .notReadable
                detail = L("File exists but is not readable.")
                repair = permissionRepair(path: path)
                findings.append(
                    finding(
                        code: .locationNotReadable,
                        severity: .blocked,
                        status: .failed,
                        title: L("\(spec.title) is not readable"),
                        detail: detail,
                        repairSuggestion: repair ?? permissionRepair(path: path),
                        locationID: spec.id,
                        path: path
                    )
                )
            } else if spec.requiresWritable, writable == false {
                status = .notWritable
                detail = L("File exists but is not writable.")
                repair = permissionRepair(path: path)
                findings.append(
                    finding(
                        code: .locationNotWritable,
                        severity: .blocked,
                        status: .failed,
                        title: L("\(spec.title) is not writable"),
                        detail: detail,
                        repairSuggestion: repair ?? permissionRepair(path: path),
                        locationID: spec.id,
                        path: path
                    )
                )
            } else if let minimum = spec.minimumFileBytes, (fileSizeBytes ?? 0) < minimum {
                status = .emptyFile
                detail = L("File exists but is empty or smaller than the minimum expected size.")
                repair = L("Remove \(path) and rerun sandbox setup so Osaurus can download a fresh asset.")
                findings.append(
                    finding(
                        code: .locationEmpty,
                        severity: .blocked,
                        status: .failed,
                        title: L("\(spec.title) is empty"),
                        detail: detail,
                        repairSuggestion: repair ?? L("Remove \(path) and rerun setup."),
                        locationID: spec.id,
                        path: path
                    )
                )
            } else {
                detail = L("File exists and is readable.")
            }
        case .socket:
            if isDirectory.boolValue {
                status = .wrongType
                detail = L("Expected a runtime socket but found a directory.")
                repair = L("Stop the sandbox, remove \(path), and start the sandbox again.")
                findings.append(wrongTypeFinding(spec: spec, detail: detail, repair: repair, path: path))
            } else {
                readable = fm.isReadableFile(atPath: path)
                detail = L("Runtime socket path exists.")
            }
        }

        return LocationCheckResult(
            location: location(
                spec: spec,
                url: url,
                status: status,
                exists: true,
                readable: readable,
                writable: writable,
                fileSizeBytes: fileSizeBytes,
                volume: volume,
                detail: detail,
                repair: repair
            ),
            findings: findings
        )
    }

    private static func volumeFindings(
        locations: [SandboxProvisioningLocation],
        minimumColdProvisionFreeBytes: Int64
    ) -> [SandboxProvisioningFinding] {
        guard minimumColdProvisionFreeBytes > 0 else { return [] }
        guard let containerRoot = locations.first(where: { $0.id == .containerRoot }) else { return [] }

        if let free = containerRoot.volumeFreeBytes {
            guard free < minimumColdProvisionFreeBytes else { return [] }
            return [
                finding(
                    code: .volumeFreeSpaceLow,
                    severity: .blocked,
                    status: .failed,
                    title: L("Not enough free disk space for cold provisioning"),
                    detail:
                        L(
                            "Container root volume has \(SandboxProvisioningReport.formatBytesForDiagnostics(free)) free; cold provisioning expects at least \(SandboxProvisioningReport.formatBytesForDiagnostics(minimumColdProvisionFreeBytes))."
                        ),
                    repairSuggestion:
                        L("Free disk space on the volume that contains \(containerRoot.path), then rerun preflight."),
                    locationID: .containerRoot,
                    path: containerRoot.path
                )
            ]
        }

        return [
            finding(
                code: .volumeFreeSpaceUnproven,
                severity: .info,
                status: .unproven,
                title: L("Free disk space could not be proven"),
                detail: L("The preflight could not read volume capacity for \(containerRoot.path)."),
                repairSuggestion: L("Check available disk space manually before cold provisioning."),
                locationID: .containerRoot,
                path: containerRoot.path
            )
        ]
    }

    private static func classifyReadiness(
        findings: [SandboxProvisioningFinding]
    ) -> SandboxProvisioningReadiness {
        if findings.contains(where: { $0.severity == .blocked }) {
            return .blocked
        }
        if findings.contains(where: { $0.status == .unproven }) {
            return .unproven
        }
        if findings.contains(where: { $0.severity == .warning }) {
            return .needsSetup
        }
        return .ready
    }

    private static func loadConfigurationSnapshot(
        fileManager fm: FileManager
    ) -> SandboxProvisioningConfigurationSnapshot {
        let url = OsaurusPaths.sandboxConfigFile().standardizedFileURL
        guard fm.fileExists(atPath: url.path) else {
            return configurationSnapshot(
                path: url.path,
                source: .missingUsingDefaults,
                config: .default,
                error: nil
            )
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(SandboxConfiguration.self, from: data)
            return configurationSnapshot(path: url.path, source: .loaded, config: config, error: nil)
        } catch {
            return configurationSnapshot(
                path: url.path,
                source: .invalidUsingDefaults,
                config: .default,
                error: error.localizedDescription
            )
        }
    }

    private static func configurationSnapshot(
        path: String,
        source: SandboxProvisioningConfigurationSource,
        config: SandboxConfiguration,
        error: String?
    ) -> SandboxProvisioningConfigurationSnapshot {
        SandboxProvisioningConfigurationSnapshot(
            path: path,
            source: source,
            cpus: config.cpus,
            memoryGB: config.memoryGB,
            network: config.network,
            autoStart: config.autoStart,
            setupComplete: config.setupComplete,
            error: error
        )
    }

    private static func location(
        spec: LocationSpec,
        url: URL,
        status: SandboxProvisioningLocationStatus,
        exists: Bool,
        readable: Bool?,
        writable: Bool?,
        fileSizeBytes: Int64?,
        volume: (free: Int64?, total: Int64?),
        detail: String,
        repair: String?
    ) -> SandboxProvisioningLocation {
        SandboxProvisioningLocation(
            id: spec.id,
            title: spec.title,
            path: url.path,
            kind: spec.kind,
            stage: spec.stage,
            status: status,
            exists: exists,
            readable: readable,
            writable: writable,
            fileSizeBytes: fileSizeBytes,
            volumeFreeBytes: volume.free,
            volumeTotalBytes: volume.total,
            detail: detail,
            repairSuggestion: repair
        )
    }

    private static func finding(
        code: SandboxProvisioningFindingCode,
        severity: SandboxProvisioningFindingSeverity,
        status: SandboxProvisioningFindingStatus,
        title: String,
        detail: String,
        repairSuggestion: String,
        locationID: SandboxProvisioningLocationID?,
        path: String?
    ) -> SandboxProvisioningFinding {
        let idSuffix = locationID?.rawValue ?? L("environment")
        return SandboxProvisioningFinding(
            id: "\(code.rawValue):\(idSuffix)",
            code: code,
            severity: severity,
            status: status,
            title: title,
            detail: detail,
            repairSuggestion: repairSuggestion,
            locationID: locationID,
            path: path
        )
    }

    private static func wrongTypeFinding(
        spec: LocationSpec,
        detail: String,
        repair: String?,
        path: String
    ) -> SandboxProvisioningFinding {
        finding(
            code: .locationWrongType,
            severity: .blocked,
            status: .failed,
            title: L("\(spec.title) has the wrong type"),
            detail: detail,
            repairSuggestion: repair ?? L("Remove or move \(path), then rerun sandbox setup."),
            locationID: spec.id,
            path: path
        )
    }

    private static func resolvedRootSource(
        environment: [String: String]
    ) -> SandboxProvisioningRootSource {
        if OsaurusPaths.overrideRoot != nil {
            return .testOverride
        }
        if let envRoot = environment["OSAURUS_TEST_ROOT"],
            !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .environmentOverride
        }
        return .defaultHome
    }

    private static func repairSuggestionForMissing(
        kind: SandboxProvisioningLocationKind,
        path: String
    ) -> String {
        switch kind {
        case .directory:
            L("Create the directory with mkdir -p \"\(path)\" or run Set Up Sandbox to let Osaurus create it.")
        case .file:
            L("Run Set Up Sandbox so Osaurus can create or download \(path).")
        case .socket:
            L("Start the sandbox; this runtime socket is created only while the host bridge is running.")
        }
    }

    private static func permissionRepair(path: String) -> String {
        L(
            "Fix ownership or permissions for \(path), then rerun preflight. For user-owned paths, chmod u+rwX \"\(path)\" is usually enough."
        )
    }

    private static func nearestExistingDirectory(
        for url: URL,
        fileManager fm: FileManager
    ) -> URL? {
        var current = url.standardizedFileURL
        while true {
            var isDirectory = ObjCBool(false)
            if fm.fileExists(atPath: current.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    private struct WriteProbe {
        let passed: Bool
        let detail: String
    }

    private static func probeDirectoryWritable(
        _ url: URL,
        fileManager fm: FileManager
    ) -> WriteProbe {
        let probe = url.appendingPathComponent(".osaurus-sandbox-preflight-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try? fm.removeItem(at: probe)
            return WriteProbe(passed: true, detail: L("Directory exists and accepted a write probe."))
        } catch {
            try? fm.removeItem(at: probe)
            return WriteProbe(
                passed: false,
                detail: L("Write probe failed: \(error.localizedDescription)")
            )
        }
    }

    private static func fileSize(at url: URL, fileManager fm: FileManager) -> Int64? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber
        else {
            return nil
        }
        return size.int64Value
    }

    private static func volumeStats(
        for url: URL,
        fileManager fm: FileManager
    ) -> (free: Int64?, total: Int64?) {
        let probeURL: URL
        if fm.fileExists(atPath: url.path) {
            probeURL = url
        } else {
            probeURL = nearestExistingDirectory(for: url, fileManager: fm) ?? url
        }
        return (
            OsaurusPaths.volumeFreeBytes(forPath: probeURL.path),
            OsaurusPaths.volumeTotalBytes(forPath: probeURL.path)
        )
    }
}

private extension SandboxProvisioningReport {
    static func formatBytesForDiagnostics(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(bytes) \(units[index])"
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
