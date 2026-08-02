//
//  CompactionDialogView.swift
//  osaurus
//
//  First-run / progress dialog for LLM context compaction.
//
//  Shown as a sheet when compaction is triggered without a configured model
//  (Settings → Chat → Compaction Model), and while an auto-triggered
//  pre-send compaction runs. Explains what compaction does, lets the user
//  pick a model (remote allowed — remote calls pass through the Privacy
//  Filter), and renders live progress from the service's phase states.
//

import SwiftUI

struct CompactionDialogView: View {
    @ObservedObject var session: ChatSession

    @Environment(\.theme) private var theme

    /// Model chosen in this dialog (pre-populated from settings when one is
    /// already configured — e.g. the dialog opened only to show progress).
    @State private var selectedModelId: String?
    @State private var showModelPicker = false

    init(session: ChatSession) {
        self.session = session
        _selectedModelId = State(
            initialValue: ContextCompactionService.configuredModelIdentifier())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 440)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Compact Conversation", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Free up context without losing your chat", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch session.compactionState {
        case .needsModelSelection:
            modelSelectionContent
        case .running(let phase):
            progressContent(phase: phase)
        case .completed(let savedTokens):
            completedContent(savedTokens: savedTokens)
        case .failed(let message):
            failedContent(message: message)
        case .idle:
            // Transient (e.g. the sheet is animating out after a cancel).
            modelSelectionContent
        }
    }

    private var modelSelectionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "This conversation is close to the model's context limit. Osaurus can summarize the older messages with a model of your choice, so the chat can continue with full awareness of what happened — your visible transcript is never changed.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Compaction model", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                modelPickerButton
                Text(
                    "Remote models pass through your Privacy Filter. You can change this anytime in Settings → Chat.",
                    bundle: .module
                )
                .font(.system(size: 10.5))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelPickerButton: some View {
        let currentItem = session.pickerItems.first { $0.id == selectedModelId }
        return Button {
            showModelPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(
                        selectedModelId == nil ? theme.tertiaryText : theme.accentColor)
                if let currentItem {
                    Text(currentItem.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                } else if let selectedModelId {
                    Text(verbatim: selectedModelId)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("Choose a model…", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            ModelPickerView(
                options: session.pickerItems,
                selectedModel: $selectedModelId,
                agentId: nil,
                onDismiss: { showModelPicker = false }
            )
        }
    }

    private func progressContent(phase: ContextCompactionPhase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text(verbatim: phase.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            ProgressView(value: phase.progressFraction)
                .progressViewStyle(.linear)
                .tint(theme.accentColor)
                .animation(.easeOut(duration: 0.35), value: phase.progressFraction)
            Text(
                "Older messages are being summarized. Your visible chat stays exactly as it is.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func completedContent(savedTokens: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(theme.successColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation compacted", bundle: .module)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "About \(savedTokens.formatted()) tokens were reclaimed. A marker in the chat shows where the summary begins.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func failedContent(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.warningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compaction didn't finish", bundle: .module)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            switch session.compactionState {
            case .needsModelSelection, .idle:
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    Text("Not Now", bundle: .module)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .keyboardShortcut(.cancelAction)

                Button {
                    if let id = selectedModelId {
                        session.chooseCompactionModelAndRun(id)
                    }
                } label: {
                    Text("Continue", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                selectedModelId == nil
                                    ? theme.accentColor.opacity(0.35) : theme.accentColor)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(selectedModelId == nil)
                .keyboardShortcut(.defaultAction)

            case .running:
                // The run keeps going if dismissed; its state stays visible
                // in the Context Budget popover.
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    Text("Hide", bundle: .module)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .keyboardShortcut(.cancelAction)

            case .completed:
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    Text("Done", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accentColor))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

            case .failed:
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    Text("Close", bundle: .module)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .keyboardShortcut(.cancelAction)

                Button {
                    session.retryCompaction()
                } label: {
                    Text("Retry", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accentColor))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }
}
