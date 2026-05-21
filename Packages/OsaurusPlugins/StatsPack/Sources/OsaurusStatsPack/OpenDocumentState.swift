//
//  OpenDocumentState.swift
//  OsaurusStatsPack
//

import Foundation
import OsaurusCore

final class OpenDocumentState: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (url: URL, reference: DocumentReference)?

    func update(url: URL, reference: DocumentReference) {
        lock.lock()
        state = (url, reference)
        lock.unlock()
    }

    func openedDocument() -> (url: URL, reference: DocumentReference)? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
