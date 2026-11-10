//
//  BindingTypeResolver.swift
//  osaurus
//
//  What a `{{...}}` reference points at, read from the schemas before the
//  run: an input field's schema, or a step's output schema walked along
//  the path (`images.0.path` steps into `images`, its items, then `path`).
//  Used to catch a media step's `sources` bound to a number or a video,
//  and to tint the graph's edges by what flows along them.
//

import Foundation

enum BindingTypeResolver {

    /// The kind of value a reference resolves to, as far as the schemas say.
    enum ValueType: String, Equatable, Sendable {
        case image, video, file, folder, string, number, integer, boolean, array, object
        /// A list of images (a media step's `images`), usable as sources.
        case imageList
        case videoList
        /// The schema does not say (a tool's open output, an `{}` schema).
        case unknown

        /// Whether a media step's `sources` can take it.
        var canFeedImageSource: Bool {
            switch self {
            case .image, .imageList, .file, .string, .array, .object, .unknown: return true
            case .video, .videoList, .folder, .number, .integer, .boolean: return false
            }
        }

        var isMedia: Bool { self == .image || self == .video || self == .imageList || self == .videoList }
    }

    /// The type of a single-reference template (`{{nodes.gen.output.images}}`),
    /// or `.string` for text with words around the reference.
    static func type(ofTemplate template: String, in def: WorkflowDefinition) -> ValueType {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = BindingRenderer.references(in: trimmed)
        guard refs.count == 1, trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}") else { return .string }
        return type(ofReference: refs[0], in: def)
    }

    static func type(ofReference ref: String, in def: WorkflowDefinition) -> ValueType {
        switch BindingRenderer.parse(reference: ref) {
        case .input(let path)?:
            return schema(at: path, in: def.inputSchema).map(type(of:)) ?? .unknown
        case .node(let id, let path)?:
            guard let node = def.node(id) else { return .unknown }
            return schema(at: path, in: node.effectiveOutputSchema).map(type(of:)) ?? .unknown
        case .folder?:
            return .folder
        case .index?:
            return .integer
        case .run?, .caller?:
            return .string
        case .item?, nil:
            return .unknown
        }
    }

    /// The sub-schema at a dotted path: object segments step into
    /// `properties`, numeric segments into `items`. Nil when the schema
    /// does not describe that path.
    static func schema(at path: String, in schema: JSONValue) -> JSONValue? {
        var current = schema
        for segment in path.split(separator: ".").map(String.init) where !segment.isEmpty {
            guard case .object(let o) = current else { return nil }
            if Int(segment) != nil, let items = o["items"] {
                current = items
            } else if case .object(let props)? = o["properties"], let next = props[segment] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }

    static func type(of schema: JSONValue) -> ValueType {
        guard case .object(let o) = schema else { return .unknown }
        let format = o["format"]?.stringValue
        switch o["type"]?.stringValue {
        case "string":
            switch format {
            case "image": return .image
            case "video": return .video
            case "file": return .file
            case "folder": return .folder
            default: return .string
            }
        case "number": return .number
        case "integer": return .integer
        case "boolean": return .boolean
        case "array":
            if let items = o["items"], case .object(let item) = items {
                if let path = (item["properties"]?.objectValue)?["path"] {
                    switch type(of: path) {
                    case .image: return .imageList
                    case .video: return .videoList
                    default: break
                    }
                }
                switch type(of: items) {
                case .image: return .imageList
                case .video: return .videoList
                default: break
                }
            }
            return .array
        case "object": return o["properties"] == nil ? .unknown : .object
        default: return .unknown
        }
    }

    /// What flows along an edge, for tinting: the media type of the
    /// parent's output when the child binds into it, else nil.
    static func edgeType(from parent: WorkflowNode, to child: WorkflowNode, in def: WorkflowDefinition) -> ValueType? {
        guard case .media(let spec) = parent.kind else { return nil }
        let refs = templates(of: child).flatMap(BindingRenderer.references(in:))
        let bindsParent = refs.contains { ref in
            if case .node(let id, _)? = BindingRenderer.parse(reference: ref) { return id == parent.id }
            return false
        }
        guard bindsParent else { return nil }
        return spec.action.makesVideo ? .video : .image
    }

    /// The template strings a node renders.
    static func templates(of node: WorkflowNode) -> [String] {
        var out: [String]
        switch node.input {
        case .template(let t): out = [t]
        case .object, .values: out = Array((node.input.fieldTemplates ?? [:]).values)
        }
        switch node.kind {
        case .media(let spec): out += spec.templates
        case .reply(let spec): out += [spec.text, spec.file ?? "", spec.caption ?? ""]
        case .map(let spec): out.append(spec.items)
        case .inference(let spec): out.append(spec.instructions)
        default: break
        }
        return out
    }
}
