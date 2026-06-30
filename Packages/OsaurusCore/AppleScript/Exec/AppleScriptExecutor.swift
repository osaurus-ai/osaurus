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
//  Per the model-runtime non-negotiables: this reports the REAL outcome
//  (success output, compile error, runtime error, or the -1743 "automation not
//  permitted" status) back to the model. There is no output coercion or fake
//  success — a failing script returns its actual error so the model can correct.
//

import Foundation

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

    /// Compile + execute `source` on the serial execution queue, bounded by
    /// `timeout`. Always returns a structured result (never throws); a timeout
    /// yields `.timedOut` and the in-flight (or not-yet-started) work is
    /// abandoned — a queued request that times out before it runs is skipped so
    /// the caller never has a script execute after it gave up.
    static func run(
        source: String,
        timeout: TimeInterval = defaultTimeoutSeconds
    ) async -> AppleScriptExecutionResult {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<AppleScriptExecutionResult, Never>) in
            let resumer = AppleScriptSingleResume(continuation)

            executionQueue.async {
                // If the watchdog already resumed the caller (timed out while
                // this was queued behind another script), skip the work — don't
                // run a script the caller no longer wants.
                guard !resumer.isResumed else { return }
                // Fresh autorelease pool per run: the OSA components and AE
                // descriptors are autoreleased, and this queue's thread is
                // long-lived across many runs.
                let result = autoreleasepool { executeSynchronously(source: source) }
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
            let status: AppleScriptExecutionResult.Status =
                fields.number == permissionDeniedErrorNumber ? .permissionRequired : .runtimeError
            return AppleScriptExecutionResult(
                status: status,
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

    private static func errorFields(_ dict: NSDictionary?) -> (number: Int?, message: String?) {
        guard let dict else { return (nil, nil) }
        let number = dict[NSAppleScript.errorNumber] as? Int
        let message = (dict[NSAppleScript.errorMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, (message?.isEmpty ?? true) ? nil : message)
    }

    /// Best-effort textual rendering of the result descriptor. Scalars and
    /// text return their `stringValue`; lists/records are joined element-wise.
    /// `nil` when the script returned nothing representable as text.
    private static func coerceOutput(_ descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor else { return nil }
        if let value = descriptor.stringValue, !value.isEmpty { return value }
        let count = descriptor.numberOfItems
        if count > 0 {
            var parts: [String] = []
            for index in 1...count {
                if let item = descriptor.atIndex(index)?.stringValue, !item.isEmpty {
                    parts.append(item)
                }
            }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return nil
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
