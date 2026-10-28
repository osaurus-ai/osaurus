import Foundation

struct AgentGenerationFieldDraft: Equatable {
    var isCustom = false
    var text = ""

    init(_ value: String? = nil) {
        isCustom = value != nil
        text = value ?? ""
    }

    func value(named name: String) throws -> String? {
        guard isCustom else { return nil }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw ChatTurnOverrides.ValidationError.invalid("Enter a value for \(name), or select Inherit.")
        }
        return raw
    }

    func float(named name: String) throws -> Float? {
        guard let raw = try value(named: name) else { return nil }
        guard let number = Float(raw), number.isFinite else {
            throw ChatTurnOverrides.ValidationError.invalid("\(name) must be a finite number.")
        }
        return number
    }

    func integer(named name: String) throws -> Int? {
        guard let raw = try value(named: name) else { return nil }
        guard let number = Int(raw) else {
            throw ChatTurnOverrides.ValidationError.invalid("\(name) must be an integer.")
        }
        return number
    }
}

/// Unsaved editor text is separate from the persisted agent. Invalid input never erases a saved value.
struct AgentGenerationDraft: Equatable {
    var temperature = AgentGenerationFieldDraft()
    var maxTokens = AgentGenerationFieldDraft()
    var topP = AgentGenerationFieldDraft()
    var topK = AgentGenerationFieldDraft()
    var minP = AgentGenerationFieldDraft()
    var repetitionPenalty = AgentGenerationFieldDraft()
    var frequencyPenalty = AgentGenerationFieldDraft()
    var presencePenalty = AgentGenerationFieldDraft()
    var seed = AgentGenerationFieldDraft()
    var stop = AgentGenerationFieldDraft()
    var templateKwargs = AgentGenerationFieldDraft()
    var thinking = "inherit"
    var reasoningEffort = ""

    init(temperature: Float? = nil, maxTokens: Int? = nil, settings: AgentGenerationSettings? = nil) {
        self.temperature = .init(temperature.map { String($0) })
        self.maxTokens = .init(maxTokens.map { String($0) })
        topP = .init(settings?.topP.map { String($0) })
        topK = .init(settings?.topK.map { String($0) })
        minP = .init(settings?.minP.map { String($0) })
        repetitionPenalty = .init(settings?.repetitionPenalty.map { String($0) })
        frequencyPenalty = .init(settings?.frequencyPenalty.map { String($0) })
        presencePenalty = .init(settings?.presencePenalty.map { String($0) })
        seed = .init(settings?.seed.map { String($0) })
        thinking = settings?.enableThinking.map { $0 ? "on" : "off" } ?? "inherit"
        reasoningEffort = settings?.reasoningEffort ?? ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        stop = .init(settings?.stop.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) })
        templateKwargs = .init(settings?.templateKwargs.flatMap { try? encoder.encode($0) }.map {
            String(decoding: $0, as: UTF8.self)
        })
    }

    struct Values {
        var temperature: Float?
        var maxTokens: Int?
        var settings: AgentGenerationSettings?
    }

    func validated() throws -> Values {
        let temperature = try temperature.float(named: "Temperature")
        try ChatTurnOverrides(temperature: temperature).validate()
        let maxTokens = try maxTokens.integer(named: "Max Tokens")
        if let maxTokens, maxTokens < 1 {
            throw ChatTurnOverrides.ValidationError.invalid("Max Tokens must be a positive integer.")
        }
        let stops = try stop.value(named: "Stop sequences").map {
            try JSONDecoder().decode([String].self, from: Data($0.utf8))
        }
        let kwargs = try templateKwargs.value(named: "Template parameters").map {
            try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
        }
        let settings = AgentGenerationSettings(
            topP: try topP.float(named: "Top P"), topK: try topK.integer(named: "Top K"),
            minP: try minP.float(named: "Min P"),
            repetitionPenalty: try repetitionPenalty.float(named: "Repetition penalty"),
            frequencyPenalty: try frequencyPenalty.float(named: "Frequency penalty"),
            presencePenalty: try presencePenalty.float(named: "Presence penalty"),
            seed: try seed.integer(named: "Seed"), stop: stops,
            enableThinking: thinking == "inherit" ? nil : thinking == "on",
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort,
            templateKwargs: kwargs
        )
        try settings.validate()
        return Values(temperature: temperature, maxTokens: maxTokens, settings: settings.isEmpty ? nil : settings)
    }
}
