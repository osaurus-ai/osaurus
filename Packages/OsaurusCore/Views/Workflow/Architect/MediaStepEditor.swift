//
//  MediaStepEditor.swift
//  osaurus
//
//  The Edit Step form for a media step: what it makes, the model, and
//  every parameter that model takes. Fields the resolved model can't use
//  are hidden; each number can be set here or bound to a value from the
//  run (`{{input.seed}}`, `{{item}}`).
//

import SwiftUI

struct MediaStepEditor: View {
    @Binding var spec: MediaSpec
    /// The workflow's input names, to flag a field linked to one it lacks.
    var inputKeys: Set<String>? = nil

    @ObservedObject private var pickerCache = ModelPickerItemCache.shared
    @Environment(\.theme) private var theme

    var body: some View {
        let candidates = MediaModelResolver.candidates(from: pickerCache.items)
        let resolved = MediaModelResolver.resolve(
            spec.model, action: spec.action, candidates: candidates,
            preferred: MediaModelResolver.configuredDefault(for: spec.action))
        let model = try? resolved.get()
        VStack(alignment: .leading, spacing: theme.space.s16) {
            field("Makes") {
                AssignedBaseSegmentedPicker(
                    selection: $spec.action,
                    options: [
                        .init(MediaAction.generate, "Image"), .init(MediaAction.edit, "Edit"),
                        .init(MediaAction.upscale, "Upscale"), .init(MediaAction.video, "Video"),
                    ]
                )
                .fixedSize()
                .accessibilityLabel(Text("Makes", bundle: .module))
            }
            modelField(candidates: candidates, resolved: resolved)
            if spec.action.usesPrompt {
                field("Prompt") {
                    longText(
                        $spec.prompt, placeholder: L("What to make. Use {{input.x}} for values from the run."), lines: 8)
                }
                if spec.action != .video && Self.takesNegativePrompt(model, action: spec.action) {
                    field("Negative Prompt") {
                        longText(optionalText($spec.negativePrompt), placeholder: L("What to avoid"), lines: 3)
                    }
                }
            }
            if spec.action.usesSources || spec.action == .video {
                field(spec.action == .video ? "Starting Image" : "Source Images") {
                    longText(sourcesText, placeholder: "{{nodes.<id>.output.images}}", lines: 4, monospaced: true)
                }
                switch spec.action {
                case .upscale:
                    note(L("One image. Bind an earlier media step's images, or a file from the run's input."))
                case .video:
                    note(L("Optional: one image to animate. Bind an earlier media step's images, or a file from the run's input."))
                default:
                    note(L("One per line, up to \(MediaSpec.maximumSources). A media step's images bind as a list."))
                }
            }
            switch spec.action {
            case .generate, .edit:
                imageParameters(model)
            case .upscale:
                field("Scale") {
                    MediaParameterField(inputKeys: inputKeys, key: "scale", placeholder: "4", value: $spec.scale)
                }
                note(L("2× or 4×."))
                seedFields
            case .video:
                videoParameters(model)
            }
        }
        .onAppear { if !pickerCache.isLoaded { pickerCache.prewarm() } }
    }

    // MARK: - Model

    private func modelField(
        candidates: [MediaModelCandidate], resolved: Result<MediaModelCandidate, MediaModelResolver.Failure>
    ) -> some View {
        let usable = candidates.filter { $0.supports(spec.action) }
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            field("Model") {
                HStack(spacing: theme.space.s8) {
                    SettingsMenuPicker(selection: modelChoice) {
                        Text("Default", bundle: .module).tag("")
                        if let family = spec.model.family {
                            Text(verbatim: L("Any \(family) model")).tag("family:\(family)")
                        }
                        if let id = spec.model.id, !usable.contains(where: { $0.id == id }) {
                            Text(verbatim: id).tag("id:\(id)")
                        }
                        Divider()
                        ForEach(usable) { candidate in
                            Text(verbatim: candidate.isLocal
                                ? candidate.displayName
                                : L("\(candidate.displayName) (billable)"))
                                .tag("id:\(candidate.id)")
                        }
                    }
                    .settingsPickerHugging()
                    if spec.action == .generate || spec.action == .video {
                        SettingsMenuPicker(selection: $spec.model.locality) {
                            Text("This Mac", bundle: .module).tag(MediaLocality.local)
                            Text("Provider", bundle: .module).tag(MediaLocality.remote)
                            Text("Either", bundle: .module).tag(MediaLocality.any)
                        }
                        .fixedSize()
                    }
                }
            }
            switch resolved {
            case _ where !pickerCache.isLoaded:
                HStack(spacing: theme.space.s6) {
                    SettingsSpinner()
                    note(L("Looking for image and video models…"))
                }
            case .success(let model):
                note(Self.describe(model))
            case .failure(let failure):
                Text(verbatim: WorkflowErrorText.text(failure))
                    .textStyle(.footnote)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelChoice: Binding<String> {
        Binding(
            get: {
                if let id = spec.model.id { return "id:\(id)" }
                if let family = spec.model.family { return "family:\(family)" }
                return ""
            },
            set: { choice in
                if choice.hasPrefix("id:") {
                    spec.model.id = String(choice.dropFirst(3))
                } else if choice.hasPrefix("family:") {
                    spec.model.id = nil
                    spec.model.family = String(choice.dropFirst(7))
                } else {
                    spec.model.id = nil
                    spec.model.family = nil
                }
            })
    }

    /// "Runs on Qwen-Image 2.1 on this Mac · sizes in steps of 32 up to 2048 · 30 steps by default".
    static func describe(_ model: MediaModelCandidate) -> String {
        var parts = [model.isLocal ? L("Runs on \(model.displayName) on this Mac") : L("Runs on \(model.displayName)")]
        if let c = model.capabilities, c.textToImage || c.imageEdit, let max = model.maxDimension {
            let multiple = model.limits?.dimensionMultiple ?? c.dimensionMultiple
            parts.append(L("sizes in steps of \(multiple) up to \(max)"))
        }
        if let fixed = model.limits?.fixedSteps {
            parts.append(L("a fixed \(fixed)-step schedule"))
        } else if let steps = model.defaultSteps {
            parts.append(L("\(steps) steps by default"))
        }
        if let price = model.media?.pricing?.minimumUSD {
            parts.append(L("from \(String(format: "$%.2f", price)) per run"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Image

    static func takesNegativePrompt(_ model: MediaModelCandidate?, action: MediaAction) -> Bool {
        if let l = model?.limits { return action == .edit ? l.supportsEditNegativePrompt : l.supportsNegativePrompt }
        return model?.capabilities?.negativePrompt != false
    }

    /// The formats the model writes: its engine's list, else PNG only for
    /// Qwen-Image 2.1, else all of them.
    static func formats(_ model: MediaModelCandidate?) -> [ImageOutputFormat] {
        if let formats = model?.limits?.outputFormats, !formats.isEmpty { return formats }
        return ImageModelRequestPolicy.isQwen21Family(model?.family) ? [.png] : ImageOutputFormat.allCases
    }

    private static func formatName(_ format: ImageOutputFormat) -> String {
        switch format {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        }
    }

    /// Why a static size won't run on `model`: off its engine grid when it
    /// publishes limits, else Qwen-Image 2.1's grid when the step selects it.
    static func sizeWarning(width: Int?, height: Int?, model: MediaModelCandidate?, selectsQwen21: Bool) -> String? {
        for value in [width, height].compactMap({ $0 }) {
            if let model, let limits = model.limits {
                if let fix = model.sizeFix(value) {
                    let name = model.displayName
                    let step = limits.dimensionMultiple
                    if let max = model.maxDimension {
                        return L("\(name) takes sizes in steps of \(step) up to \(max), so \(value) won't run. Try \(fix).")
                    }
                    return L("\(name) takes sizes in steps of \(step), so \(value) won't run. Try \(fix).")
                }
            } else if selectsQwen21 || ImageModelRequestPolicy.isQwen21Family(model?.family),
                let fix = MediaSpec.qwen21SizeFix(value)
            {
                return L("Qwen-Image 2.1 takes sizes in steps of 32 up to 2048, so \(value) won't run. Try \(fix).")
            }
        }
        return nil
    }

    @ViewBuilder
    private func imageParameters(_ model: MediaModelCandidate?) -> some View {
        let q21 = ImageModelRequestPolicy.isQwen21Family(model?.family)
        let formats = Self.formats(model)
        field("Size") {
            HStack(spacing: theme.space.s6) {
                MediaParameterField(inputKeys: inputKeys, key: "width", placeholder: L("Width"), value: $spec.width)
                Text(verbatim: "×").foregroundColor(theme.text.tertiary)
                MediaParameterField(inputKeys: inputKeys, key: "height", placeholder: L("Height"), value: $spec.height)
                SettingsOverflowMenu(icon: "aspectratio", help: "Size Presets") {
                    ForEach(Self.sizePresets(maximum: model?.maxDimension ?? (q21 ? 2048 : 1024)), id: \.label) { preset in
                        Button(preset.label) {
                            spec.width = .value(preset.width)
                            spec.height = .value(preset.height)
                        }
                    }
                }
            }
        }
        if let warning = Self.sizeWarning(
            width: spec.width?.staticValue, height: spec.height?.staticValue, model: model,
            selectsQwen21: spec.model.selectsQwen21)
        {
            Text(verbatim: warning)
                .textStyle(.footnote)
                .foregroundColor(theme.status.warning.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .top, spacing: theme.space.s12) {
            field("Steps") {
                MediaParameterField(
                    inputKeys: inputKeys, key: "steps", placeholder: model?.defaultSteps.map(String.init) ?? L("Model default"),
                    value: $spec.steps)
            }
            field("Guidance") {
                MediaParameterField(
                    inputKeys: inputKeys, key: "guidance",
                    placeholder: model?.defaultGuidance.map { String(format: "%.1f", $0) } ?? L("Model default"),
                    value: $spec.guidance)
            }
        }
        if let model, let fixed = model.limits?.fixedSteps {
            let name = model.displayName
            note(L("\(name) runs a fixed \(fixed)-step schedule from its bundle; Steps is not used."))
        }
        if let model, let limits = model.limits {
            samplingFields(limits)
            if let warning = Self.samplingWarning(spec, model: model) {
                Text(verbatim: warning)
                    .textStyle(.footnote)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if spec.action == .edit && (model?.limits?.supportsStrength ?? model?.capabilities?.editStrength) != false {
            field("Strength") {
                MediaParameterField(inputKeys: inputKeys, key: "strength", placeholder: "0.75", value: $spec.strength)
            }
            note(L("0 keeps the source, 1 ignores it."))
        }
        seedFields
        HStack(alignment: .top, spacing: theme.space.s12) {
            if spec.action == .generate {
                field("Images") {
                    MediaParameterField(inputKeys: inputKeys, key: "count", placeholder: "1", value: $spec.count)
                }
                if let parallel = model?.limits?.maximumParallelImages, parallel > 1 {
                    field("Batch Size") {
                        MediaParameterField(
                            inputKeys: inputKeys, key: "batch_size", placeholder: "1", value: $spec.batchSize)
                    }
                }
            }
            if formats.count > 1 {
                field("Format") {
                    SettingsMenuPicker(selection: formatChoice) {
                        ForEach(formats, id: \.self) { format in
                            Text(verbatim: Self.formatName(format)).tag(format)
                        }
                    }
                    .fixedSize()
                }
            }
        }
        if spec.action == .generate {
            note(L("Up to \(MediaSpec.maximumCount) images, each with its own seed."))
        }
        if model?.isLocal != false {
            field("Preview Every") {
                MediaParameterField(
                    inputKeys: inputKeys, key: "preview_interval", placeholder: L("Off"), value: $spec.previewInterval)
            }
            note(L("Draws a small preview every N steps while the run is open. Leave empty for none."))
        }
    }

    /// What the model refuses among the step's typed sampler, scheduler,
    /// and shift, in the words the run would fail with.
    static func samplingWarning(_ spec: MediaSpec, model: MediaModelCandidate) -> String? {
        guard let limits = model.limits else { return nil }
        let typed: (String?) -> String? = { $0.flatMap { $0.contains("{{") ? nil : $0 } }
        let sampling = ImageRequestLimits.Sampling(
            sampler: typed(spec.sampler), scheduler: typed(spec.scheduler),
            shift: spec.shift?.staticValue.map(Float.init))
        guard let refused = limits.samplingRefusal(sampling) else { return nil }
        let name = model.displayName
        let key = MediaNodeExecutor.specKey(refused.field)
        return L("\(name) refuses `\(key)` = \(refused.value): it takes \(refused.allowed).")
    }

    /// Sampler, scheduler, and shift, as the model's engine lists them.
    /// A list of one is the model's fixed choice and is not shown unless
    /// the step already sets it, so a value from another model stays visible.
    @ViewBuilder
    private func samplingFields(_ limits: ImageRequestLimits) -> some View {
        let samplers = limits.samplers
        let schedulers = limits.schedulers
        let showsSampler = samplers.count > 1 || spec.sampler != nil
        let showsScheduler = schedulers.count > 1 || spec.scheduler != nil
        let showsShift = limits.supportsShift || spec.shift != nil
        if showsSampler || showsScheduler || showsShift {
            HStack(alignment: .top, spacing: theme.space.s12) {
                if showsSampler {
                    field("Sampler") {
                        namedChoice(
                            text: optionalText($spec.sampler), options: samplers, defaultName: limits.defaultSampler)
                    }
                }
                if showsScheduler {
                    field("Scheduler") {
                        namedChoice(
                            text: optionalText($spec.scheduler), options: schedulers,
                            defaultName: limits.defaultScheduler)
                    }
                }
                if showsShift {
                    field("Shift") {
                        MediaParameterField(
                            inputKeys: inputKeys, key: "shift", placeholder: L("Model default"), value: $spec.shift)
                    }
                }
            }
        }
    }

    /// A picker over the model's names, keeping a value it doesn't list
    /// (a binding, or a name from another model) visible.
    private func namedChoice(text: Binding<String>, options: [String], defaultName: String?) -> some View {
        SettingsMenuPicker(selection: text) {
            Text(verbatim: defaultName.map { L("Default (\($0))") } ?? L("Default")).tag("")
            if !text.wrappedValue.isEmpty, !options.contains(text.wrappedValue) {
                Text(verbatim: text.wrappedValue).tag(text.wrappedValue)
            }
            ForEach(options, id: \.self) { Text(verbatim: $0).tag($0) }
        }
        .fixedSize()
    }

    private var formatChoice: Binding<ImageOutputFormat> {
        Binding(get: { spec.format ?? .png }, set: { spec.format = $0 == .png ? nil : $0 })
    }

    struct SizePreset {
        var label: String
        var width: Int
        var height: Int
    }

    static func sizePresets(maximum: Int) -> [SizePreset] {
        var out = [
            SizePreset(label: L("Square 512"), width: 512, height: 512),
            SizePreset(label: L("Square 768"), width: 768, height: 768),
            SizePreset(label: L("Square 1024"), width: 1024, height: 1024),
            SizePreset(label: L("Landscape 1024 × 768"), width: 1024, height: 768),
            SizePreset(label: L("Portrait 768 × 1024"), width: 768, height: 1024),
        ]
        if maximum >= 2048 {
            out += [
                SizePreset(label: L("Landscape 1248 × 832"), width: 1248, height: 832),
                SizePreset(label: L("Portrait 832 × 1248"), width: 832, height: 1248),
                SizePreset(label: L("Square 2048"), width: 2048, height: 2048),
            ]
        }
        return out
    }

    // MARK: - Seed

    @ViewBuilder
    private var seedFields: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            field("Seed") {
                SettingsMenuPicker(selection: seedMode) {
                    Text("Random", bundle: .module).tag(MediaSeedMode.random)
                    Text("Fixed", bundle: .module).tag(MediaSeedMode.fixed)
                    Text("Step Through", bundle: .module).tag(MediaSeedMode.increment)
                }
                .fixedSize()
            }
            if spec.effectiveSeedMode != .random {
                field(spec.effectiveSeedMode == .increment ? "Starting Seed" : "Seed Value") {
                    MediaParameterField(inputKeys: inputKeys, key: "seed", placeholder: "42", value: $spec.seed)
                }
            }
        }
        switch spec.effectiveSeedMode {
        case .random: note(L("A new seed each run. The seed used is saved with each image."))
        case .fixed: note(L("The same seed every run, so changes to the prompt are easy to compare."))
        case .increment: note(L("Adds the item number in a For Each step, so each item gets the next seed."))
        }
    }

    private var seedMode: Binding<MediaSeedMode> {
        Binding(
            get: { spec.effectiveSeedMode },
            set: { mode in
                spec.seedMode = mode
                if mode != .random && spec.seed == nil { spec.seed = .value(42) }
            })
    }

    // MARK: - Video

    @ViewBuilder
    private func videoParameters(_ model: MediaModelCandidate?) -> some View {
        let constraints = model?.media?.constraints
        HStack(alignment: .top, spacing: theme.space.s12) {
            field("Duration") {
                choiceField(
                    text: optionalText($spec.duration), options: constraints?.durations ?? [], placeholder: "5")
            }
            field("Resolution") {
                choiceField(
                    text: optionalText($spec.resolution), options: constraints?.resolutions ?? [],
                    placeholder: "720p")
            }
            field("Aspect Ratio") {
                choiceField(
                    text: optionalText($spec.aspectRatio), options: constraints?.aspectRatios ?? [],
                    placeholder: "16:9")
            }
        }
        if constraints?.audioConfigurable == true {
            SettingsToggle(title: "With Audio", isOn: audio)
        }
        if model?.isLocal == true {
            HStack(alignment: .top, spacing: theme.space.s12) {
                field("Frames") {
                    MediaParameterField(inputKeys: inputKeys, key: "frame_count", placeholder: "49", value: $spec.frameCount)
                }
                field("Frame Rate") {
                    MediaParameterField(
                        inputKeys: inputKeys, key: "fps", placeholder: "\(LocalVideoRequestPolicy.defaultFPS)",
                        value: $spec.fps)
                }
                field("Steps") {
                    MediaParameterField(
                        inputKeys: inputKeys, key: "steps",
                        placeholder: constraints?.defaultSteps.map(String.init) ?? L("Model default"), value: $spec.steps)
                }
                field("Guidance") {
                    MediaParameterField(inputKeys: inputKeys, key: "guidance", placeholder: "5", value: $spec.guidance)
                }
            }
            field("Size") {
                HStack(spacing: theme.space.s6) {
                    MediaParameterField(inputKeys: inputKeys, key: "width", placeholder: L("Width"), value: $spec.width)
                    Text(verbatim: "×").foregroundColor(theme.text.tertiary)
                    MediaParameterField(inputKeys: inputKeys, key: "height", placeholder: L("Height"), value: $spec.height)
                }
            }
            note(L("Frames are 4n+1 and must equal duration × frame rate: 49 frames at 16 fps is 3.0625 s. Leave Duration empty to take it from Frames. Size defaults to the resolution and aspect ratio, in steps of 16."))
        }
        seedFields
        if model?.isLocal == true {
            note(L("Runs on this Mac at no cost. Stop ends it at the next step."))
        } else {
            note(L("Videos are made by a connected provider and are billed per run. You approve the price before it starts."))
        }
    }

    private var audio: Binding<Bool> {
        Binding(get: { spec.audio?.staticValue ?? false }, set: { spec.audio = $0 ? .value(true) : nil })
    }

    @ViewBuilder
    private func choiceField(text: Binding<String>, options: [String], placeholder: String) -> some View {
        if options.isEmpty {
            SettingsTextField(placeholder: placeholder, text: text, monospaced: true)
        } else {
            SettingsMenuPicker(selection: text) {
                Text("Default", bundle: .module).tag("")
                ForEach(options, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .fixedSize()
        }
    }

    // MARK: - Helpers

    private var sourcesText: Binding<String> {
        Binding(
            get: { spec.sources.joined(separator: "\n") },
            set: { text in
                spec.sources = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    /// A text view, not a vertical `TextField`: that one lays its whole value
    /// out on every measure, and the Architect writes long prompts.
    private func longText(_ text: Binding<String>, placeholder: String, lines: CGFloat, monospaced: Bool = false)
        -> some View
    {
        let line = theme.lineHeight(.bodySmall)
        return SettingsTextEditor(
            text: text, placeholder: placeholder, minHeight: line * min(3, lines), maxHeight: line * lines,
            monospaced: monospaced)
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(label, bundle: .module)
                .textStyle(.caption, weight: 500)
                .foregroundColor(theme.text.secondary)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One media parameter: a number typed here, or (after the link button) a
/// `{{...}}` binding rendered when the step runs. Empty means the model's
/// default.
struct MediaParameterField<T: MediaScalar & LosslessStringConvertible>: View {
    /// The workflow's input names; nil when unknown.
    var inputKeys: Set<String>? = nil
    let key: String
    let placeholder: String
    @Binding var value: MediaValue<T>?

    @Environment(\.theme) private var theme
    @State private var text = ""
    @State private var bound = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
            HStack(spacing: theme.space.s4) {
                SettingsTextField(
                    placeholder: bound ? "{{input.\(key)}}" : placeholder, text: $text, monospaced: bound,
                    isInvalid: !isValid)
                SettingsIconButton(
                    "link", help: bound ? L("Type a value") : L("Take this from the run"), size: .compact,
                    isActive: bound
                ) {
                    bound.toggle()
                    text = bound ? "{{input.\(key)}}" : (value?.staticValue.map { $0.description } ?? "")
                }
            }
            if let missing = missingInput {
                Text(verbatim: L("The workflow has no input “\(missing)”. Add it to the inputs, or link something else."))
                    .textStyle(.footnote)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
        .onChange(of: value) { _, _ in if parsed != value { load() } }
        .onChange(of: text) { _, _ in if isValid, parsed != value { value = parsed } }
    }

    private func load() {
        switch value {
        case .bound(let template):
            bound = true
            text = template
        case .value(let v):
            bound = false
            text = v.description
        case nil:
            text = ""
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    private var parsed: MediaValue<T>? {
        if trimmed.isEmpty { return nil }
        if trimmed.contains("{{") { return .bound(trimmed) }
        return T(trimmed).map { .value($0) }
    }

    private var isValid: Bool { trimmed.isEmpty || parsed != nil }

    /// The input a linked value names that the workflow doesn't declare.
    private var missingInput: String? {
        guard bound, let inputKeys else { return nil }
        return Self.inputNames(in: trimmed).first { !inputKeys.contains($0) }
    }

    /// `seed` from "{{input.seed}}", `size` from "{{ input.size.w }}".
    nonisolated static func inputNames(in text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            rest = rest[open.upperBound...]
            let body = rest.prefix { $0 != "}" }.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("input.") {
                let name = body.dropFirst("input.".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { names.append(String(name)) }
            }
        }
        return names
    }
}
