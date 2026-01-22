//
//  SelectCapabilitiesTool.swift
//  osaurus
//
//  Tool for model to select which capabilities (tools + skills) to use for a conversation.
//  Called once at conversation start during two-phase capability loading.
//

import Foundation

/// Result of capability selection
public struct CapabilitySelectionResult: Codable, Sendable {
    public let selectedTools: [String]
    public let selectedSkills: [String]
    public let loadedToolSchemas: [String: JSONValue]
    public let loadedSkillInstructions: [String: String]
    public let errors: [String]

    public init(
        selectedTools: [String],
        selectedSkills: [String],
        loadedToolSchemas: [String: JSONValue],
        loadedSkillInstructions: [String: String],
        errors: [String] = []
    ) {
        self.selectedTools = selectedTools
        self.selectedSkills = selectedSkills
        self.loadedToolSchemas = loadedToolSchemas
        self.loadedSkillInstructions = loadedSkillInstructions
        self.errors = errors
    }
}

/// Tool for selecting capabilities at conversation start
final class SelectCapabilitiesTool: OsaurusTool, @unchecked Sendable {
    let name = "select_capabilities"
    let description =
        "Select which tools and skills to use for this conversation. Call this before starting your response."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "tools": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Names of tools to enable for this conversation"),
            ]),
            "skills": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Names of skills to activate for guidance"),
            ]),
        ]),
        "required": .array([.string("tools"), .string("skills")]),
    ])

    /// Callback to notify when capabilities are selected
    var onCapabilitiesSelected: ((CapabilitySelectionResult) -> Void)?

    init(onCapabilitiesSelected: ((CapabilitySelectionResult) -> Void)? = nil) {
        self.onCapabilitiesSelected = onCapabilitiesSelected
    }

    func execute(argumentsJSON: String) async throws -> String {
        // Parse arguments
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SelectCapabilitiesError.invalidArguments
        }

        let requestedTools = (json["tools"] as? [String]) ?? []
        let requestedSkills = (json["skills"] as? [String]) ?? []

        var loadedToolSchemas: [String: JSONValue] = [:]
        var loadedSkillInstructions: [String: String] = [:]
        var errors: [String] = []
        var selectedTools: [String] = []
        var selectedSkills: [String] = []

        // Load tool schemas
        await MainActor.run {
            let registry = ToolRegistry.shared
            for toolName in requestedTools {
                if let params = registry.parametersForTool(name: toolName) {
                    loadedToolSchemas[toolName] = params
                    selectedTools.append(toolName)
                } else {
                    errors.append("Tool '\(toolName)' not found or not enabled")
                }
            }
        }

        // Load skill instructions
        await MainActor.run {
            let manager = SkillManager.shared
            for skillName in requestedSkills {
                if let skill = manager.skill(named: skillName), skill.enabled {
                    loadedSkillInstructions[skillName] = skill.instructions
                    selectedSkills.append(skillName)
                } else {
                    errors.append("Skill '\(skillName)' not found or not enabled")
                }
            }
        }

        let result = CapabilitySelectionResult(
            selectedTools: selectedTools,
            selectedSkills: selectedSkills,
            loadedToolSchemas: loadedToolSchemas,
            loadedSkillInstructions: loadedSkillInstructions,
            errors: errors
        )

        // Notify callback
        onCapabilitiesSelected?(result)

        // Build response
        return buildResponse(result)
    }

    private func buildResponse(_ result: CapabilitySelectionResult) -> String {
        var response: [String] = []

        response.append("# Capabilities Loaded")
        response.append("")

        if !result.selectedTools.isEmpty {
            response.append("## Selected Tools")
            response.append("The following tools are now available for this conversation:")
            for tool in result.selectedTools {
                response.append("- \(tool)")
            }
            response.append("")
        }

        if !result.loadedSkillInstructions.isEmpty {
            response.append("## Activated Skills")
            response.append("The following skill instructions are now active:")
            response.append("")

            for (skillName, instructions) in result.loadedSkillInstructions {
                response.append("### \(skillName)")
                response.append("")
                response.append(instructions)
                response.append("")
            }
        }

        if !result.errors.isEmpty {
            response.append("## Warnings")
            for error in result.errors {
                response.append("- \(error)")
            }
            response.append("")
        }

        if result.selectedTools.isEmpty && result.loadedSkillInstructions.isEmpty {
            response.append("No capabilities were loaded. You can proceed without tools or skills.")
        } else {
            response.append("You can now proceed with your response using the loaded capabilities.")
        }

        return response.joined(separator: "\n")
    }
}

// MARK: - Errors

enum SelectCapabilitiesError: Error, LocalizedError {
    case invalidArguments
    case noCapabilitiesAvailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Invalid arguments for select_capabilities"
        case .noCapabilitiesAvailable:
            return "No capabilities available to select"
        }
    }
}

// MARK: - Capability Selection State

/// Tracks the state of capability selection for a conversation
@MainActor
public class CapabilitySelectionState: ObservableObject {
    /// Whether capabilities have been selected for this conversation
    @Published public var hasSelected: Bool = false

    /// The result of the last selection
    @Published public var lastResult: CapabilitySelectionResult?

    /// Names of currently selected tools
    public var selectedToolNames: [String] {
        lastResult?.selectedTools ?? []
    }

    /// Names of currently selected skills
    public var selectedSkillNames: [String] {
        lastResult?.selectedSkills ?? []
    }

    /// Combined instructions from all selected skills
    public var combinedSkillInstructions: String {
        guard let result = lastResult else { return "" }
        return result.loadedSkillInstructions.values.joined(separator: "\n\n---\n\n")
    }

    /// Reset selection state for a new conversation
    public func reset() {
        hasSelected = false
        lastResult = nil
    }

    /// Update state with selection result
    public func update(with result: CapabilitySelectionResult) {
        hasSelected = true
        lastResult = result
    }
}
