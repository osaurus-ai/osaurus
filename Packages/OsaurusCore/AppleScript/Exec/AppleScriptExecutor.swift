//
//  AppleScriptExecutor.swift
//  OsaurusCore — AppleScript Computer Use
//
//  In-process `NSAppleScript` execution with a hard timeout watchdog. Running
//  the script in-process (rather than shelling out to `osascript`) is
//  deliberate: macOS attributes the resulting Automation / Apple Events
//  permission prompts to "Osaurus", so the first `tell application …` triggers
//  the OS consent dialog for THIS app and subsequent runs are governed by the
//  user's choice in System Settings → Privacy & Security → Automation. This
//  mirrors the existing in-process probes in `SystemPermissionService`.
//
//  `executeAndReturnError` is synchronous and can block (a long script, an app
//  that never replies, or a modal the script spawned), so every run is
//  dispatched onto a process-wide SERIAL queue (the scripting component is not
//  concurrency-safe — see `executionQueue`) and raced against a timeout. On
//  timeout the in-flight run is abandoned (we cannot safely interrupt a thread
//  mid-Apple-Event) and the caller is resumed with `.timedOut`; a run still
//  queued when its caller times out is skipped. The continuation is resumed
//  exactly once.
//
//  Every in-flight script also arms a main-runloop HEARTBEAT timer (see
//  `beginMainRunLoopHeartbeat`): AppleScript's Apple-event reply delivery and
//  post-send main-actor scheduling both depend on the MAIN run loop turning,
//  which a headless CLI parked in `CFRunLoopRun` does not do on its own.
//  Without it, sends from background threads stall for tens of seconds (or
//  forever) and the process's main actor wedges — observed live as eval-suite
//  watchdog kills attributed to "TCC consent" that were really a sleeping
//  run loop.
//
//  Per the model-runtime non-negotiables: this reports the REAL outcome
//  (success output, compile error, runtime error, or the -1743 "automation not
//  permitted" status) back to the model. There is no output coercion or fake
//  success — a failing script returns its actual error so the model can correct.
//
//  JXA (JavaScript for Automation) runs through the same serial queue and
//  watchdog via OSAKit's `OSAScript` with the JavaScript OSA component —
//  identical outcome mapping, different language runtime.
//

import Foundation
import OSAKit

/// Structured outcome of one `NSAppleScript` execution. `output` is the
/// coerced textual result on success; the error fields carry the real
/// `NSAppleScript` error number + message on any failure so the loop can feed
/// the exact reason back to the model.
public struct AppleScriptExecutionResult: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The script compiled and ran with no error.
        case success
        /// The source failed to compile (syntax error).
        case compileError
        /// The script compiled but raised an error while running.
        case runtimeError
        /// `-1743` / `errAEEventNotPermitted`: the OS Automation permission for
        /// the target app isn't granted. The send itself triggers the system
        /// consent dialog (attributed to Osaurus); the user must approve it.
        case permissionRequired
        /// The run exceeded its timeout and was abandoned.
        case timedOut
    }

    public let status: Status
    public let output: String?
    public let errorNumber: Int?
    public let errorMessage: String?

    public init(status: Status, output: String?, errorNumber: Int?, errorMessage: String?) {
        self.status = status
        self.output = output
        self.errorNumber = errorNumber
        self.errorMessage = errorMessage
    }

    public var isSuccess: Bool { status == .success }
}

enum AppleScriptExecutor {
    /// `errAEEventNotPermitted` — the target app's Automation permission is not
    /// granted for this process. The failed send auto-triggers the OS dialog.
    static let permissionDeniedErrorNumber = -1743

    /// Default per-script wall-clock budget. Generous enough for an app to
    /// launch and reply, bounded so a hung script can't stall the loop.
    static let defaultTimeoutSeconds: TimeInterval = 45

    /// Process-wide SERIAL execution queue. The Open Scripting Architecture /
    /// Component Manager that backs `NSAppleScript` is NOT safe to drive
    /// concurrently: two `executeAndReturnError` calls in flight on different
    /// threads at once deadlock the scripting component (verified — concurrent
    /// runs hang indefinitely; staggered ones return `errOSAInvalidID` / -1751).
    /// Serializing every run here is both the correctness fix and the right
    /// domain model (one desktop, one script at a time). A dedicated queue (not
    /// the cooperative pool, not main) keeps a slow script from starving Swift
    /// concurrency or freezing the UI.
    private static let executionQueue = DispatchQueue(
        label: "ai.osaurus.applescript.exec",
        qos: .userInitiated
    )

    /// Main-runloop heartbeat, armed for the duration of every Apple event
    /// send. An off-main `executeAndReturnError` needs the MAIN run loop to
    /// turn for its reply to be delivered: AppleScript's send path parks the
    /// reply delivery on main-runloop wakeups. A GUI app gets those wakeups
    /// for free (events, timers); a CLI whose main thread sits inside
    /// `swift_task_asyncMainDrainQueue` → `CFRunLoopRun` does NOT — the loop
    /// stays asleep in `mach_msg`, the reply is never serviced, and (worse)
    /// main-actor jobs enqueued AFTER the send get stranded too: the whole
    /// process wedges until an unrelated wakeup arrives. Verified in
    /// isolation: a successful `tell app "Finder" to count windows` took 32s
    /// with a sleeping main loop and 1s with a heartbeat; a task hopping to
    /// the MainActor after an abandoned send never ran at all without one.
    /// The timer's tick does no work — the WAKEUP is the point. Refcounted
    /// so overlapping compile checks / runs share one timer; removed when
    /// the last in-flight script finishes. `CFRunLoop` add/remove is
    /// thread-safe, so worker threads can arm it directly.
    private static let heartbeatLock = NSLock()
    nonisolated(unsafe) private static var heartbeatTimer: CFRunLoopTimer?
    nonisolated(unsafe) private static var heartbeatRefCount = 0

    private static func beginMainRunLoopHeartbeat() {
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        heartbeatRefCount += 1
        guard heartbeatTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 0.25,
            0.25,
            0,
            0
        ) { _ in
            // Intentionally empty: the wakeup itself drains stranded
            // main-queue / main-actor work and lets AE replies deliver.
        }
        heartbeatTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private static func endMainRunLoopHeartbeat() {
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        heartbeatRefCount -= 1
        guard heartbeatRefCount <= 0 else { return }
        heartbeatRefCount = 0
        if let timer = heartbeatTimer {
            CFRunLoopTimerInvalidate(timer)
            heartbeatTimer = nil
        }
    }

    /// Test seam: whether the main-runloop heartbeat timer is currently
    /// armed. The begin/end pairing (including the abandoned-worker and
    /// skipped-worker paths) is what regression tests pin — a leaked ref
    /// would keep the main loop waking forever; a missing ref re-introduces
    /// the headless-host AE-reply wedge.
    static var isHeartbeatActiveForTesting: Bool {
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        return heartbeatTimer != nil
    }

    /// Compile + execute `source` on the serial execution queue, bounded by
    /// `timeout`. Always returns a structured result (never throws); a timeout
    /// yields `.timedOut` and the in-flight (or not-yet-started) work is
    /// abandoned — a queued request that times out before it runs is skipped so
    /// the caller never has a script execute after it gave up.
    static func run(
        source: String,
        language: AppleScriptLanguage = .appleScript,
        timeout: TimeInterval = defaultTimeoutSeconds
    ) async -> AppleScriptExecutionResult {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<AppleScriptExecutionResult, Never>) in
            let resumer = AppleScriptSingleResume(continuation)

            // Heartbeat spans enqueue → worker completion (NOT caller resume):
            // an abandoned run keeps its ref so the parked send can still
            // receive its reply, finish, and release the serial queue instead
            // of blocking every later script.
            beginMainRunLoopHeartbeat()
            executionQueue.async {
                defer { endMainRunLoopHeartbeat() }
                // If the watchdog already resumed the caller (timed out while
                // this was queued behind another script), skip the work — don't
                // run a script the caller no longer wants.
                guard !resumer.isResumed else { return }
                // Fresh autorelease pool per run: the OSA components and AE
                // descriptors are autoreleased, and this queue's thread is
                // long-lived across many runs.
                let result = autoreleasepool {
                    switch language {
                    case .appleScript: return executeSynchronously(source: source)
                    case .javascript: return executeJavaScriptSynchronously(source: source)
                    }
                }
                resumer.resume(result)
            }

            if timeout > 0, timeout.isFinite {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    resumer.resume(
                        AppleScriptExecutionResult(
                            status: .timedOut,
                            output: nil,
                            errorNumber: nil,
                            errorMessage:
                                "The AppleScript did not finish within \(Int(timeout))s and was stopped."
                        )
                    )
                }
            }
        }
    }

    /// Compile `source` WITHOUT executing it — the confirm-gate dry run. A
    /// compile sends no Apple Events and mutates nothing; it only proves the
    /// syntax. Returns the `.compileError` result to feed back to the model
    /// when the script cannot compile, and `nil` when it compiles fine — or
    /// when the check couldn't complete inside `timeout` (never block or fail
    /// the flow on the checker itself; the executor still reports the real
    /// compile outcome at run time).
    static func compileCheck(
        source: String,
        language: AppleScriptLanguage = .appleScript,
        timeout: TimeInterval = 10
    ) async -> AppleScriptExecutionResult? {
        let result: AppleScriptExecutionResult = await withCheckedContinuation { continuation in
            let resumer = AppleScriptSingleResume(continuation)
            // Compiles send no Apple events themselves, but they share the
            // serial queue with runs — the heartbeat keeps a compile queued
            // behind a parked send from waiting on a reply that can only be
            // delivered by main-runloop wakeups.
            beginMainRunLoopHeartbeat()
            executionQueue.async {
                defer { endMainRunLoopHeartbeat() }
                guard !resumer.isResumed else { return }
                let outcome = autoreleasepool { compileSynchronously(source: source, language: language) }
                resumer.resume(outcome)
            }
            if timeout > 0, timeout.isFinite {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    resumer.resume(
                        AppleScriptExecutionResult(
                            status: .timedOut,
                            output: nil,
                            errorNumber: nil,
                            errorMessage: nil
                        )
                    )
                }
            }
        }
        return result.status == .compileError ? result : nil
    }

    /// Synchronous compile-only pass for either OSA language. `.success` when
    /// the source compiles, `.compileError` (with the real error fields) when
    /// it doesn't, `.runtimeError` when the OSA component itself is missing.
    private static func compileSynchronously(
        source: String,
        language: AppleScriptLanguage
    ) -> AppleScriptExecutionResult {
        let ok = AppleScriptExecutionResult(
            status: .success,
            output: nil,
            errorNumber: nil,
            errorMessage: nil
        )
        switch language {
        case .appleScript:
            guard let script = NSAppleScript(source: source) else {
                return AppleScriptExecutionResult(
                    status: .compileError,
                    output: nil,
                    errorNumber: nil,
                    errorMessage: "The AppleScript could not be initialized."
                )
            }
            var compileError: NSDictionary?
            if !script.compileAndReturnError(&compileError) {
                let fields = errorFields(compileError)
                return AppleScriptExecutionResult(
                    status: .compileError,
                    output: nil,
                    errorNumber: fields.number,
                    errorMessage: fields.message ?? "The AppleScript failed to compile."
                )
            }
            return ok
        case .javascript:
            guard
                let osaLanguage = OSALanguage(
                    forName: AppleScriptLanguage.javascript.osaLanguageName
                )
            else {
                return AppleScriptExecutionResult(
                    status: .runtimeError,
                    output: nil,
                    errorNumber: nil,
                    errorMessage: nil
                )
            }
            let script = OSAScript(source: source, language: osaLanguage)
            var compileError: NSDictionary?
            if !script.compileAndReturnError(&compileError) {
                let fields = errorFields(compileError)
                return AppleScriptExecutionResult(
                    status: .compileError,
                    output: nil,
                    errorNumber: fields.number,
                    errorMessage: fields.message ?? "The JXA script failed to compile."
                )
            }
            return ok
        }
    }

    /// Synchronous compile + execute. Distinguishes a compile error (syntax)
    /// from a runtime error by compiling explicitly first, and maps the
    /// permission code so the loop can report it precisely.
    private static func executeSynchronously(source: String) -> AppleScriptExecutionResult {
        guard let script = NSAppleScript(source: source) else {
            return AppleScriptExecutionResult(
                status: .compileError,
                output: nil,
                errorNumber: nil,
                errorMessage: "The AppleScript could not be initialized."
            )
        }

        var compileError: NSDictionary?
        if !script.compileAndReturnError(&compileError) {
            let fields = errorFields(compileError)
            return AppleScriptExecutionResult(
                status: .compileError,
                output: nil,
                errorNumber: fields.number,
                errorMessage: fields.message ?? "The AppleScript failed to compile."
            )
        }

        var executeError: NSDictionary?
        let descriptor = script.executeAndReturnError(&executeError)
        if let executeError {
            let fields = errorFields(executeError)
            // Two permission shapes map to `.permissionRequired`: the -1743
            // Automation denial, and System Events' assistive-access denials
            // (UI scripting without the Accessibility grant) — both are user
            // grants, not script bugs, so the loop routes them to permission
            // recovery instead of a rewrite.
            let isPermission =
                fields.number == permissionDeniedErrorNumber
                || AppleScriptAccessibility.isAccessibilityDenial(
                    errorNumber: fields.number,
                    errorMessage: fields.message
                )
            return AppleScriptExecutionResult(
                status: isPermission ? .permissionRequired : .runtimeError,
                output: nil,
                errorNumber: fields.number,
                errorMessage: fields.message ?? "The AppleScript failed while running."
            )
        }

        return AppleScriptExecutionResult(
            status: .success,
            output: coerceOutput(descriptor),
            errorNumber: nil,
            errorMessage: nil
        )
    }

    /// Synchronous compile + execute for a JXA (JavaScript for Automation)
    /// source via OSAKit's `OSAScript` with the JavaScript OSA component. Same
    /// outcome mapping as the AppleScript path: real compile error, real
    /// runtime error (with the permission statuses recognized), or the coerced
    /// return-value descriptor on success.
    private static func executeJavaScriptSynchronously(source: String) -> AppleScriptExecutionResult {
        guard let language = OSALanguage(forName: AppleScriptLanguage.javascript.osaLanguageName)
        else {
            // The JavaScript OSA component ships with macOS; its absence is an
            // environment fault worth reporting honestly, not a script bug.
            return AppleScriptExecutionResult(
                status: .runtimeError,
                output: nil,
                errorNumber: nil,
                errorMessage:
                    "JavaScript for Automation is not available on this system (no JavaScript OSA "
                    + "component)."
            )
        }
        let script = OSAScript(source: source, language: language)

        var compileError: NSDictionary?
        if !script.compileAndReturnError(&compileError) {
            let fields = errorFields(compileError)
            return AppleScriptExecutionResult(
                status: .compileError,
                output: nil,
                errorNumber: fields.number,
                errorMessage: fields.message ?? "The JXA script failed to compile."
            )
        }

        var executeError: NSDictionary?
        let descriptor = script.executeAndReturnError(&executeError)
        if let executeError {
            let fields = errorFields(executeError)
            let isPermission =
                fields.number == permissionDeniedErrorNumber
                || AppleScriptAccessibility.isAccessibilityDenial(
                    errorNumber: fields.number,
                    errorMessage: fields.message
                )
            return AppleScriptExecutionResult(
                status: isPermission ? .permissionRequired : .runtimeError,
                output: nil,
                errorNumber: fields.number,
                errorMessage: fields.message ?? "The JXA script failed while running."
            )
        }

        return AppleScriptExecutionResult(
            status: .success,
            output: coerceOutput(descriptor),
            errorNumber: nil,
            errorMessage: nil
        )
    }

    /// Extract the error number + message from either error-dictionary shape:
    /// `NSAppleScript` keys (`NSAppleScriptErrorNumber`/`…Message`) or OSAKit's
    /// `OSAScript` keys (`OSAScriptErrorNumberKey`/`OSAScriptErrorMessageKey`).
    private static func errorFields(_ dict: NSDictionary?) -> (number: Int?, message: String?) {
        guard let dict else { return (nil, nil) }
        let number =
            (dict[NSAppleScript.errorNumber] as? Int)
            ?? (dict[OSAScriptErrorNumberKey] as? Int)
        let rawMessage =
            (dict[NSAppleScript.errorMessage] as? String)
            ?? (dict[OSAScriptErrorMessageKey] as? String)
            ?? (dict[OSAScriptErrorBriefMessageKey] as? String)
        let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, (message?.isEmpty ?? true) ? nil : message)
    }

    /// Best-effort textual rendering of the result descriptor so the loop can
    /// surface a REAL value for the payload, not just success/failure. Text
    /// returns directly; scalars (integers, reals, booleans, dates) are coerced
    /// to text; lists and records are rendered element-wise (recursively).
    /// `nil` when the script returned nothing representable as text (e.g. an
    /// action with no `return`). Trimmed; an all-whitespace result is `nil`.
    private static func coerceOutput(_ descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor else { return nil }
        let rendered = render(descriptor)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (rendered?.isEmpty ?? true) ? nil : rendered
    }

    // Four-char AE type codes we special-case, computed at use site so this file
    // stays Foundation-only (no Carbon / CoreServices import for the constants).
    private static let aeListType: DescType = fourCharCode("list")
    private static let aeRecordType: DescType = fourCharCode("reco")
    private static let aeUnicodeType: DescType = fourCharCode("utxt")
    private static let aeBooleanTypes: Set<DescType> = [
        fourCharCode("bool"), fourCharCode("true"), fourCharCode("fals"),
    ]
    /// `keyASUserRecordFields` — the keyword under which a user-defined
    /// AppleScript record carries its NON-reserved label/value pairs as a
    /// flat alternating list (`{battery:87}` → `usrf: ["battery", 87]`).
    /// These labels are real, resolvable names rather than four-char codes.
    private static let aeUserRecordFields: AEKeyword = fourCharCode("usrf")
    /// AppleScript RESERVED record labels compile to coded keyword fields
    /// directly on the record (not into `usrf`); map the ubiquitous ones back
    /// to their source names so `{name:"Front Door", locked:true}` reads back
    /// as written. Codes outside the map fall back to their raw four-char tag.
    private static let aeReservedRecordKeys: [AEKeyword: String] = [
        fourCharCode("pnam"): "name",
        fourCharCode("ID  "): "id",
        fourCharCode("pidx"): "index",
        fourCharCode("pcls"): "class",
        fourCharCode("aslk"): "locked",
        fourCharCode("vers"): "version",
        fourCharCode("pcnt"): "contents",
        fourCharCode("ppor"): "port",
        fourCharCode("psiz"): "size",
        fourCharCode("pALL"): "properties",
    ]

    /// Pack a (≤4 char) ASCII tag into a `DescType` (FourCharCode) without
    /// importing the Carbon headers that declare `typeAEList` & friends.
    private static func fourCharCode(_ tag: String) -> DescType {
        var code: DescType = 0
        for byte in tag.utf8.prefix(4) { code = (code << 8) + DescType(byte) }
        return code
    }

    /// Recursive descriptor → text. Handles booleans, lists, and records
    /// structurally and falls back to a Unicode-text coercion for any other
    /// scalar (integers, reals, dates) before giving up.
    private static func render(_ descriptor: NSAppleEventDescriptor) -> String? {
        let type = descriptor.descriptorType
        if aeBooleanTypes.contains(type) { return descriptor.booleanValue ? "true" : "false" }
        // A list (`{1, 2, 3}` / `{"a", "b"}`) renders element-wise; a record
        // renders as `key: value` pairs with its REAL keys where resolvable.
        if type == aeListType { return joinItems(descriptor) }
        if type == aeRecordType { return renderRecord(descriptor) }
        if let value = descriptor.stringValue, !value.isEmpty { return value }
        if let coerced = descriptor.coerce(toDescriptorType: aeUnicodeType)?.stringValue,
            !coerced.isEmpty
        {
            return coerced
        }
        return nil
    }

    /// Render each element of a list/record descriptor (recursing via `render`)
    /// and comma-join them. `nil` when empty or nothing renders.
    private static func joinItems(_ descriptor: NSAppleEventDescriptor) -> String? {
        let count = descriptor.numberOfItems
        guard count > 0 else { return nil }
        var parts: [String] = []
        for index in 1 ... count {
            if let item = descriptor.atIndex(index), let text = render(item) { parts.append(text) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Render a record descriptor as `key: value` pairs with REAL keys where
    /// resolvable. Two field shapes coexist on one record: user-defined labels
    /// arrive as an alternating key/value list under `usrf`, while RESERVED
    /// labels (`name`, `id`, …) arrive as coded keyword fields directly on the
    /// record — mapped back via `aeReservedRecordKeys`, with unknown codes
    /// surfacing their four-char tag (still actionable). Nested containers are
    /// braced so pair boundaries stay readable. Falls back to text coercion,
    /// then value-joining, when nothing renders as a pair.
    private static func renderRecord(_ descriptor: NSAppleEventDescriptor) -> String? {
        let count = descriptor.numberOfItems
        guard count > 0 else { return nil }
        var parts: [String] = []
        for index in 1 ... count {
            guard let item = descriptor.atIndex(index) else { continue }
            let keyword = descriptor.keywordForDescriptor(at: index)
            if keyword == aeUserRecordFields {
                var fieldIndex = 1
                while fieldIndex + 1 <= item.numberOfItems {
                    if let key = item.atIndex(fieldIndex)?.stringValue, !key.isEmpty,
                        let value = item.atIndex(fieldIndex + 1).flatMap(renderFieldValue)
                    {
                        parts.append("\(key): \(value)")
                    }
                    fieldIndex += 2
                }
            } else if let value = renderFieldValue(item) {
                parts.append("\(recordKeyName(for: keyword)): \(value)")
            }
        }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        if let coerced = descriptor.coerce(toDescriptorType: aeUnicodeType)?.stringValue,
            !coerced.isEmpty
        {
            return coerced
        }
        return joinItems(descriptor)
    }

    /// Render one record-field value, bracing nested containers so a nested
    /// record/list doesn't blur into the parent's `key: value` sequence.
    private static func renderFieldValue(_ descriptor: NSAppleEventDescriptor) -> String? {
        guard let text = render(descriptor) else { return nil }
        let type = descriptor.descriptorType
        return (type == aeRecordType || type == aeListType) ? "{\(text)}" : text
    }

    /// Readable name for a coded record keyword: known reserved labels map to
    /// their AppleScript source names; anything else surfaces its raw
    /// four-char tag rather than being dropped.
    private static func recordKeyName(for keyword: AEKeyword) -> String {
        if let name = aeReservedRecordKeys[keyword] { return name }
        let bytes = [
            UInt8((keyword >> 24) & 0xFF), UInt8((keyword >> 16) & 0xFF),
            UInt8((keyword >> 8) & 0xFF), UInt8(keyword & 0xFF),
        ]
        let tag = (String(bytes: bytes, encoding: .macOSRoman) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? "?" : tag
    }
}

/// Resume a `CheckedContinuation` at most once, from whichever of the worker
/// thread or the timeout watchdog finishes first. `CheckedContinuation` traps
/// on a double-resume, so the lock-guarded flag is load-bearing. Named
/// distinctly from the module's generic `SingleResume<T>` to avoid a
/// same-name top-level type collision.
private final class AppleScriptSingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<AppleScriptExecutionResult, Never>

    init(_ continuation: CheckedContinuation<AppleScriptExecutionResult, Never>) {
        self.continuation = continuation
    }

    /// Whether the continuation has already been resumed (by the worker or the
    /// timeout watchdog). Read by the serial queue to skip work for a request
    /// that timed out while queued.
    var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    func resume(_ result: AppleScriptExecutionResult) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: result)
    }
}
