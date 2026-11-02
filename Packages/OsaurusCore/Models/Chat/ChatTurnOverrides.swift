import Foundation

/// One composer submission. Nil fields inherit; zero and false are explicit values.
/// Never written into agent, model-option, or server-default stores.
public struct ChatTurnOverrides: Codable, Equatable, Sendable {
    public var temperature: Float? = nil
    public var topP: Float? = nil
    public var topK: Int? = nil
    public var reasoningEffort: String? = nil
    public var enableThinking: Bool? = nil
    public var templateKwargs: [String: JSONValue]? = nil

    public init(temperature: Float? = nil, topP: Float? = nil, topK: Int? = nil,
        reasoningEffort: String? = nil, enableThinking: Bool? = nil,
        templateKwargs: [String: JSONValue]? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.reasoningEffort = reasoningEffort
        self.enableThinking = enableThinking
        self.templateKwargs = templateKwargs
    }

    var isEmpty: Bool {
        temperature == nil && topP == nil && topK == nil && reasoningEffort == nil
            && enableThinking == nil && templateKwargs == nil
    }

    enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    func validate() throws {
        if let temperature, !temperature.isFinite || temperature < 0 {
            throw ValidationError.invalid("Temperature must be a finite, nonnegative number.")
        }
        if let topP, !topP.isFinite || !(0...1).contains(topP) {
            throw ValidationError.invalid("Top P must be between 0 and 1.")
        }
        if let topK, topK < 0 {
            throw ValidationError.invalid("Top K must be a nonnegative integer; 0 disables it.")
        }
        if let reasoningEffort, reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.invalid("Clear reasoning effort to inherit the model default.")
        }
        try ChatTemplateParameters.validate(templateKwargs)
    }

    /// Shared workspace agents execute their host's controls. Never accept
    /// an explicit local override and silently discard it on the remote wire.
    func validate(forWorkspaceAgent isWorkspaceAgent: Bool) throws {
        try validate()
        if isWorkspaceAgent, !isEmpty {
            throw ValidationError.invalid("Per-turn controls are not supported for shared workspace agents. The remote agent owns its generation settings.")
        }
    }

    func apply(to request: inout ResponsesInferenceRequest) {
        if let temperature { request.generation.temperature = temperature }
        if let topP { request.generation.topP = topP }
        if let topK { request.generation.topK = topK }
        if let reasoningEffort { request.generation.reasoningEffort = reasoningEffort }
        if let enableThinking { request.generation.enableThinking = enableThinking }
        if let templateKwargs { request.generation.templateKwargs = templateKwargs }
    }
}
