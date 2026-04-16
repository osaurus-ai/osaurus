//
//  HarnessReliabilityFlags.swift
//  osaurus
//
//  Internal rollout switches for staged harness improvements.
//

import Foundation

enum HarnessReliabilityFlag: String {
    case toolPromptFoundation = "HarnessReliability.ToolPromptFoundationEnabled"

    var environmentVariable: String {
        switch self {
        case .toolPromptFoundation:
            return "OSAURUS_HARNESS_TOOL_PROMPT_FOUNDATION"
        }
    }
}

@MainActor
enum HarnessReliabilityFlags {
    private static var overrides: [HarnessReliabilityFlag: Bool] = [:]

    static func isEnabled(_ flag: HarnessReliabilityFlag) -> Bool {
        if let override = overrides[flag] {
            return override
        }
        if let envValue = ProcessInfo.processInfo.environment[flag.environmentVariable] {
            return parseBool(envValue) ?? false
        }
        return UserDefaults.standard.object(forKey: flag.rawValue) as? Bool ?? false
    }

    static func withOverride<T>(
        _ enabled: Bool,
        for flag: HarnessReliabilityFlag,
        perform: () throws -> T
    ) rethrows -> T {
        let previous = overrides[flag]
        overrides[flag] = enabled
        defer {
            if let previous {
                overrides[flag] = previous
            } else {
                overrides.removeValue(forKey: flag)
            }
        }
        return try perform()
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
