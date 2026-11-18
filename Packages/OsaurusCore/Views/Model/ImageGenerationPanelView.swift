//
//  ImageGenerationPanelView.swift
//  osaurus
//
//  Manual image generation / edit panel. A direct surface (separate from the
//  chat-triggered `image` delegation tool) that drives
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
    @Published var previewImage: NSImage?
    @Published var resultURL: URL?
    @Published var resultSeed: UInt64?
    @Published var resultParameters: ImageEffectiveParameters?
    @Published private(set) var results: [GeneratedImage] = []
    /// `true` between a user Cancel press and the terminal event that resolves
    /// the job. The actual weight load inside vMLXFlux is not interruptible, so
    /// this drives immediate UI feedback while the soft cancel settles.
    @Published var isCancelling = false
    /// Live elapsed wall-clock for the current job (Generate press → finish),
    /// updated ~10x/sec while busy so the panel can show a running timer.
    @Published var elapsed: TimeInterval = 0
    /// Final elapsed of the most recent finished job (any outcome), for the
    /// "Done in Xs" readout.
    @Published private(set) var lastDuration: TimeInterval?
    /// Estimate carried over from the last *successful* run with the same
    /// model + size + mode, shown before/while the next run finishes.
    @Published private(set) var estimate: TimeInterval?

    private var job: Task<Void, Never>?
    private let jobID = UUID().uuidString
    private var startDate: Date?
    private var timerTask: Task<Void, Never>?
    private var durationKey: String?

    var isBusy: Bool {
        switch phase {
        case .loadingModel, .running: return true
        default: return false
        }
    }

    func generate(_ params: ImageGenerationParameters) {
        durationKey = ImageGenerationDurationStore.key(
            model: params.model,
            width: params.width,
            height: params.height,
            isEdit: false
        )
        if params.numImages > 1 { durationKey = durationKey.map { $0 + "|images=\(params.numImages)" } }
        start { await ImageGenerationService.shared.generate(params, jobID: self.jobID) }
    }

    func edit(_ params: ImageEditParameters) {
        durationKey = ImageGenerationDurationStore.key(
            model: params.model,
            width: params.width,
            height: params.height,
            isEdit: true
        )
        start { await ImageGenerationService.shared.edit(params, jobID: self.jobID) }
    }

    func upscale(_ params: ImageUpscaleParameters) {
        let image = NSBitmapImageRep(data: params.sourceImage)
        durationKey = "\(params.model)|\(image?.pixelsWide ?? 0)x\(image?.pixelsHigh ?? 0)|upscale\(params.scale)"
        start { await ImageGenerationService.shared.upscale(params, jobID: self.jobID) }
    }

    func setInspectionResults(_ values: [GeneratedImage]) { results = values }

    func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true
        Task { await ImageGenerationService.shared.cancel(jobID: jobID) }
    }

    private func start(
        _ makeStream: @escaping () async -> AsyncThrowingStream<ImageGenerationEvent, Error>
    ) {
        job?.cancel()
        resultURL = nil
        previewImage = nil
        resultSeed = nil
        resultParameters = nil
        results = []
        isCancelling = false
        lastDuration = nil
        estimate = durationKey.flatMap { ImageGenerationDurationStore.lastDuration(for: $0) }
        phase = .loadingModel("")
        startTiming()
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await makeStream()
                for try await event in stream {
                    await self.apply(event)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isCancelling = false
                    self.finishTiming(persist: false)
                    self.phase = .cancelled
                }
            } catch {
                await MainActor.run {
                    self.isCancelling = false
                    self.finishTiming(persist: false)
                    self.phase = .failed(String(describing: error))
                }
            }
        }
    }

    private func apply(_ event: ImageGenerationEvent) {
        switch event {
        case .loadingModel(let model):
            phase = .loadingModel(model)
        case .step(let step, let total, let eta):
            phase = .running(step: step, total: total, eta: eta)
        case .preview(let data, _):
            previewImage = NSImage(data: data)
        case .imageCompleted(let image, _):
            results.append(image)
            selectResult(image)
        case .completed(let images):
            results = images
            if let first = images.first {
                selectResult(first)
            }
            isCancelling = false
            finishTiming(persist: true)
            phase = .done
        case .failed(let message, _):
            isCancelling = false
            finishTiming(persist: false)
            phase = .failed(message)
        case .cancelled:
            isCancelling = false
            finishTiming(persist: false)
            phase = .cancelled
        }
    }

    func selectResult(_ image: GeneratedImage) {
        resultURL = image.url
        resultSeed = image.seed
        resultParameters = image.effectiveParameters
    }

    private func startTiming() {
        startDate = Date()
        elapsed = 0
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while let self, self.isBusy {
                self.elapsed = Date().timeIntervalSince(self.startDate ?? Date())
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Stop the timer, freeze the final elapsed, and (on success) persist it as
    /// the estimate for the next run with the same key.
    private func finishTiming(persist: Bool) {
        timerTask?.cancel()
        timerTask = nil
        guard let start = startDate else { return }
        let total = Date().timeIntervalSince(start)
        startDate = nil
        elapsed = total
        lastDuration = total
        if persist, let key = durationKey {
            ImageGenerationDurationStore.record(total, for: key)
            estimate = total
        }
    }
}

/// Persists the most recent successful end-to-end duration (Generate press →
/// finished image) per model + size + mode, so the panel can offer a rough
/// "~Xs" estimate before the next run. Backed by a plist dictionary in
/// `UserDefaults`.
enum ImageGenerationDurationStore {
    private static let defaultsKey = "osaurus.imageGeneration.lastDurations"

    static func key(model: String, width: Int?, height: Int?, isEdit: Bool) -> String {
        let size = (width != nil && height != nil) ? "\(width!)x\(height!)" : "auto"
        return "\(model)|\(size)|\(isEdit ? "edit" : "gen")"
    }

    static func lastDuration(for key: String) -> TimeInterval? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double])?[key]
    }

    static func record(_ duration: TimeInterval, for key: String) {
        guard duration.isFinite, duration > 0 else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
        dict[key] = duration
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }
}

struct ImageGenerationPanelView: View {
    @Environment(\.theme) private var inheritedTheme
    #if OSAURUS_DESIGN_INSPECTOR
    @Environment(\.inspectorVerificationWidth) private var inspectorWidth
    #endif
    private var theme: any ThemeProtocol { inheritedTheme }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ImageGenerationPanelModel()
    struct InspectionDisplay {
        let phase: ImageGenerationPanelModel.Phase
        var resultURL: URL? = nil
        var sampling: ImageSamplingCapabilities? = nil
        var results: [GeneratedImage] = []
        var isCancelling = false
        var previewURL: URL? = nil
        var sourceURLs: [URL] = []
        var prompt = ""
    }

    /// Bundle id to drive (e.g. "FLUX.1-schnell"). Locked for this panel.
    let modelId: String
    let displayName: String
    /// `true` ⇒ image-edit bundle (needs a source image); `false` ⇒ text→image.
    let isEdit: Bool
    let modelInfo: ImageModelInfo
    var inspectionDisplay: InspectionDisplay? = nil
    private var isUpscale: Bool { modelInfo.capabilities.upscale }
    private var sheetWidth: CGFloat {
        #if OSAURUS_DESIGN_INSPECTOR
        if inspectionDisplay != nil { return min(620, inspectorWidth) }
        #endif
        return 620
    }
    private var requestPolicy: ImageModelRequestPolicy {
        ImageModelRequestPolicy(canonical: modelInfo.canonicalName)
    }

    @State private var upscaleFactor = 2
    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var sizeIndex: Int = 1  // 0:512, 1:1024
    @State private var seedText: String = ""
    @State private var imageCount = 1
    @State private var livePreviews = false
    @State private var sourceURLs: [URL] = []
    @State private var stepsText = ""
    @State private var guidanceText = ""
    @State private var useSourceSize = true
    @State private var customWidth = 1024
    @State private var customHeight = 1024
    @State private var samplingCapabilities = ImageSamplingCapabilities()
    @State private var sampler = ""
    @State private var scheduler = ""
    @State private var shiftText = ""

    private var samplingInputValid: Bool {
        shiftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || Float(shiftText).map { $0.isFinite } == true
    }
    private var sourceLimit: Int { max(1, samplingCapabilities.maxSourceImages) }

    private let sizes: [Int] = [512, 1024]

    private var parsedInput: ImagePanelParameterInput? {
        try? ImagePanelParameterInput(steps: stepsText, guidance: guidanceText, seed: seedText)
    }

    private var inputError: ImagePanelParameterInput.InputError? {
        do {
            _ = try ImagePanelParameterInput(steps: stepsText, guidance: guidanceText, seed: seedText)
            return nil
        } catch let error as ImagePanelParameterInput.InputError {
            return error
        } catch { return nil }
    }

    private var canRun: Bool {
        if inspectionDisplay != nil { return false }
        return (isUpscale || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!(isEdit || isUpscale) || (!sourceURLs.isEmpty && sourceURLs.count <= sourceLimit))
            && parsedInput != nil
            && samplingInputValid
            && !model.isBusy
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s24) {
                        if model.phase != .idle {
                            activitySection.id("imageGeneration.activity")
                        }
                        if isEdit || isUpscale { sourcePicker }
                        if !isUpscale { promptField }
                        outputSettings
                        if !isUpscale { advancedParams }
                    }
                    .padding(theme.space.s24)
                }
                .onChange(of: model.isBusy) { _, _ in
                    proxy.scrollTo("imageGeneration.activity", anchor: .top)
                }
            }
            Divider()
            footer
        }
        .task(id: modelId) {
            if let inspectionDisplay {
                model.phase = inspectionDisplay.phase
                model.resultURL = inspectionDisplay.resultURL
                model.resultSeed = inspectionDisplay.resultURL == nil ? nil : 1234
                model.isCancelling = inspectionDisplay.isCancelling
                model.previewImage = inspectionDisplay.previewURL.flatMap { NSImage(contentsOf: $0) }
                sourceURLs = inspectionDisplay.sourceURLs
                prompt = inspectionDisplay.prompt
                if let sampling = inspectionDisplay.sampling { samplingCapabilities = sampling }
                model.setInspectionResults(inspectionDisplay.results)
                return
            }
            do {
                samplingCapabilities = try await ImageGenerationService.shared.samplingCapabilities(for: modelId)
            } catch {
                model.phase = .failed(error.localizedDescription)
            }
        }
        .fittedSheetFrame(width: sheetWidth, height: 640)
        .background(theme.surface.canvas)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(isUpscale ? "Upscale Image" : (isEdit ? "Edit Image" : "Generate Image"), bundle: .module)
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle)
                .foregroundColor(theme.text.primary)
                .accessibilityAddTraits(.isHeader)
            supportingText(displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
    }

    // MARK: - Inputs

    private var sourcePicker: some View {
        panelSection(sourceLimit > 1 ? "Source images" : "Source image") {
            if sourceLimit > 1 {
                supportingText(L("Choose up to \(sourceLimit) images in the order they should be used."))
            }
            ForEach(Array(sourceURLs.enumerated()), id: \.offset) { index, url in
                HStack {
                    Text("\(index + 1). \(url.lastPathComponent)")
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription).lineLimit(1)
                    Spacer()
                    if sourceLimit > 1 {
                        SettingsIconButton("arrow.up", help: "Move image up", size: .compact, role: .tertiary) {
                            sourceURLs.swapAt(index, index - 1)
                        }
                        .disabled(index == 0)
                        SettingsIconButton("minus.circle", help: "Remove image", size: .compact, role: .tertiary) {
                            sourceURLs.remove(at: index)
                        }
                    }
                }
            }
            SettingsButton(.secondary, sourceURLs.isEmpty ? "Choose…" : "Replace…", icon: "photo", size: .compact, action: pickSource)
            if sourceURLs.count > sourceLimit {
                Text(localized: "Choose up to \(sourceLimit) source images.").foregroundColor(
                    theme.status.warning.foreground
                )
            }
        }
    }

    private var promptField: some View {
        panelSection("Prompt") {
            SettingsTextEditor(
                text: $prompt,
                placeholder: isEdit ? L("Describe what to change") : L("Describe the image you want to create"),
                minHeight: 70, maxHeight: 144
            )
            .settingsFieldAccessibility(L("Prompt"))

            if modelInfo.capabilities.negativePrompt && (!isEdit || modelInfo.capabilities.editNegativePrompt) {
                SettingsFieldRow(
                    label: "Negative prompt (optional)",
                    hint: requestPolicy.isQwen21 ? "Negative prompt applies when guidance is above 1." : nil
                ) {
                    SettingsTextField(placeholder: L("What to leave out"), text: $negativePrompt)
                }
            }
            if modelInfo.canonicalName == "ideogram" {
                supportingText(L("Use a structured JSON caption."))
                supportingText(#"{"high_level_description": "your description"}"#)
            }
        }
    }

    private var outputSettings: some View {
        panelSection("Output") {
            if isEdit {
                Toggle(isOn: $useSourceSize) { Text(localized: "Use source aspect ratio") }
                    .settingsCheckbox()
            }
            fieldGrid {
                if isUpscale {
                    SettingsFieldRow(label: "Scale") {
                        segmentedControl(selection: $upscaleFactor, options: [
                            .init(2, "2×", verbatim: true),
                            .init(4, "4×", verbatim: true),
                        ], label: "Scale")
                    }
                    seedField
                } else {
                    if requestPolicy.isFlux3 {
                        dimensionField("Width", value: $customWidth, anchor: "imageGeneration.width")
                        dimensionField("Height", value: $customHeight, anchor: "imageGeneration.height")
                    } else {
                        SettingsFieldRow(label: "Size") {
                            segmentedControl(
                                selection: $sizeIndex,
                                options: sizes.indices.map { .init($0, "\(sizes[$0].formatted())²", verbatim: true) },
                                label: "Size"
                            )
                            .disabled(isEdit && useSourceSize)
                        }
                    }
                    if !isEdit {
                        SettingsFieldRow(label: "Images") {
                            SettingsMenuPicker(selection: $imageCount) {
                                ForEach(1...8, id: \.self) { count in Text(verbatim: count.formatted()).tag(count) }
                            }
                            .accessibilityLabel(Text("Images", bundle: .module))
                            .disabled(model.isBusy)
                        }
                    }
                }
            }
            if isUpscale {
                supportingText(L("SeedVR2 restores the image in one step. The source aspect ratio is preserved."))
            }
        }
    }

    private var advancedParams: some View {
        panelSection("Advanced options") {
            fieldGrid {
                seedField
                parameterField(
                    "Steps", value: $stepsText, placeholder: String(modelInfo.defaultSteps ?? 20),
                    error: inputError == .steps ? inputError?.localizedMessage : nil,
                    anchor: "imageGeneration.steps"
                )
                .disabled(modelInfo.canonicalName == "qwen-image-2.1-turbo")
                if requestPolicy.supportsGuidance {
                    parameterField(
                        "Guidance", value: $guidanceText, placeholder: String(modelInfo.defaultGuidance ?? 3.5),
                        error: inputError == .guidance ? inputError?.localizedMessage : nil
                    )
                }
                if !samplingCapabilities.samplers.isEmpty {
                    samplingPicker("Sampler", selection: $sampler, values: samplingCapabilities.samplers,
                        anchor: "imageGeneration.sampler")
                }
                if !samplingCapabilities.schedulers.isEmpty {
                    samplingPicker("Scheduler", selection: $scheduler, values: samplingCapabilities.schedulers,
                        anchor: "imageGeneration.scheduler")
                }
                if samplingCapabilities.supportsShift {
                    parameterField(
                        "Timestep shift", value: $shiftText, placeholder: L("Bundle default"),
                        error: samplingInputValid ? nil : L("Timestep shift must be a finite number."),
                        anchor: "imageGeneration.shift"
                    )
                    .disabled(model.isBusy)
                }
            }
            if modelInfo.canonicalName == "qwen-image-2.1-turbo" {
                supportingText(L("Turbo uses the fixed sampling schedule from its bundle."))
            } else if requestPolicy.isQwen21 {
                supportingText(L("Qwen-Image-2.1 uses at least 2 steps."))
            }
            Toggle(isOn: $livePreviews) { Text(localized: "Live previews") }
                .settingsCheckbox()
                .disabled(model.isBusy)
                .settingsLandingAnchor("imageGeneration.previews")
        }
    }

    private var seedField: some View {
        parameterField(
            "Seed (optional)", value: $seedText, placeholder: L("Random"),
            error: inputError == .seed ? inputError?.localizedMessage : nil
        )
    }

    private func dimensionField(_ label: String, value: Binding<Int>, anchor: String) -> some View {
        SettingsFieldRow(label: label, anchorId: anchor) {
            SettingsTextField(placeholder: "", text: dimensionText(value), monospaced: true, onSubmit: {
                value.wrappedValue = requestPolicy.snappedDimension(value.wrappedValue, limits: modelInfo.requestLimits)
            })
            .disabled(isEdit && useSourceSize)
        }
    }

    private func parameterField(_ label: String, value: Binding<String>, placeholder: String,
        error: String?, anchor: String? = nil) -> some View {
        SettingsFieldRow(label: label, hint: error, anchorId: anchor, verbatimHint: true) {
            SettingsTextField(placeholder: placeholder, text: value, monospaced: true, isInvalid: error != nil)
        }
    }

    private func samplingPicker(_ label: String, selection: Binding<String>, values: [String], anchor: String) -> some View {
        SettingsFieldRow(label: label, anchorId: anchor) {
            SettingsMenuPicker(selection: selection) {
                Text(localized: "Bundle default").tag("")
                ForEach(values, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module))
            .disabled(model.isBusy)
        }
    }

    private func segmentedControl<Value: Hashable>(selection: Binding<Value>,
        options: [SettingsPickerRow<Value>.Option], label: LocalizedStringKey) -> some View {
        AssignedBaseSegmentedPicker(selection: selection, options: options)
            .accessibilityLabel(Text(label, bundle: .module))
    }

    private func fieldGrid<Fields: View>(@ViewBuilder fields: () -> Fields) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: max(156, 112 * theme.fontScale)), spacing: theme.space.s12, alignment: .topLeading)],
            alignment: .leading, spacing: theme.space.s12, content: fields
        )
    }

    // MARK: - Status + result

    private var activitySection: some View {
        panelSection("Results") {
            statusContent
            if let url = model.resultURL {
                resultCard(url)
            } else if model.isBusy, let preview = model.previewImage {
                supportingText(L("Live preview"))
                imagePreview(preview)
            }
        }
    }

    @ViewBuilder private var statusContent: some View {
        if model.isCancelling {
            statusRow(L("Cancelling…"), detail: Self.formatDuration(model.elapsed), spinner: true)
        } else {
            switch model.phase {
            case .idle:
                EmptyView()
            case .loadingModel(let name):
                statusRow(name.isEmpty ? L("Loading model…") : L("Loading \(name)…"),
                    detail: busyTiming, spinner: true)
            case .running(let step, let total, let eta):
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    statusRow(L("Step \(step) of \(total)"),
                        detail: Self.formatDuration(model.elapsed) + (eta.map { " · " + L("\(Self.formatEstimate($0)) remaining") } ?? ""),
                        spinner: true)
                    SettingsProgressBar(value: Double(step) / Double(max(total, 1)))
                        .accessibilityLabel(Text("Image generation progress", bundle: .module))
                }
            case .done:
                statusRow(L("Complete"), detail: model.lastDuration.map(Self.formatDuration),
                    icon: "checkmark.circle.fill", tint: theme.status.success.foreground)
            case .failed(let message):
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    statusRow(L("Couldn’t finish the image"), icon: "exclamationmark.circle.fill",
                        tint: theme.status.error.foreground)
                    supportingText(message)
                }
            case .cancelled:
                statusRow(L("Cancelled"), icon: "xmark.circle")
            }
        }
    }

    /// Elapsed time, with a prior-run estimate when available.
    private var busyTiming: String {
        var suffix = Self.formatDuration(model.elapsed)
        if let estimate = model.estimate {
            suffix += " / " + Self.formatEstimate(estimate)
        }
        return suffix
    }

    private static func formatDuration(_ t: TimeInterval) -> String {
        if t < 60 { return String(format: "%.1fs", t) }
        return String(format: "%dm %02ds", Int(t) / 60, Int(t) % 60)
    }

    private static func formatEstimate(_ t: TimeInterval) -> String {
        let r = t.rounded()
        if r < 60 { return String(format: "~%.0fs", r) }
        return String(format: "~%dm %02ds", Int(r) / 60, Int(r) % 60)
    }

    private func resultCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            if model.results.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: theme.space.s6) {
                        ForEach(Array(model.results.enumerated()), id: \.offset) { index, image in
                            FilterChip(L("Image \(index + 1)"), isSelected: image.url == url) {
                                model.selectResult(image)
                            }
                        }
                    }
                }
            }
            if let image = NSImage(contentsOf: url) {
                imagePreview(image)
            } else {
                supportingText(L("Preview unavailable. Open the image in Finder to view it."))
            }
            if let parameters = model.resultParameters {
                Group {
                    if requestPolicy.isFlux3 {
                        Text("\(parameters.width) × \(parameters.height) · \(parameters.steps) steps")
                    } else {
                        Text("\(parameters.width) × \(parameters.height) · \(parameters.steps) steps · CFG \(parameters.guidance, specifier: "%g")")
                    }
                }
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption.monospacedDigit())
                .foregroundColor(theme.text.secondary)
            }
            if let seed = model.resultSeed {
                supportingText(L("Seed \(String(seed))"))
            }
            HStack(spacing: theme.space.s8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(L("Show in Finder"), systemImage: "folder")
                        .componentInspectionText(54, role: .caption, fallback: .caption, weight: 500, theme: theme)
                }
                .assignedSettingsButtonStyle(.tertiary, size: .compact)
                Button {
                    saveAs(url)
                } label: {
                    Label(L("Save As…"), systemImage: "square.and.arrow.down")
                        .componentInspectionText(54, role: .caption, fallback: .caption, weight: 500, theme: theme)
                }
                .assignedSettingsButtonStyle(.tertiary, size: .compact)
            }
        }
    }

    private func imagePreview(_ image: NSImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium)
        return Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 224)
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.border.default, lineWidth: theme.stroke.default) }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: theme.space.s12) {
            SettingsButton(.tertiary, "Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            if model.isBusy {
                SettingsButton(.destructive, model.isCancelling ? "Cancelling…" : "Cancel",
                    action: cancel)
                    .disabled(model.isCancelling)
            } else {
                SettingsButton(.primary, isUpscale ? "Upscale" : (isEdit ? "Edit" : "Generate"),
                    icon: isUpscale ? "arrow.up.left.and.arrow.down.right" : "sparkles", action: run)
                    .disabled(!canRun)
            }
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s12)
    }

    private func cancel() {
        if inspectionDisplay != nil {
            model.isCancelling = false
            model.phase = .cancelled
            return
        }
        model.cancel()
    }

    // MARK: - Actions

    private func run() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRun, let input = parsedInput else { return }
        let size = sizes[sizeIndex]
        let width = requestPolicy.isFlux3 ? requestPolicy.snappedDimension(customWidth, limits: modelInfo.requestLimits) : size
        let height = requestPolicy.isFlux3 ? requestPolicy.snappedDimension(customHeight, limits: modelInfo.requestLimits) : size
        let seed = input.seed
        let negative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if isUpscale {
            guard let source = sourceURLs.first, let data = try? Data(contentsOf: source) else { return }
            model.upscale(ImageUpscaleParameters(model: modelId, sourceImage: data, scale: upscaleFactor, seed: seed))
        } else if isEdit {
            guard !sourceURLs.isEmpty,
                let sources = try? sourceURLs.map({ try Data(contentsOf: $0) }) else { return }
            model.edit(
                ImageEditParameters(
                    model: modelId,
                    prompt: trimmedPrompt,
                    sourceImages: sources,
                    negativePrompt: modelInfo.capabilities.editNegativePrompt && !negative.isEmpty ? negative : nil,
                    width: useSourceSize ? nil : width,
                    height: useSourceSize ? nil : height,
                    steps: input.steps, guidance: requestPolicy.supportsGuidance ? input.guidance : nil,
                    seed: seed,
                    sampler: sampler.isEmpty ? nil : sampler, scheduler: scheduler.isEmpty ? nil : scheduler,
                    shift: shiftText.isEmpty ? nil : Float(shiftText),
                    previewInterval: livePreviews ? 5 : nil
                )
            )
        } else {
            model.generate(
                ImageGenerationParameters(
                    model: modelId,
                    prompt: trimmedPrompt,
                    negativePrompt: modelInfo.capabilities.negativePrompt && !negative.isEmpty ? negative : nil,
                    width: width,
                    height: height,
                    steps: input.steps, guidance: requestPolicy.supportsGuidance ? input.guidance : nil,
                    seed: seed, numImages: imageCount,
                    sampler: sampler.isEmpty ? nil : sampler, scheduler: scheduler.isEmpty ? nil : scheduler,
                    shift: shiftText.isEmpty ? nil : Float(shiftText),
                    previewInterval: livePreviews ? 5 : nil
                )
            )
        }
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = sourceLimit > 1
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { sourceURLs = panel.urls }
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

    /// Edits a pixel dimension as text; input that is not a whole number is ignored.
    private func dimensionText(_ value: Binding<Int>) -> Binding<String> {
        Binding(
            get: { String(value.wrappedValue) },
            set: { text in
                if let number = Int(text.trimmingCharacters(in: .whitespaces)) { value.wrappedValue = number }
            }
        )
    }

    private func panelSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(title, bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func supportingText(_ text: String) -> some View {
        Text(verbatim: text)
            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusRow(_ title: String, detail: String? = nil, spinner: Bool = false, icon: String? = nil,
        tint: Color? = nil) -> some View {
        HStack(spacing: theme.space.s8) {
            if spinner {
                SettingsSpinner()
            } else if let icon {
                Image(systemName: icon)
                    .foregroundColor(tint ?? theme.text.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: title)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                if let detail { supportingText(detail) }
            }
        }
    }
}
