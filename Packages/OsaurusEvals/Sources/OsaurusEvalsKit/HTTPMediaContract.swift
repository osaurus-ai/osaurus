import Foundation

/// Assertions shared by live image/video rows and adversarial regression tests.
/// A successful HTTP envelope alone is not proof that pixels were consumed.
enum HTTPMediaContract {
    static func exactColor(_ answer: String, expected: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!\"'`*"))
            .lowercased() == expected
    }

    static func maySkipUnsupported(status: Int, errorType: String?,
                                   installedSupportsMedia: Bool?, required: Bool) -> Bool {
        !required && installedSupportsMedia == false
            && status == 400 && errorType == "invalid_request_error"
    }

    static func terminalProblems(_ json: [String: Any]?) -> [String] {
        var problems: [String] = []
        let choices = json?["choices"] as? [[String: Any]]
        let choice = choices?.first
        let message = choice?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        if choices?.count != 1 { problems.append("expected exactly one choice") }
        if choice?["finish_reason"] as? String != "stop" { problems.append("generation did not stop normally") }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("visible answer missing")
        }
        if ["<think>", "</think>", "<|im_start|>", "<|im_end|>", "<|vision_start|>"].contains(where: content.contains) {
            problems.append("protocol marker leaked into visible answer")
        }
        let usage = json?["usage"] as? [String: Any]
        let rate = (usage?["tokens_per_second"] as? NSNumber)?.doubleValue ?? 0
        if !rate.isFinite || rate <= 0 { problems.append("measured token/s missing") }
        return problems
    }
}
