//
//  SpanBuilder.swift
//  osaurus / PrivacyFilter (vendored)
//
//  Vendored from https://github.com/kokluch/privacy-filter-swift
//  @ 2bb396cce542155e1923fff1e08520348f1af1c5.
//

import Foundation

/// Maps BIOES label sequence + token offsets back to entities in the original string.
enum SpanBuilder {
    static func entities(
        labelIds: [Int],
        labels: BIOESLabelTable,
        offsets: [TokenOffset],
        text: String
    ) -> [Entity] {
        // The model truncates inputs longer than its position-embedding
        // cap, so the decoder can return fewer labels than the tokenizer
        // produced offsets. Walk the common prefix instead of trapping —
        // tokens beyond the cap were never classified, so they cannot
        // yield entities.
        let count = min(labelIds.count, offsets.count)
        var result: [Entity] = []
        var openStart: Int? = nil
        var openEntity: EntityType? = nil

        func emit(start: Int, end: Int, entity: EntityType) {
            guard let startIndex = text.utf8Index(at: start),
                let endIndex = text.utf8Index(at: end)
            else { return }
            let span = String(text[startIndex ..< endIndex])
            let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.append(Entity(type: entity, text: trimmed, range: startIndex ..< endIndex))
        }

        for i in 0 ..< count {
            let label = labels[labelIds[i]]
            let offset = offsets[i]
            switch label.boundary {
            case .single:
                if let entity = label.entity {
                    emit(start: offset.utf8Start, end: offset.utf8End, entity: entity)
                }
                openStart = nil
                openEntity = nil
            case .begin:
                openStart = offset.utf8Start
                openEntity = label.entity
            case .inside:
                if openEntity == nil {
                    openStart = offset.utf8Start
                    openEntity = label.entity
                }
            case .end:
                if let start = openStart, let entity = openEntity {
                    emit(start: start, end: offset.utf8End, entity: entity)
                }
                openStart = nil
                openEntity = nil
            case .outside:
                openStart = nil
                openEntity = nil
            }
        }
        return result
    }
}

private extension String {
    func utf8Index(at utf8Offset: Int) -> String.Index? {
        let utf8 = self.utf8
        guard utf8Offset >= 0, utf8Offset <= utf8.count else { return nil }
        return utf8.index(utf8.startIndex, offsetBy: utf8Offset).samePosition(in: self)
    }
}
