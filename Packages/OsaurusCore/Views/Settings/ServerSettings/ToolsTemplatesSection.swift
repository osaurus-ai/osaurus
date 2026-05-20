//
//  ToolsTemplatesSection.swift
//  osaurus
//
//  Tool / template parser overrides for the Server → Settings tab.
//  Persisted today; Osaurus auto-selects parsers from the loaded model
//  so these are display-and-persist only until a host bridge lands.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct ToolsTemplatesSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    var body: some View {
        ServerSettingsCard(
            section: .tools,
            status: .needsBridge,
            blurb:
                "Override the auto-selected tool-call and reasoning parsers. Persisted today; Osaurus reads from the loaded model until the host bridge ships."
        ) {
            SettingsToggle(
                title: L("Allow Implicit Tool Calls"),
                description:
                    "Let the model invoke tools without an explicit `tool_choice` from the client.",
                isOn: $draft.tools.enableAutoToolChoice
            )

            OptionalStringField(
                label: "Tool Parser Override",
                placeholder: "Blank = auto-pick from the model",
                help: "Known names include: hermes, openai_function.",
                value: $draft.tools.toolParserOverride
            )

            OptionalStringField(
                label: "Reasoning Parser Override",
                placeholder: "Blank = auto-pick from the model",
                help: "Known names include: deepseek_r1, qwen3.",
                value: $draft.tools.reasoningParserOverride
            )

            OptionalStringField(
                label: "MCP Config File",
                placeholder: "Blank = use providers/mcp.json",
                help: "Path to an alternative MCP configuration file.",
                value: $draft.tools.mcpConfigFile
            )

            SettingsField(
                label: "Custom Chat Template",
                hint:
                    "Override the model's chat template. Leave blank to use the one shipped with the model."
            ) {
                TextEditor(text: customTemplateBinding)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 100, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
            }
        }
    }

    /// Bridge the multi-line `TextEditor`'s `Binding<String>` to the
    /// model's `Binding<String?>`, collapsing blank input to `nil`.
    private var customTemplateBinding: Binding<String> {
        Binding(
            get: { draft.tools.customChatTemplate ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.tools.customChatTemplate = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}
