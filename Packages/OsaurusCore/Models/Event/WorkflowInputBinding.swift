//
//  WorkflowInputBinding.swift
//  osaurus
//
//  How an automation fills a workflow's inputs. Storage stays
//  `WorkflowEventAction.inputMapping` (input key -> `{{path}}` template);
//  this reads one entry as a choice a person makes (a trigger value, a
//  custom template, or a fixed value), prefills a new mapping, previews
//  the input a sample occurrence produces, and finds required inputs that
//  would fail at run time.
//

import Foundation

enum WorkflowInputBinding {
    enum Kind: Equatable, Sendable {
        /// Nothing bound: the workflow sees no value.
        case unset
        /// Exactly one trigger value, e.g. `{{webhook.body.issue.title}}`.
        case triggerValue(String)
        /// Text mixing bindings, e.g. `New issue: {{webhook.body.title}}`.
        case template
        /// Plain text, sent as written (coerced to the input's type).
        case fixed
    }

    static func kind(of template: String?) -> Kind {
        let trimmed = template?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return .unset }
        if let path = EventTemplate.singleBinding(trimmed), EventTemplate.isPayloadPath(path) {
            return .triggerValue(path)
        }
        return EventTemplate.references(in: trimmed).contains(where: EventTemplate.isPayloadPath) ? .template : .fixed
    }

    /// Required inputs that declare a default, as fixed values. The
    /// executor applies no defaults, so a binding carries them.
    static func requiredDefaults(schema: JSONValue) -> [String: String] {
        let properties = schema.value(atPath: "properties")?.objectValue ?? [:]
        let required = (schema.value(atPath: "required")?.arrayValue ?? []).compactMap(\.stringValue)
        var mapping: [String: String] = [:]
        for key in required {
            if let value = properties[key]?.value(atPath: "default"), value != .null {
                mapping[key] = EventTemplate.text(of: value)
            }
        }
        return mapping
    }

    /// A starting mapping when a workflow is chosen: the trigger's natural
    /// value for fields named like it, `{{text}}` for the first other text
    /// field, and each remaining required field's schema default as a
    /// fixed value.
    static func prefill(schema: JSONValue, sourceKind: EventSourceKind) -> [String: String] {
        let required = (schema.value(atPath: "required")?.arrayValue ?? []).compactMap(\.stringValue)
        // A required input with a default keeps it; the trigger's values go
        // to the rest.
        let mapping = requiredDefaults(schema: schema)
        let remaining = required.filter { mapping[$0] == nil }
        guard required.isEmpty || !remaining.isEmpty, var object = schema.objectValue else { return mapping }
        if !required.isEmpty { object["required"] = .array(remaining.map(JSONValue.string)) }
        let suggested = WorkflowInputMapper.suggestedMapping(schema: .object(object), sourceKind: sourceKind)
        return mapping.merging(suggested) { kept, _ in kept }
    }

    /// Required inputs with nothing bound. The executor validates the
    /// input against the schema, so each of these fails every run.
    static func missingRequired(fields: [DialogField], mapping: [String: String]) -> [DialogField] {
        fields.filter { field in
            field.required && kind(of: mapping[field.key]) == .unset
        }
    }

    /// The value `field` gets from `payload`, as text for the preview.
    static func preview(field: String, mapping: [String: String], payload: JSONValue, schema: JSONValue) -> String? {
        guard let template = mapping[field], kind(of: template) != .unset else { return nil }
        let input = WorkflowInputMapper.input(mapping: [field: template], payload: payload, schema: schema)
        guard let value = input.value(atPath: field) else { return nil }
        switch value {
        case .string(let s): return s
        case .null: return ""
        default: return value.compactJSONString
        }
    }

    /// Schema problems for the whole input a sample produces, as text.
    static func issues(mapping: [String: String], payload: JSONValue, schema: JSONValue) -> [String] {
        let input = WorkflowInputMapper.input(mapping: mapping, payload: payload, schema: schema)
        return JSONSchemaValidator.validate(input, against: schema).map(\.description)
    }
}
