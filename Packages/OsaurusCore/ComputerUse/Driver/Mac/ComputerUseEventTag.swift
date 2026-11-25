//
//  ComputerUseEventTag.swift
//  OsaurusCore — Computer Use
//
//  Marks every event the driver synthesizes so the takeover keyboard guard can
//  tell them from the user's own keystrokes.
//

import CoreGraphics

enum ComputerUseEventTag {
    static let value: Int64 = 0x4F53_4155_4355

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    static func isSynthesized(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == value
    }
}

extension CGEvent {
    func postTagged(tap: CGEventTapLocation) {
        ComputerUseEventTag.mark(self)
        post(tap: tap)
    }
}
