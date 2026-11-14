//
//  CloudModelCategory.swift
//  osaurus
//
//  Catalog-backed tasks for the Cloud browser. A model can support more than
//  one task, so vision chat models belong to both text and image input groups.
//

import Foundation

enum CloudModelCategory: CaseIterable, Identifiable, Hashable {
    case all
    case textToText
    case imageToText
    case image
    case textToVideo
    case imageToVideo

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All"
        case .textToText: return "Text-to-text"
        case .imageToText: return "Image-to-text"
        case .image: return "Image"
        case .textToVideo: return "Text-to-video"
        case .imageToVideo: return "Image-to-video"
        }
    }

    func includes(_ model: ModelPickerItem) -> Bool {
        switch self {
        case .all:
            return true
        case .textToText:
            return model.isLikelyChatCapable
        case .imageToText:
            return model.isLikelyChatCapable && model.isVLM
        case .image:
            // Cloud image metadata does not distinguish generation from
            // editing. Keep its broad category instead of guessing by name.
            return model.mediaModel?.kind == .image
        case .textToVideo:
            return model.mediaModel?.kind == .textToVideo
        case .imageToVideo:
            return model.mediaModel?.kind == .imageToVideo
        }
    }

    /// The row shows the most specific task; multimodal chat remains available
    /// through both input categories when filtering.
    static func displayCategory(for model: ModelPickerItem) -> Self? {
        if let kind = model.mediaModel?.kind {
            switch kind {
            case .image: return .image
            case .textToVideo: return .textToVideo
            case .imageToVideo: return .imageToVideo
            }
        }
        guard model.isLikelyChatCapable else { return nil }
        return model.isVLM ? .imageToText : .textToText
    }

    static func available(in models: [ModelPickerItem]) -> [Self] {
        allCases.filter { category in
            category == .all || models.contains(where: category.includes)
        }
    }
}
