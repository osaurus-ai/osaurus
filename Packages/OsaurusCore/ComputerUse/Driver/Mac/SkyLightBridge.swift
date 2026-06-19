//
//  SkyLightBridge.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  Lazily resolves the private SkyLight / HIServices entry points used for
//  backgrounded (no cursor-warp) input routing. Degrades gracefully when the
//  symbols are unavailable (older/newer macOS, sandboxed host).
//

import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - Process Serial Number
//
// Apple deprecated `ProcessSerialNumber` years ago, but every private
// SkyLight/HIServices entry point we need still expects one. We redeclare
// the layout here so we never have to import the deprecated header.

struct PSN {
    var highLong: UInt32
    var lowLong: UInt32

    static let zero = PSN(highLong: 0, lowLong: 0)
}

// MARK: - Symbol Table
//
// All private functions are resolved lazily via `dlopen`/`dlsym`. We never
// link against the private framework directly, so:
//   1. Code-signing for downstream embedders is unaffected.
//   2. If Apple removes a symbol in a future macOS, we degrade to the HID-tap
//      fallback instead of failing at launch.
//
// `@convention(c)` rejects Swift struct pointers in its signatures because
// they're not Objective-C-representable. We use opaque raw pointers in the
// function-pointer typealiases and rebind to `PSN` at the call site instead.

// Real signature is `CGError SLEventPostToPid(pid_t pid, CGEventRef event)`
// — pid FIRST, event second, same as the public `CGEvent.postToPid`. Passing
// them in the other order makes SkyLight dereference the pid value as the
// event pointer and crashes with EXC_BAD_ACCESS at a tiny address.
private typealias SLEventPostToPidFn = @convention(c) (pid_t, CGEvent) -> Int32

private typealias SLPSPostEventRecordToFn =
    @convention(c) (
        UnsafeRawPointer, UnsafePointer<UInt8>
    ) -> Int32

private typealias SLPSGetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

/// Lazy-loaded pointers to the private SkyLight / HIServices entry points
/// that the background-driver recipe depends on.
///
/// First access does the `dlopen`. Subsequent calls hit the cached pointers.
/// `isAvailable` short-circuits callers when the host OS doesn't expose
/// what we need (older / newer macOS versions, sandboxed processes that
/// can't see the private framework, etc).
enum SkyLightBridge {

    // The dyld shared cache makes the on-disk file invisible, but `dlopen`
    // resolves these names through the cache fine.
    private static let skyLightPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let hiServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

    private static let symbols: ResolvedSymbols = ResolvedSymbols.load()

    static var isAvailable: Bool { symbols.eventPostToPid != nil }
    static var canFocusWithoutRaise: Bool {
        symbols.postEventRecordTo != nil && symbols.getFrontProcess != nil
            && symbols.getProcessForPID != nil
    }

    // MARK: - Public wrappers

    /// Post a synthesized `CGEvent` directly to a target pid via SkyLight's
    /// auth-signed channel. This bypasses `IOHIDPostEvent`, so the user's
    /// cursor never moves and Chromium-class renderers accept the event.
    ///
    /// Returns `true` when the bridge is available and the call succeeded.
    /// Callers must treat `false` as "fall back to a different transport".
    @discardableResult
    static func postEvent(_ event: CGEvent, toPid pid: pid_t) -> Bool {
        guard let fn = symbols.eventPostToPid else { return false }
        // Same WindowServer-knowability guard as processSerialNumber. Avoids
        // segfaults inside the private function when targeting a CLI process.
        guard isWindowServerVisible(pid: pid) else { return false }
        // SLEventPostToPid does NOT use the CGError "0 == success" convention: it
        // returns a non-zero status (observed 0xB0000000 / -1342177280) when it
        // accepts and delivers the event. Gating success on `== 0` made this
        // ALWAYS report failure, so `BackgroundDriver.route` treated SkyLight as a
        // miss and *also* posted the same event via `CGEvent.postToPid` — every
        // keystroke and click was delivered twice (the Chrome-omnibox / TextEdit
        // "abb" doubling). A completed call to a window-server-visible pid IS the
        // delivery, so report success and let `route` stop there.
        let rc = fn(pid, event)
        InputDebug.log("SLEventPostToPid pid=\(pid) rc=\(rc) (non-zero is success) -> delivered")
        return true
    }

    /// True when the pid corresponds to a GUI app the WindowServer can
    /// route synthesized events to. Background-only and CLI processes
    /// fail this gate.
    static func isWindowServerVisible(pid: pid_t) -> Bool {
        if kill(pid, 0) != 0 { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activationPolicy != .prohibited
    }

    /// Read the PSN of whichever process is currently AppKit-frontmost.
    /// Used as the "source" record in the focus-without-raise pair.
    static func currentFrontProcess() -> PSN? {
        guard let fn = symbols.getFrontProcess else { return nil }
        var psn = PSN.zero
        let status = withUnsafeMutablePointer(to: &psn) { ptr -> Int32 in
            fn(UnsafeMutableRawPointer(ptr))
        }
        return status == 0 ? psn : nil
    }

    /// Resolve a `pid_t` to its `PSN`. Required to address the target side
    /// of the focus-without-raise event pair. `GetProcessForPID` is a
    /// long-deprecated Carbon entry point but it still works at runtime.
    ///
    /// Returns `nil` for pids that don't correspond to a running process —
    /// some macOS versions segfault inside the private function when handed
    /// a non-existent pid, so we gate the call on `kill(pid, 0)`.
    static func processSerialNumber(forPid pid: pid_t) -> PSN? {
        guard let fn = symbols.getProcessForPID else { return nil }
        if kill(pid, 0) != 0 { return nil }
        // GetProcessForPID is only safe for pids that the WindowServer knows
        // about (i.e. real GUI apps). Calling it for a CLI process or an LSUI
        // background-only process has been observed to segfault. Filter via
        // NSRunningApplication first.
        guard let app = NSRunningApplication(processIdentifier: pid),
            app.activationPolicy != .prohibited
        else {
            return nil
        }
        var psn = PSN.zero
        let status = withUnsafeMutablePointer(to: &psn) { ptr -> Int32 in
            fn(pid, UnsafeMutableRawPointer(ptr))
        }
        return status == 0 ? psn : nil
    }

    /// yabai's focus-without-raise pattern.
    ///
    /// Sends two `_SLPSPostEventRecordTo` payloads (subtype `0x01` to the
    /// previously-frontmost process, `0x02` to the target) so the target
    /// becomes AppKit-active for input routing without `SLPSSetFrontProcess`
    /// pulling its window forward or dragging Spaces along.
    ///
    /// No-op (returns `false`) when any of the symbols are missing or the
    /// PSN lookup fails. Callers should treat `false` as "best-effort, the
    /// SkyLight click will still be tried".
    @discardableResult
    static func focusWithoutRaise(pid: pid_t) -> Bool {
        guard let post = symbols.postEventRecordTo,
            let frontPSN = currentFrontProcess(),
            let targetPSN = processSerialNumber(forPid: pid)
        else { return false }

        // 248-byte event record matching yabai's window_manager_focus_window_without_raise.
        // Only the bytes yabai sets explicitly need to be non-zero; the buffer
        // is otherwise zeroed.
        var bytes1 = [UInt8](repeating: 0, count: 0xF8)
        var bytes2 = [UInt8](repeating: 0, count: 0xF8)
        bytes1[0x04] = 0xF8
        bytes1[0x08] = 0x01
        bytes1[0x3A] = 0x10
        bytes2[0x04] = 0xF8
        bytes2[0x08] = 0x02
        bytes2[0x3A] = 0x10
        // yabai also sets bytes[0x20..<0x30] = 0xFF when targeting a specific
        // window id. We don't know windowId here, so leave the slot zero —
        // that addresses "the app" rather than a specific window, which is
        // exactly what we want when the agent is just routing input.

        var fronts = frontPSN
        var targets = targetPSN
        let s1 = bytes1.withUnsafeBufferPointer { buf -> Int32 in
            withUnsafePointer(to: &fronts) { psnPtr -> Int32 in
                post(UnsafeRawPointer(psnPtr), buf.baseAddress!)
            }
        }
        // 20ms gap between records, matching yabai. WindowServer occasionally
        // drops the second record if they arrive in the same tick.
        usleep(20_000)
        let s2 = bytes2.withUnsafeBufferPointer { buf -> Int32 in
            withUnsafePointer(to: &targets) { psnPtr -> Int32 in
                post(UnsafeRawPointer(psnPtr), buf.baseAddress!)
            }
        }
        return s1 == 0 && s2 == 0
    }

    // MARK: - Symbol loader

    /// Resolves all SkyLight/HIServices entry points once at first use.
    /// Stored as a value type so we can keep it `let` and avoid locks.
    private struct ResolvedSymbols {
        let eventPostToPid: SLEventPostToPidFn?
        let postEventRecordTo: SLPSPostEventRecordToFn?
        let getFrontProcess: SLPSGetFrontProcessFn?
        let getProcessForPID: GetProcessForPIDFn?
        let hasObserverRemoteSymbol: Bool

        static func load() -> ResolvedSymbols {
            let skyHandle = dlopen(SkyLightBridge.skyLightPath, RTLD_LAZY)
            let hiHandle = dlopen(SkyLightBridge.hiServicesPath, RTLD_LAZY)

            func loadFn<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
                guard let handle = handle, let raw = dlsym(handle, name) else { return nil }
                return unsafeBitCast(raw, to: type)
            }

            // Both HIServices (Carbon-era ProcessManager) and SkyLight expose
            // these — try whichever is around. The `_`-prefixed variant is the
            // one yabai uses on modern macOS.
            let frontFn: SLPSGetFrontProcessFn? =
                loadFn(skyHandle, "_SLPSGetFrontProcess", as: SLPSGetFrontProcessFn.self)
                ?? loadFn(skyHandle, "SLPSGetFrontProcess", as: SLPSGetFrontProcessFn.self)

            // GetProcessForPID lives in HIServices/HIToolbox but the dyld shared
            // cache surfaces it through pretty much any Application-Services
            // descendant; try a couple of fallbacks before giving up.
            let pidFn: GetProcessForPIDFn? =
                loadFn(hiHandle, "GetProcessForPID", as: GetProcessForPIDFn.self)
                ?? loadFn(skyHandle, "GetProcessForPID", as: GetProcessForPIDFn.self)
                ?? loadFn(nil, "GetProcessForPID", as: GetProcessForPIDFn.self)

            // Probe (don't bind) for the Electron-AX-remote symbol so callers
            // can decide whether to expose `subscribe_to_app`-style tools later.
            let hasRemote =
                dlsym(hiHandle, "_AXObserverAddNotificationAndCheckRemote") != nil
                || dlsym(nil, "_AXObserverAddNotificationAndCheckRemote") != nil

            return ResolvedSymbols(
                eventPostToPid: loadFn(skyHandle, "SLEventPostToPid", as: SLEventPostToPidFn.self),
                postEventRecordTo: loadFn(
                    skyHandle,
                    "SLPSPostEventRecordTo",
                    as: SLPSPostEventRecordToFn.self
                )
                    ?? loadFn(skyHandle, "_SLPSPostEventRecordTo", as: SLPSPostEventRecordToFn.self),
                getFrontProcess: frontFn,
                getProcessForPID: pidFn,
                hasObserverRemoteSymbol: hasRemote
            )
        }
    }
}
