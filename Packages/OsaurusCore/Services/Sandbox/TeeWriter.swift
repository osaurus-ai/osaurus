//
//  TeeWriter.swift
//  osaurus
//
//  Fan-out adapter for the Containerization `Writer` protocol. Forwards
//  every `write` to a primary AND a secondary writer in lockstep.
//
//  Used by `SandboxManager.execViaAgent` so the foreground exec path can
//  collect bytes for the model's final result envelope (primary) while
//  simultaneously broadcasting them to a live UI sink / log tailer
//  (secondary). Secondary failures are swallowed so a flaky observer
//  never blocks the model's run.
//

#if os(macOS)

    import Containerization
    import Foundation

    final class TeeWriter: Writer, @unchecked Sendable {
        private let primary: any Writer
        private let secondary: any Writer

        init(primary: any Writer, secondary: any Writer) {
            self.primary = primary
            self.secondary = secondary
        }

        func write(_ data: Data) throws {
            // Secondary first so a slow / throwing observer doesn't block
            // the primary path, AND its failure can never propagate up
            // into the model's result envelope. The primary write is the
            // authoritative collection — if IT throws, the caller hears.
            try? secondary.write(data)
            try primary.write(data)
        }

        func close() throws {
            try? secondary.close()
            try primary.close()
        }
    }

#endif
