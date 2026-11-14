import Foundation

/// Protocol negotiation is allowed only for an unmistakably missing endpoint,
/// before a successful stream is accepted. Model/auth/rate and midstream
/// failures are never evidence that a different protocol should be replayed.
enum RemoteResponsesCapabilityFallback {
    static func isUnsupportedEndpoint(status: Int, body: Data, endpoint: URL?) -> Bool {
        guard [400, 404, 405, 501].contains(status), endpoint?.path.hasSuffix("/responses") == true else { return false }
        let text = String(decoding: body, as: UTF8.self).lowercased()
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let code = (error?["code"] as? String ?? root?["code"] as? String ?? "").lowercased()
        let parameter = (error?["param"] as? String ?? "").lowercased()
        if parameter == "model" || text.contains("model_not_found") || text.contains("invalid_api_key") { return false }
        if ["unsupported_endpoint", "endpoint_not_found", "route_not_found"].contains(code) { return true }
        return ["cannot post /responses", "cannot post /v1/responses", "unknown endpoint /responses",
            "unknown endpoint: /responses", "unsupported endpoint /responses", "unsupported endpoint: /responses",
            "/responses is not supported", "responses endpoint is not supported", "route /v1/responses not found"]
            .contains { text.contains($0) }
    }

    static func validatePortableOptions(_ options: ResponsesProviderOptions?, providerType: RemoteProviderType = .openaiLegacy) throws {
        guard let options else { return }
        var unsupported = options.unsupportedPortableTools.map { "tool:\($0)" }
        if options.store == true { unsupported.append("store:true") }
        if options.include?.isEmpty == false { unsupported.append("include") }
        if options.reasoning?.summary != nil { unsupported.append("reasoning.summary") }
        if options.reasoning?.context != nil { unsupported.append("reasoning.context") }
        if providerType != .openaiLegacy && providerType != .azureOpenAI {
            if options.parallelToolCalls != nil { unsupported.append("parallel_tool_calls") }
            if options.metadata != nil { unsupported.append("metadata") }
            if options.text != nil { unsupported.append("text.format") }
        }
        guard unsupported.isEmpty else {
            throw RemoteProviderServiceError.unsupportedParameter(
                "This provider's compatibility protocol cannot represent Responses options: \(unsupported.joined(separator: ", ")). Use a Responses-capable provider."
            )
        }
    }

    static func portableChoice(_ choice: OpenResponsesToolChoice) -> ToolChoiceOption {
        switch choice {
        case .auto: return .auto
        case .none: return .none
        case .required: return .required
        case .function(let name): return .function(.init(type: "function", function: .init(name: name)))
        }
    }
}
