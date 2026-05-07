//
//  ProcessHandle.swift
//  osaurus
//
//  Lightweight kill-handle exposed to streaming tools after the
//  underlying process has started. Lets the user's [Terminate] button
//  signal the live exec without leaking the Containerization-specific
//  `LinuxProcess` type (or the host `Process` type for shell_run)
//  across abstraction boundaries.
//
//  The handle's `kill` closure is idempotent — sending SIGTERM to a
//  process that's already exited is a no-op signal-wise (the kernel
//  reports ESRCH which our wrappers swallow).
//

#if os(macOS)

    import Foundation

    public struct ProcessHandle: Sendable {
        public let pid: Int32
        public let kill: @Sendable (_ signal: Int32) async throws -> Void

        public init(
            pid: Int32,
            kill: @escaping @Sendable (_ signal: Int32) async throws -> Void
        ) {
            self.pid = pid
            self.kill = kill
        }
    }

#endif
