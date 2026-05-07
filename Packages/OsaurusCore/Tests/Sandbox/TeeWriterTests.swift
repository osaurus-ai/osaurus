//
//  TeeWriterTests.swift
//
//  Pin the fan-out contract: every write reaches BOTH writers, secondary
//  failures don't propagate (so a flaky UI observer can't kill the
//  exec), and `close` cascades.
//

import Containerization
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct TeeWriterTests {

    /// Minimal `Writer` test double — collects writes into a Data
    /// buffer and counts close calls.
    private final class CollectingWriter: Writer, @unchecked Sendable {
        private let lock = NSLock()
        private var _buffer = Data()
        private var _closeCount = 0

        var data: Data { lock.withLock { _buffer } }
        var closeCount: Int { lock.withLock { _closeCount } }

        func write(_ data: Data) throws { lock.withLock { _buffer.append(data) } }
        func close() throws { lock.withLock { _closeCount += 1 } }
    }

    /// Writer that throws on every call. Used to prove the secondary
    /// path's errors are swallowed.
    private final class ThrowingWriter: Writer, @unchecked Sendable {
        struct Boom: Error {}
        func write(_ data: Data) throws { throw Boom() }
        func close() throws { throw Boom() }
    }

    @Test func writeFansOutToBothWriters() throws {
        let primary = CollectingWriter()
        let secondary = CollectingWriter()
        let tee = TeeWriter(primary: primary, secondary: secondary)
        try tee.write(Data("hello".utf8))
        try tee.write(Data(" world".utf8))
        #expect(String(data: primary.data, encoding: .utf8) == "hello world")
        #expect(String(data: secondary.data, encoding: .utf8) == "hello world")
    }

    @Test func secondaryFailureDoesNotPropagate() throws {
        let primary = CollectingWriter()
        let tee = TeeWriter(primary: primary, secondary: ThrowingWriter())
        // Must not throw even though secondary always throws.
        try tee.write(Data("ok".utf8))
        #expect(String(data: primary.data, encoding: .utf8) == "ok")
    }

    @Test func closeCascadesToBothEvenIfSecondaryThrows() throws {
        let primary = CollectingWriter()
        let tee = TeeWriter(primary: primary, secondary: ThrowingWriter())
        try tee.close()
        #expect(primary.closeCount == 1)
    }
}
