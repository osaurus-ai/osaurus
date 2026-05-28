//
//  PresentationDocument.swift
//  osaurus
//
//  Typed read model for presentation files. It intentionally records only
//  text-bearing slide content today so PPTX/POTX ingestion can preserve
//  source identity without pretending to understand the full OOXML layout
//  graph.
//

import Foundation

/// Distinguishes decks from templates while keeping both on one typed
/// representation; OpenXML templates share the same slide package layout.
public enum PresentationDocumentKind: String, Codable, Equatable, Sendable {
    case presentation
    case template
}

/// Format-native representation for presentation reads that downstream tools
/// can inspect before higher-fidelity media, layout, and chart support lands.
public struct PresentationDocument: StructuredRepresentation, Codable, Equatable, Sendable {
    public let kind: PresentationDocumentKind
    public let sourceName: String
    public let slides: [PresentationSlide]

    public init(
        kind: PresentationDocumentKind,
        sourceName: String,
        slides: [PresentationSlide]
    ) {
        self.kind = kind
        self.sourceName = sourceName
        self.slides = slides
    }
}

/// A slide preserves both user-facing order (`index`) and source numbering
/// (`number`) because OpenXML slide filenames are not guaranteed contiguous.
public struct PresentationSlide: Codable, Equatable, Sendable {
    public let index: Int
    public let number: Int
    public let sourcePart: String
    public let label: String
    public let isHidden: Bool
    public let textRuns: [PresentationTextRun]
    public let speakerNotes: PresentationSpeakerNotes?

    public var text: String {
        PresentationTextRun.paragraphText(from: textRuns)
    }

    public init(
        index: Int,
        number: Int,
        sourcePart: String,
        label: String,
        isHidden: Bool = false,
        textRuns: [PresentationTextRun],
        speakerNotes: PresentationSpeakerNotes? = nil
    ) {
        precondition(index >= 0, "Presentation slide index must be non-negative")
        precondition(number > 0, "Presentation slide number must be positive")
        self.index = index
        self.number = number
        self.sourcePart = sourcePart
        self.label = label
        self.isHidden = isHidden
        self.textRuns = textRuns
        self.speakerNotes = speakerNotes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            index: container.decode(Int.self, forKey: .index),
            number: container.decode(Int.self, forKey: .number),
            sourcePart: container.decode(String.self, forKey: .sourcePart),
            label: container.decode(String.self, forKey: .label),
            isHidden: container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
            textRuns: container.decode([PresentationTextRun].self, forKey: .textRuns),
            speakerNotes: container.decodeIfPresent(PresentationSpeakerNotes.self, forKey: .speakerNotes)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case number
        case sourcePart
        case label
        case isHidden
        case textRuns
        case speakerNotes
    }
}

/// Run-level text keeps paragraph/run coordinates available for later rich
/// conversion while the current fallback still flattens to paragraph text.
public struct PresentationTextRun: Codable, Equatable, Sendable {
    public let text: String
    public let paragraphIndex: Int
    public let runIndex: Int
    public let sourcePart: String
    public let anchorId: String

    public init(
        text: String,
        paragraphIndex: Int,
        runIndex: Int,
        sourcePart: String,
        anchorId: String
    ) {
        precondition(paragraphIndex >= 0, "Presentation paragraph index must be non-negative")
        precondition(runIndex >= 0, "Presentation run index must be non-negative")
        self.text = text
        self.paragraphIndex = paragraphIndex
        self.runIndex = runIndex
        self.sourcePart = sourcePart
        self.anchorId = anchorId
    }

    public static func paragraphText(from runs: [PresentationTextRun]) -> String {
        var paragraphs: [Int: String] = [:]
        for run in runs.sorted(by: { ($0.paragraphIndex, $0.runIndex) < ($1.paragraphIndex, $1.runIndex) }) {
            paragraphs[run.paragraphIndex, default: ""].append(run.text)
        }
        return paragraphs.keys.sorted()
            .compactMap { paragraphs[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Speaker notes are modelled separately because they are attached to a slide
/// but live in a distinct OOXML part with a distinct source anchor.
public struct PresentationSpeakerNotes: Codable, Equatable, Sendable {
    public let sourcePart: String
    public let anchorId: String
    public let textRuns: [PresentationTextRun]

    public var text: String {
        PresentationTextRun.paragraphText(from: textRuns)
    }

    public init(
        sourcePart: String,
        anchorId: String,
        textRuns: [PresentationTextRun]
    ) {
        self.sourcePart = sourcePart
        self.anchorId = anchorId
        self.textRuns = textRuns
    }
}
