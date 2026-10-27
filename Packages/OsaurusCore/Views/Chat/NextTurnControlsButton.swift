import SwiftUI

/// A one-turn draft. Apply changes only to the composer binding, never global stores.
struct NextTurnControlsButton: View {
    @Binding var overrides: ChatTurnOverrides
    let model: String?
    let reasoningCapabilities: ModelReasoningCapabilities?
    @State private var isPresented = false
    @State private var temperature = ""
    @State private var topP = ""
    @State private var topK = ""
    @State private var effort = ""
    @State private var thinking = "inherit"
    @State private var kwargs = ""
    @State private var validationError: String?

    private var effortLevels: [ModelOptionSegment] {
        if let reasoningCapabilities { return reasoningCapabilities.levels.map { .init(id: $0.id, label: $0.id) } }
        guard let model, let definition = ModelProfileRegistry.profile(for: model)?.options.first(where: { $0.id == "reasoningEffort" }),
            case .segmented(let levels) = definition.kind else { return [] }
        return levels
    }

    var body: some View {
        Button {
            temperature = overrides.temperature.map { String($0) } ?? ""
            topP = overrides.topP.map { String($0) } ?? ""
            topK = overrides.topK.map { String($0) } ?? ""
            effort = overrides.reasoningEffort ?? ""
            thinking = overrides.enableThinking.map { $0 ? "on" : "off" } ?? "inherit"
            if let value = overrides.templateKwargs, !value.isEmpty,
                let bytes = try? JSONEncoder().encode(value) { kwargs = String(decoding: bytes, as: UTF8.self) }
            else { kwargs = "" }
            validationError = nil
            isPresented = true
        } label: {
            Label(overrides.isEmpty ? L("Next turn") : L("Next turn •"), systemImage: "slider.horizontal.3")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .localizedHelp("Override generation parameters for the next submitted turn")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text(localized: "Next turn").font(.headline)
                Text(localized: "Blank fields inherit your existing defaults. Changes apply to one submitted turn, including its tool steps and retries.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    numberField(L("Temperature"), text: $temperature)
                    numberField(L("Top P"), text: $topP)
                    numberField(L("Top K"), text: $topK)
                }
                if let model, ModelProfileRegistry.profile(for: model)?.thinkingOption != nil {
                    Picker(L("Thinking"), selection: $thinking) {
                        Text(localized: "Inherit").tag("inherit")
                        Text(localized: "On").tag("on")
                        Text(localized: "Off").tag("off")
                    }
                }
                if !effortLevels.isEmpty {
                    Picker(L("Reasoning effort"), selection: $effort) {
                        Text(localized: "Inherit").tag("")
                        ForEach(effortLevels) { level in Text(level.label).tag(level.id) }
                    }
                }
                DisclosureGroup(L("Template parameters (JSON)")) {
                    TextEditor(text: $kwargs).font(.system(.caption, design: .monospaced))
                        .frame(height: 105)
                    Text(localized: "A JSON object of parameters for the model’s chat template. Blank inherits; nested null values are preserved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(localized: "Reset to inherited") {
                        overrides = ChatTurnOverrides()
                        isPresented = false
                    }
                    Spacer()
                    Button(localized: "Cancel") { isPresented = false }
                    Button(localized: "Apply") { apply() }.keyboardShortcut(.defaultAction)
                }
            }.padding(16).frame(width: 410)
        }
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            TextField(L("Inherit"), text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func apply() {
        do {
            func float(_ raw: String, _ label: String) throws -> Float? {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                guard let number = Float(value) else { throw ChatTurnOverrides.ValidationError.invalid("\(label) must be a number.") }
                return number
            }
            let integer = topK.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedTopK = integer.isEmpty ? nil : Int(integer)
            if !integer.isEmpty, parsedTopK == nil { throw ChatTurnOverrides.ValidationError.invalid("Top K must be an integer.") }
            let rawKwargs = kwargs.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedKwargs = rawKwargs.isEmpty ? nil : try JSONDecoder().decode([String: JSONValue].self, from: Data(rawKwargs.utf8))
            let candidate = ChatTurnOverrides(
                temperature: try float(temperature, "Temperature"), topP: try float(topP, "Top P"), topK: parsedTopK,
                reasoningEffort: effort.isEmpty ? nil : effort,
                enableThinking: thinking == "inherit" ? nil : thinking == "on", templateKwargs: parsedKwargs)
            try candidate.validate()
            overrides = candidate
            isPresented = false
        } catch { validationError = error.localizedDescription }
    }
}
