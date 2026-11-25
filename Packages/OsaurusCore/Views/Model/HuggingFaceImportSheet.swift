//
//  HuggingFaceImportSheet.swift
//  osaurus
//
//  Add Model on Local Models: paste a Hugging Face URL or repo id.
//

import SwiftUI

// MARK: - Hugging Face Import Sheet

/// Modal that lets users paste a Hugging Face URL or repo id and surface
/// a friendly error when the repo isn't MLX-compatible. On success, the
/// caller routes the resolved repo id back into the search field, which
/// triggers the existing `fetchRemoteMLXModels` resolution path
struct HuggingFaceImportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let onImported: (String) -> Void
    /// Called when the pasted repo is an image bundle, staged via the image
    /// store instead of the LLM path.
    let onImportedImage: (String) -> Void

    @State private var inputText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isResolving = false

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !isResolving && ModelManager.parseHuggingFaceRepoId(from: trimmedInput) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: theme.space.s16) {
                explainer
                inputField
                if let errorMessage {
                    errorBanner(errorMessage)
                }
            }
            .padding(theme.space.s16)

            Divider()
            footer
        }
        .frame(width: SettingsSheetWidth.compact)
        .background(theme.surface.canvas)
    }

    private var header: some View {
        HStack(spacing: theme.space.s10) {
            Text("🤗")
                .font(SettingsFont.cardTitle)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Import from Hugging Face", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                Text("Paste a link to a model on Hugging Face", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            }
            Spacer()
            SettingsIconButton("xmark", help: "Close", size: .compact, action: { dismiss() })
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s16)
    }

    private var explainer: some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: "info.circle")
                .glyphSize(.caption, weight: .medium)
                .foregroundColor(theme.text.link)
                .padding(.top, theme.space.s2)
            Text(
                "Paste a Hugging Face link to a chat or image model. Osaurus puts it in the right tab.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.selected)
    }

    private var inputField: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text("Hugging Face link", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)

            SettingsTextField(
                placeholder: "OsaurusAI/gemma-4-E2B-it-8bit",
                text: $inputText,
                monospaced: true,
                onSubmit: submit
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.caption)
                .foregroundColor(theme.status.warning.foreground)
                .padding(.top, theme.space.s2)
            Text(message)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.warning))
    }

    private var footer: some View {
        HStack {
            Spacer()
            SettingsButton(.primary, "Import", isLoading: isResolving, action: submit)
                .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
    }

    private func submit() {
        guard let repoId = ModelManager.parseHuggingFaceRepoId(from: trimmedInput) else {
            errorMessage = L(
                "That doesn't look like a Hugging Face model. Paste a huggingface.co link, or a name such as OsaurusAI/gemma-4-E2B-it-8bit."
            )
            return
        }
        if RetiredModelBundles.isRetired(id: repoId) {
            errorMessage = RetiredModelBundles.badgeHelp
            return
        }
        errorMessage = nil
        isResolving = true
        Task { @MainActor in
            // Image bundles use a diffusers/mflux layout and a separate engine,
            // so route them to the image store before the LLM compatibility
            // check (which would reject them and stage to the wrong directory).
            if await ImageModelDownloadService.isImageRepo(repoId) {
                ImageModelDownloadService.shared.download(
                    repoId: repoId,
                    displayName: ImageModelDownload.directoryName(forRepoId: repoId)
                )
                isResolving = false
                onImportedImage(repoId)
                return
            }

            let resolved = await ModelManager.shared.resolveModelIfMLXCompatible(byRepoId: repoId)
            isResolving = false
            if resolved != nil {
                onImported(repoId)
            } else if repoId.lowercased().hasPrefix("osaurusai/") {
                errorMessage = L(
                    "Osaurus doesn't offer that OsaurusAI model. Pick one from the Chat or Image tab instead."
                )
            } else {
                errorMessage = L(
                    "Osaurus can't run this model. It may be in a format Osaurus doesn't support, or it may be private: add a Hugging Face token that can access it and try again."
                )
            }
        }
    }
}
