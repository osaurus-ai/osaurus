//
//  ChatHarnessPickerOption.swift
//  osaurus
//
//  A chat-picker row that moves the agent onto a harness runtime. Kept apart
//  from `ModelPickerItem`: a harness is not a model the server can route to,
//  so it must never reach `/v1/models`, the settings model pickers, or a
//  session's `selectedModel`.
//

import Foundation

struct ChatHarnessPickerOption: Identifiable, Equatable, Hashable, Sendable {
    let runtimeId: UUID
    /// Claude Code `--model` value; nil for runtimes that pick their own model.
    let claudeModel: String?
    let title: String

    var id: String {
        Self.id(runtimeId: runtimeId, claudeModel: claudeModel)
    }

    static func id(runtimeId: UUID, claudeModel: String?) -> String {
        "harness:\(runtimeId.uuidString)" + (claudeModel.map { ":\($0)" } ?? "")
    }

    /// The row id for an agent's current runtime, or nil on the built-in loop
    /// (or a deleted runtime, which has no row to mark).
    static func selectedID(runtime: HarnessRuntime?, claudeConfig: ClaudeCodeAgentConfig) -> String? {
        guard let runtime else { return nil }
        switch runtime.kind {
        case .claudeCode:
            return id(runtimeId: runtime.id, claudeModel: claudeConfig.resolvedModel)
        case .piRPC:
            return id(runtimeId: runtime.id, claudeModel: nil)
        }
    }

    /// Rows for one runtime. Claude Code lists its model aliases, plus the
    /// agent's own full model id when that is what it runs, so the current
    /// choice always shows as selected.
    static func options(for runtime: HarnessRuntime, currentClaudeModel: String? = nil) -> [ChatHarnessPickerOption] {
        switch runtime.kind {
        case .claudeCode:
            var options = ClaudeCodeModel.allCases.map {
                ChatHarnessPickerOption(runtimeId: runtime.id, claudeModel: $0.rawValue, title: $0.rawValue.capitalized)
            }
            if let currentClaudeModel, !options.contains(where: { $0.claudeModel == currentClaudeModel }) {
                options.append(
                    ChatHarnessPickerOption(runtimeId: runtime.id, claudeModel: currentClaudeModel, title: currentClaudeModel)
                )
            }
            return options
        case .piRPC:
            return [ChatHarnessPickerOption(runtimeId: runtime.id, claudeModel: nil, title: L("Default model"))]
        }
    }
}
