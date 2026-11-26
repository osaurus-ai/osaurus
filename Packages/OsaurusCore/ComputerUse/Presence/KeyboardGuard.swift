//
//  KeyboardGuard.swift
//  OsaurusCore — Computer Use
//
//  A session event tap that, while the app being driven is frontmost, drops
//  the user's keystrokes to it and turns Esc into Stop. Events the driver
//  synthesizes carry `ComputerUseEventTag` and always pass. Keys typed into
//  any other app are untouched.
//

import AppKit
import CoreGraphics

@MainActor
final class KeyboardGuard {
    nonisolated static let escapeKeyCode: Int64 = 53

    /// What the tap does with one keyboard event.
    enum Disposition: Equatable {
        case pass
        case drop
        case stop
    }

    /// Pure decision so the policy is testable without a live tap.
    nonisolated static func disposition(
        isSynthesized: Bool,
        targetIsFrontmost: Bool,
        isKeyDown: Bool,
        keyCode: Int64
    ) -> Disposition {
        if isSynthesized || !targetIsFrontmost { return .pass }
        if keyCode == escapeKeyCode { return isKeyDown ? .stop : .drop }
        return .drop
    }

    var targetPid: Int32?
    private let onEscape: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var frontmostPid: Int32?
    private var activationObserver: NSObjectProtocol?

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    var isInstalled: Bool { tap != nil }

    /// Returns false when macOS refuses the tap (Accessibility not granted);
    /// the shield still blocks the mouse.
    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated { self?.frontmostPid = pid }
        }
        let mask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: keyboardGuardCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            ComputerUseTraceLog.note("keyboard guard: event tap refused")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        tap = nil
        source = nil
        activationObserver = nil
    }

    /// True when the event should reach its destination.
    fileprivate func shouldPass(type: CGEventType, isSynthesized: Bool, keyCode: Int64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        let targetIsFrontmost = targetPid != nil && targetPid == frontmostPid
        switch Self.disposition(
            isSynthesized: isSynthesized,
            targetIsFrontmost: targetIsFrontmost,
            isKeyDown: type == .keyDown,
            keyCode: keyCode
        ) {
        case .pass: return true
        case .drop: return false
        case .stop:
            onEscape()
            return false
        }
    }
}

private func keyboardGuardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let guardInstance = Unmanaged<KeyboardGuard>.fromOpaque(userInfo).takeUnretainedValue()
    let isSynthesized = ComputerUseEventTag.isSynthesized(event)
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let pass = MainActor.assumeIsolated {
        guardInstance.shouldPass(type: type, isSynthesized: isSynthesized, keyCode: keyCode)
    }
    return pass ? Unmanaged.passUnretained(event) : nil
}
