import Foundation

public enum PortabilityClass: String, Codable, CaseIterable {
    case portable
    case adapter_needed
    case rewrite
}

public enum BridgeCapability: String, Codable, CaseIterable {
    case clipboard
    case externalLink = "external_link"
    case filePicker = "file_picker"

    public var serviceInterface: String {
        switch self {
        case .clipboard:
            return "ClipboardService"
        case .externalLink:
            return "ExternalLinkService"
        case .filePicker:
            return "FilePickerService"
        }
    }

    public var projectionNamespace: String {
        switch self {
        case .clipboard:
            return "Windows.ApplicationModel.DataTransfer"
        case .externalLink:
            return "Windows.System"
        case .filePicker:
            return "Windows.Storage.Pickers"
        }
    }
}

public enum SliceDefinition: String, Codable, CaseIterable {
    case management_settings

    public var displayName: String {
        switch self {
        case .management_settings:
            return "Management/Settings"
        }
    }

    public var slug: String { rawValue.replacingOccurrences(of: "_", with: "-") }

    public var sourcePaths: [String] {
        switch self {
        case .management_settings:
            return [
                "Packages/OsaurusCore/Views/Management/ManagementView.swift",
                "Packages/OsaurusCore/Models/Configuration/ManagementTab.swift",
                "Packages/OsaurusCore/Views/Settings/ServerView.swift",
                "Packages/OsaurusCore/Views/Management/SidebarNavigation.swift",
                "Packages/OsaurusCore/Views/Management/ManagerHeader.swift",
                "Packages/OsaurusCore/Views/Management/SharedSidebarComponents.swift",
                "Packages/OsaurusCore/Views/Common/AnimatedTabSelector.swift",
            ]
        }
    }

    public var serviceInterfaces: [String] {
        [
            "ClipboardService",
            "ExternalLinkService",
            "ServerControlService",
            "SettingsNavigationService",
            "FilePickerService",
        ]
    }

    public var primaryUIFramework: String { "SwiftCrossUI" }

    public var windowsBridgePackagePath: String { "Packages/HeliosWindowsBridge" }

    public var fixedNextSlices: [String] {
        ["chat_surface", "app_shell", "platform_services"]
    }
}

public struct PortabilityFinding: Codable, Equatable {
    public let sourcePath: String
    public let symbols: [String]
    public let classification: PortabilityClass
    public let reasons: [String]
    public let platformDependencies: [String]
    public let bridgeCapabilities: [BridgeCapability]

    enum CodingKeys: String, CodingKey {
        case bridgeCapabilities
        case sourcePath
        case symbols
        case classification = "class"
        case reasons
        case platformDependencies
    }
}

public struct PortabilitySummary: Codable, Equatable {
    public let totalFiles: Int
    public let portableCount: Int
    public let adapterNeededCount: Int
    public let rewriteCount: Int
}

public struct PortabilityReport: Codable, Equatable {
    public let slice: SliceDefinition
    public let findings: [PortabilityFinding]
    public let summary: PortabilitySummary
}

public struct ArchitectureDecision: Equatable {
    public let slice: SliceDefinition
    public let primaryUIFramework: String
    public let windowsBridgePackage: String
    public let bridgeCapabilities: [BridgeCapability]
    public let projectionNamespaces: [String]
    public let rationale: [String]
    public let serverRewriteZones: [String]
    public let guardrails: [String]
}

public struct HeliosSliceManifest: Codable, Equatable {
    public let slice: SliceDefinition
    public let tabs: [String]
    public let serviceInterfaces: [String]
    public let bridgeCapabilities: [BridgeCapability]
    public let primaryUIFramework: String
    public let windowsBridgePackage: String
    public let sourcePaths: [String]
    public let todoMarkers: [String]
}

public struct CommandOutput: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum HeliosPorterError: LocalizedError, Equatable {
    case invalidCommand(String)
    case missingOption(String)
    case invalidSlice(String)
    case sourceFileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCommand(let command):
            return "Unknown command '\(command)'."
        case .missingOption(let option):
            return "Missing required option \(option)."
        case .invalidSlice(let value):
            return "Unsupported slice '\(value)'."
        case .sourceFileMissing(let relativePath):
            return "Missing source file '\(relativePath)' in the repository root."
        }
    }
}
