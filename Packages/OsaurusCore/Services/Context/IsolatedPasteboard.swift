//
//  IsolatedPasteboard.swift
//  osaurus
//
//  A pasteboard reader that owns its OWN connection to the pasteboard
//  server, for code that must read the clipboard off the main thread.
//
//  `NSPasteboard.general` is one process-wide object with an unsynchronized
//  type cache. AppKit itself reads that object on the main thread all the
//  time — menu validation for Paste, `NSTextView` key handling, Services —
//  so any read of the same object from another thread is a data race no
//  queue on our side can serialize. The race is real: Sentry
//  APPLE-MACOS-1QM (0.23.0 → 0.25.14, three users) is a SIGSEGV inside
//  `-[NSPasteboard _typesAtIndex:combinesItems:]` → fast enumeration over a
//  types array the main thread was replacing, under
//  `ClipboardService.detectContent` on the clipboard queue, and
//  APPLE-MACOS-2N before it was the same cache double-freed. An ObjC
//  exception catcher around the read cannot catch a segfault.
//
//  The Pasteboard Manager API (`PasteboardCreate`) hands out a distinct
//  pasteboard object per call, each with its own item/flavor cache, all
//  kept coherent by the pasteboard server. Reading the clipboard through
//  one of those from the clipboard queue shares no mutable state with
//  AppKit's `NSPasteboard.general`, so the main thread can keep using
//  `NSPasteboard` freely while the poller stays off-main (every pasteboard
//  read is a synchronous XPC round-trip that can block for seconds, which
//  is why the poller left the main thread in the first place).
//
//  Flavors are UTIs and match `NSPasteboard.PasteboardType.rawValue`
//  (`public.utf8-plain-text`, `public.file-url`, `public.png`,
//  `public.tiff`), so callers keep speaking `NSPasteboard` types.
//

import AppKit
import ApplicationServices
import Foundation

/// The subset of pasteboard reads `ClipboardService` performs, so the
/// detection logic can run against either an `IsolatedPasteboard` or a
/// test double.
protocol PasteboardReading {
    /// UTF-8 string for `type` from the first item that carries it.
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    /// Raw bytes for `type` from the first item that carries it.
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

/// One private connection to a named pasteboard. NOT thread-safe itself:
/// confine each instance to one queue (the clipboard poller uses its serial
/// pasteboard queue — that confinement is what the `@unchecked Sendable`
/// relies on). What it is safe against is *other* pasteboard objects for
/// the same name — `NSPasteboard.general` on the main thread included.
final class IsolatedPasteboard: PasteboardReading, @unchecked Sendable {

    private let ref: Pasteboard

    /// Monotonic count of generations observed on this connection. Starts at
    /// 0 and advances by one each time `synchronize()` finds the pasteboard
    /// changed since the previous call; the same role `NSPasteboard.changeCount`
    /// plays for the poller, without touching AppKit's object.
    private(set) var changeCount: Int = 0

    /// `nil` when the pasteboard server refused the connection.
    init?(name: String = kPasteboardClipboard as String) {
        var created: Pasteboard?
        let status = PasteboardCreate(name as CFString, &created)
        guard status == noErr, let created else { return nil }
        ref = created
        // Establish the baseline generation so the first `synchronize()`
        // only reports changes made after this connection existed.
        _ = PasteboardSynchronize(ref)
    }

    /// Pulls the current generation from the server. Returns `true` and
    /// advances `changeCount` when the pasteboard changed since the last
    /// call. Every read below is only as fresh as the last synchronize.
    @discardableResult
    func synchronize() -> Bool {
        let flags = PasteboardSynchronize(ref)
        guard flags.contains(.modified) else { return false }
        changeCount += 1
        return true
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        guard let data = data(forType: type) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        var count = 0
        guard PasteboardGetItemCount(ref, &count) == noErr, count > 0 else { return nil }
        let flavor = type.rawValue as CFString
        for index in 1 ... count {
            var item: PasteboardItemID?
            guard PasteboardGetItemIdentifier(ref, index, &item) == noErr, let item else { continue }
            var flavors: CFArray?
            guard PasteboardCopyItemFlavors(ref, item, &flavors) == noErr,
                let flavors,
                CFArrayContainsValue(
                    flavors, CFRange(location: 0, length: CFArrayGetCount(flavors)),
                    Unmanaged.passUnretained(flavor).toOpaque())
            else { continue }
            var data: CFData?
            guard PasteboardCopyItemFlavorData(ref, item, flavor, &data) == noErr, let data else { continue }
            return data as Data
        }
        return nil
    }
}
