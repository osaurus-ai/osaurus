//
//  ImageGenerationPanelView.swift
//  osaurus
//
//  Manual image generation / edit panel. A direct surface (separate from the
//  chat-triggered `image_generate` / `image_edit` delegation tools) that drives
//  `ImageGenerationService` for an on-device bundle: prompt + a few params →
//  live progress → the saved image, with a Save-As / Reveal action.
//
//  Manual panels keep their own loading behavior (they do NOT run the chat
//  residency handoff): the service acquires its exclusive image lane and loads
//  the requested bundle directly. The chat-triggered spawn path is the one that
//  unloads/reloads the orchestrator under RAM-safety preflight.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drives one `ImageGenerationService` stream and publishes progress for the
/// panel. `@MainActor` so all `@Published` mutations land on the UI thread.
@MainActor
final class ImageGenerationPanelModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loadingModel(String)
        case running(step: Int, total: Int, eta: Double?)
        case done
        case failed(String)
        case cancelled
    }

    @Published var phase: Phase = .idle
    @Published var resultURL: URL?
    @Published var resultSeed: UInt64?

    private var job: Task<Void, Never>?
    private let jobID = UUID().uuidString

    var isBusy: Bool {
        switch phase {
        case .loadingModel, .running: return true
        default: return false
        }
    }

    func generate(_ params: ImageGenerationParameters) {
        start { await ImageGenerationService.shared.generate(params, jobID: self.jobID) }
    }

    func edit(_ params: ImageEditParameters) {
        start { await ImageGenerationService.shared.edit(params, jobID: self.jobID) }
    }

    func cancel() {
        Task { await ImageGenerationService.shared.cancel(jobID: jobID) }
    }

    private func start(
        _ makeStream: @escaping () async -> AsyncThrowingStream<ImageGenerationEvent, Error>
    ) {
        job?.cancel()
        resultURL = nil
        resultSeed = nil
        phase = .loadingModel("")
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await makeStream()
                for try await event in stream {
                    await self.apply(event)
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch {
                await MainActor.run { self.phase = .failed(String(describing: error)) }
            }
        }
    }

    private func apply(_ event: ImageGenerationEvent) {
        switch event {
        case .loadingModel(let model):
            phase = .loadingModel(model)
        case .step(let step, let total, let eta):
            phase = .running(step: step, total: total, eta: eta)
        case .preview:
            break
        case .completed(let images):
            if let first = images.first {
                resultURL = first.url
                resultSeed = first.seed
            }
            phase = .done
        case .failed(let message, _):
            phase = .failed(message)
        case .cancelled:
            phase = .cancelled
        }
    }
}

struct ImageGenerationPanelView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ImageGenerationPanelModel()

    /// Bundle id to drive (e.g. "FLUX.1-schnell"). Locked for this panel.
    let modelId: String
    let displayName: String
    /// `true` ⇒ image-edit bundle (needs a source image); `false` ⇒ text→image.
    let isEdit: Bool

    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var sizeIndex: Int = 1  // 0:512, 1:1024
    @State private var seedText: String = ""
    @State private var sourceURL: URL?

    private let sizes: [Int] = [512, 1024]

    private var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isEdit || sourceURL != nil)
            && !model.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isEdit { sourcePicker }
                    promptField
                    paramsRow
                    statusCard
                    if let url = model.resultURL { resultCard(url) }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            footer
        }
        .frame(width: 620, height: 640)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isEdit ? "wand.and.stars" : "photo.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accentColor)
            Text(isEdit ? "Edit Image" : "Generate Image", bundle: .module)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(theme.primaryText)
            Text(displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(Rectangle().fill(theme.cardBorder).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Inputs

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Source image")
            HStack(spacing: 12) {
                if let sourceURL, let nsImage = NSImage(contentsOf: sourceURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))
                }
                Button(action: pickSource) {
                    Text(sourceURL == nil ? "Choose…" : "Replace…", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(SettingsButtonStyle())
                if let sourceURL {
                    Text(sourceURL.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Prompt")
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .frame(height: 70)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
                )
            fieldLabel("Negative prompt (optional)")
            TextField("", text: $negativePrompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
                )
        }
    }

    private var paramsRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Size")
                Picker("", selection: $sizeIndex) {
                    ForEach(sizes.indices, id: \.self) { i in
                        Text("\(sizes[i])²").tag(i)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Seed (optional)")
                TextField("random", text: $seedText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)))
            }
            Spacer()
        }
    }

    // MARK: - Status + result

    private var statusCard: some View {
        Group {
            switch model.phase {
            case .idle:
                EmptyView()
            case .loadingModel(let m):
                statusRow(spinner: true, text: m.isEmpty ? L("Loading model…") : "Loading \(m)…")
            case .running(let step, let total, let eta):
                VStack(alignment: .leading, spacing: 6) {
                    statusRow(
                        spinner: true,
                        text: "Step \(step)/\(total)" + (eta.map { String(format: " · ~%.0fs", $0) } ?? ""))
                    ProgressView(value: Double(step), total: Double(max(total, 1)))
                        .tint(theme.accentColor)
                }
            case .done:
                statusRow(spinner: false, text: L("Done"), color: theme.successColor)
            case .failed(let message):
                statusRow(spinner: false, text: message, color: theme.errorColor)
            case .cancelled:
                statusRow(spinner: false, text: L("Cancelled"), color: theme.warningColor)
            }
        }
    }

    private func resultCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
            }
            HStack(spacing: 12) {
                if let seed = model.resultSeed {
                    Text("seed \(String(seed))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                    Label(L("Reveal"), systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PlainButtonStyle())
                Button(action: { saveAs(url) }) {
                    Label(L("Save As…"), systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Text("Close", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
            Spacer()
            if model.isBusy {
                Button(action: { model.cancel() }) {
                    Text("Cancel", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.errorColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Button(action: run) {
                HStack(spacing: 6) {
                    Image(systemName: isEdit ? "wand.and.stars" : "sparkles")
                        .font(.system(size: 13))
                    Text(isEdit ? "Edit" : "Generate", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canRun ? theme.accentColor : theme.accentColor.opacity(0.4)))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canRun)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(Rectangle().fill(theme.cardBorder).frame(height: 1), alignment: .top)
    }

    // MARK: - Actions

    private func run() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let size = sizes[sizeIndex]
        let seed = UInt64(seedText.trimmingCharacters(in: .whitespaces))
        let negative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if isEdit {
            guard let sourceURL, let data = try? Data(contentsOf: sourceURL) else { return }
            model.edit(
                ImageEditParameters(
                    model: modelId,
                    prompt: trimmedPrompt,
                    sourceImages: [data],
                    negativePrompt: negative.isEmpty ? nil : negative,
                    seed: seed))
        } else {
            model.generate(
                ImageGenerationParameters(
                    model: modelId,
                    prompt: trimmedPrompt,
                    negativePrompt: negative.isEmpty ? nil : negative,
                    width: size,
                    height: size,
                    seed: seed))
        }
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { sourceURL = panel.url }
    }

    private func saveAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    // MARK: - Subviews

    private func fieldLabel(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.secondaryText)
    }

    private func statusRow(spinner: Bool, text: String, color: Color? = nil) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(color ?? theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1)))
    }
}
