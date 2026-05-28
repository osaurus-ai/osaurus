//
//  ToolsTemplatesSection.swift
//  osaurus
//
//  Tool / template controls for the Server → Settings tab. Parser overrides
//  are engine-wired through vmlx; host/tool-provider controls are persisted
//  but remain planned until their Osaurus bridges land.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct ToolsTemplatesSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    var body: some View {
        ServerSettingsCard(
            section: .tools,
            status: .partial,
            blurb:
                "Parser overrides are applied at model load. Tool-provider and template controls are persisted here until their host bridges land."
        ) {
            SettingsToggle(
                title: L("Allow Implicit Tool Calls"),
                description:
                    "Let the model invoke tools without an explicit `tool_choice` from the client.",
                isOn: $draft.tools.enableAutoToolChoice
            )
            ServerSettingsPlannedBanner(
                blurb:
                    "Implicit tool-choice policy is persisted only; OpenAI-compatible requests still use the request's explicit tool choice and Osaurus chat-agent policy."
            )

            OptionalStringField(
                label: "Tool Parser Override",
                placeholder: "Blank = auto-pick from the model",
                help: "Applied by vmlx at local model load. Known names include: qwen3_6, dsml, minimax_m2.",
                value: $draft.tools.toolParserOverride
            )

            OptionalStringField(
                label: "Reasoning Parser Override",
                placeholder: "Blank = auto-pick from the model",
                help: "Applied by vmlx at local model load. Use off to disable reasoning parsing.",
                value: $draft.tools.reasoningParserOverride
            )

            OptionalStringField(
                label: "MCP Config File",
                placeholder: "Blank = use providers/mcp.json",
                help: "Path to an alternative MCP configuration file.",
                value: $draft.tools.mcpConfigFile
            )
            ServerSettingsPlannedBanner(
                blurb:
                    "MCP config-file override is persisted only; the current tool registry still owns provider loading."
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
            ServerSettingsPlannedBanner(
                blurb:
                    "Custom chat templates are persisted only; vmlx still renders with the loaded tokenizer's template."
            )
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
