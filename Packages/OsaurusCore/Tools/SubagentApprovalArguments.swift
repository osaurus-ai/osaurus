//
//  SubagentApprovalArguments.swift
//  osaurus
//
//  Small helpers for showing resolved delegate-job facts in permission prompts.
//

import Foundation

enum SubagentApprovalArguments {
    static func enrichedJSON(from argumentsJSON: String, values: [String: Any]) -> String {
        var payload = parseObject(argumentsJSON) ?? [:]
        for (key, value) in values {
            payload[key] = value
        }
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical),
            let json = String(data: data, encoding: .utf8)
        else {
            return argumentsJSON
        }
        return json
    }

    private static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
