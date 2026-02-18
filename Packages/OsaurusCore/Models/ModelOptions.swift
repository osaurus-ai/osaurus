//
//  ModelOptions.swift
//  osaurus
//
//  Registry-based model options system. Each ModelProfile declares the options
//  a family of models supports; the UI renders them dynamically and the values
//  flow through to the request builder.
//

import Foundation

// MARK: - Option Value

enum ModelOptionValue: Sendable, Equatable, Hashable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

// MARK: - Option Definition

struct ModelOptionSegment: Identifiable, Sendable {
    let id: String
    let label: String
}

struct ModelOptionDefinition: Identifiable, Sendable {
    enum Kind: Sendable {
        case segmented([ModelOptionSegment])
        case toggle(default: Bool)
    }

    let id: String
    let label: String
    let icon: String?
    let kind: Kind

    init(id: String, label: String, icon: String? = nil, kind: Kind) {
        self.id = id
        self.label = label
        self.icon = icon
        self.kind = kind
    }
}

// MARK: - Model Profile Protocol

protocol ModelProfile: Sendable {
    static func matches(modelId: String) -> Bool
    static var displayName: String { get }
    static var options: [ModelOptionDefinition] { get }
    static var defaults: [String: ModelOptionValue] { get }
}

// MARK: - Registry

enum ModelProfileRegistry {
    static let profiles: [any ModelProfile.Type] = [
        GeminiImageProfile.self
    ]

    static func profile(for modelId: String) -> (any ModelProfile.Type)? {
        profiles.first { $0.matches(modelId: modelId) }
    }

    static func defaults(for modelId: String) -> [String: ModelOptionValue] {
        profile(for: modelId)?.defaults ?? [:]
    }

    static func options(for modelId: String) -> [ModelOptionDefinition] {
        profile(for: modelId)?.options ?? []
    }
}

// MARK: - Gemini Image Profile

struct GeminiImageProfile: ModelProfile {
    static let displayName = "Image Generation"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("image") || lower.contains("nano-banana")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "aspectRatio",
            label: "Aspect Ratio",
            icon: "aspectratio",
            kind: .segmented([
                ModelOptionSegment(id: "auto", label: "Auto"),
                ModelOptionSegment(id: "1:1", label: "1:1"),
                ModelOptionSegment(id: "3:4", label: "3:4"),
                ModelOptionSegment(id: "4:3", label: "4:3"),
                ModelOptionSegment(id: "9:16", label: "9:16"),
                ModelOptionSegment(id: "16:9", label: "16:9"),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "aspectRatio": .string("auto")
    ]
}
