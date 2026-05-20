//
//  ToolsTemplatesSection.swift
//  osaurus
//
//  Tool/template parser overrides for the Server → Settings tab.
//  Persisted today; Osaurus auto-selects parsers from the loaded model
//  so these are display-and-persist only until a host bridge lands.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct ToolsTemplatesSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(title: "Tools & Templates", icon: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .needsBridge,
                    blurb:
                        "vmlx validates these strings; Osaurus auto-selects parsers from the loaded model today."
                )

                SettingsToggle(
                    title: L("Enable Auto Tool Choice"),
                    description: "Allow the model to invoke tools without explicit `tool_choice`.",
                    isOn: $draft.tools.enableAutoToolChoice
                )

                OptionalStringField(
                    label: "Tool Parser Override",
                    placeholder: "Empty = auto (model-stamped)",
                    help: "Name of a known tool-call parser (e.g. hermes, openai_function).",
                    value: $draft.tools.toolParserOverride
                )

                OptionalStringField(
                    label: "Reasoning Parser Override",
                    placeholder: "Empty = auto (model-stamped)",
                    help: "Name of a known reasoning parser (e.g. deepseek_r1, qwen3).",
                    value: $draft.tools.reasoningParserOverride
                )

                OptionalStringField(
                    label: "MCP Config File",
                    placeholder: "Empty = use the providers/mcp.json store",
                    help: "Path to an alternative MCP config file.",
                    value: $draft.tools.mcpConfigFile
                )

                SettingsField(
                    label: "Custom Chat Template",
                    hint: "Overrides the model's chat template. Leave blank to use the stamped one."
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
