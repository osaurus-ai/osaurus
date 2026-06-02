//
//  MLXErrorRecovery.swift
//  osaurus
//
//  Installs a process-wide MLX error handler so a C++-side MLX error in any
//  forward pass becomes a logged event instead of `fatalError`. Without this,
//  the default `mlx-swift` `ErrorHandler.dispatch` fallback is `fatalError(message)`
//  — i.e. *any* MLX assertion (shape mismatch in `rmsNorm`, broadcast mismatch,
//  Metal validation failure) takes the entire osaurus process down, killing every
//  unrelated in-flight request as collateral damage.
//
//  The crash class this prevents was symbolicated against bundle
//  `nemotron-cascade-2-30b-a3b-jang_4m`, where the JANG_4M unpack on the
//  NemotronH backbone produced a weight tensor whose last dim disagreed with
//  the activation: `MLXFast.rmsNorm` → `_mlx_error` → `ErrorHandler.dispatch`
//  → `_assertionFailure` → SIGTRAP. The vmlx-side fix lives in
//  `NemotronHJANGTQ.swift`; on the osaurus side we want the server to keep
//  running and surface the error to the offending request only.
//
//  ### Why a global handler, not `withErrorHandler`/`withError`
//
//  vmlx-swift's `BatchEngine` runs its scheduling loop in a long-lived
//  background `Task` created when the engine is instantiated, not per request.
//  TaskLocal handlers (the non-deprecated `withErrorHandler` API) only flow
//  through structured concurrency — they do **not** reach a pre-existing task,
//  so wrapping `engine.generate` at the call site would not protect the slot
//  whose forward pass actually traps.
//
//  The deprecated-but-still-public `setErrorHandler` is therefore the correct
//  tool for "make MLX errors recoverable for the whole process." Its
//  deprecation message is a hint that *user code* should prefer scoped
//  handlers; system bootstrap is a different shape.
//

import Foundation
import MLX
import os.log

private let recoveryLog = Logger(subsystem: "com.dinoki.osaurus", category: "MLXErrorRecovery")

/// A recovered MLX C++ forward-pass error surfaced to a single request. The
/// global handler turns the underlying MLX `fatalError` into a logged event
/// (keeping the server alive); this is how the offending generation reports
/// it to its caller as a failed chunk / HTTP 500 with `mlx_error` detail
/// instead of an opaque blank stream.
public struct MLXForwardPassError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { "mlx_error: \(message)" }
}

public enum MLXErrorRecovery {

    /// Lock-protected slot for the most recent MLX error message. Useful for
    /// diagnostics — the handler runs on whichever thread MLX called us from,
    /// so this is a coarse "what failed last" rather than a per-request signal.
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastError: String?
    /// Monotonic count of MLX errors seen process-wide. A generation captures
    /// this before it starts and compares afterward to detect whether an MLX
    /// C++ error fired during its window. Coarse under heavy concurrency (the
    /// handler is global and can't be attributed to a specific forward pass),
    /// but enough to convert the common single-stream blank-output case into a
    /// surfaced error.
    nonisolated(unsafe) private static var _errorSequence: UInt64 = 0

    public static var lastError: String? {
        lock.withLock { _lastError }
    }

    /// Snapshot of the current error sequence; capture before a generation.
    public static func errorSequence() -> UInt64 {
        lock.withLock { _errorSequence }
    }

    /// The most recent MLX error message if a new error was recorded since
    /// `sequence`, else `nil`.
    public static func errorSince(_ sequence: UInt64) -> String? {
        lock.withLock { _errorSequence > sequence ? _lastError : nil }
    }

    /// One-shot install flag. `setErrorHandler` itself is idempotent at the
    /// MLX level (replaces the previous handler), but we still gate to avoid
    /// re-logging the install message on every call from defensive call sites.
    nonisolated(unsafe) private static var installed = false

    /// Install the process-wide handler. Idempotent and thread-safe via `lock`.
    /// Safe to call from any thread; first caller wins, subsequent calls are
    /// no-ops.
    public static func installGlobalHandler() {
        lock.withLock {
            guard !installed else { return }
            installed = true
        }

        // C-convention closure: no captures (must match `@convention(c)`).
        let handler: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
            cMessage,
            _ in
            let message = cMessage.map { String(cString: $0) } ?? "<nil>"
            MLXErrorRecovery.lock.withLock {
                MLXErrorRecovery._lastError = message
                MLXErrorRecovery._errorSequence &+= 1
            }
            // `os_log` from the C-convention thunk is allowed (no async
            // hops, no captures of Swift state).
            recoveryLog.error("MLX error: \(message, privacy: .public)")
        }

        // `setErrorHandler` is marked deprecated in mlx-swift; see the file
        // header for why the global form is the correct shape here.
        @available(*, deprecated)
        func setHandlerCompat() {
            MLX.setErrorHandler(handler)
        }
        setHandlerCompat()

        recoveryLog.info("installed global MLX error handler (process will not fatalError on MLX C++ errors)")
    }
}
