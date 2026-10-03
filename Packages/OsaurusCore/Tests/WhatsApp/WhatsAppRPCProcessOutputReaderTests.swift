#if os(macOS)
    import Foundation
    import Testing

    @testable import OsaurusCore

    struct WhatsAppRPCProcessOutputReaderTests {
        /// The write end intentionally stays open. A blocking EOF drain would
        /// deadlock; termination must still deliver the final frame first.
        @Test(.timeLimit(.minutes(1))) func terminationDrainsBufferedResponseBeforeExitWithoutWaitingForEOF() async throws {
            let pipe = Pipe()
            defer { try? pipe.fileHandleForWriting.close() }
            let reader = try WhatsAppRPCProcessOutputReader(handle: pipe.fileHandleForReading)
            let frame = Data("{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true}}\n".utf8)
            try pipe.fileHandleForWriting.write(contentsOf: frame)
            // No readability callback is dispatched before the exit callback.
            reader.finishAfterTermination()
            var events: [WhatsAppRPCProcessOutputReader.Event] = []
            for await event in reader.events { events.append(event) }
            #expect(events == [.data(frame), .terminated])
        }

        @Test(.timeLimit(.minutes(1))) func queuedPartialFramePrecedesTerminationDrainedSuffix() async throws {
            let pipe = Pipe()
            defer { try? pipe.fileHandleForWriting.close() }
            let reader = try WhatsAppRPCProcessOutputReader(handle: pipe.fileHandleForReading)
            let prefix = Data("{\"id\":1,\"result\":".utf8)
            let suffix = Data("{\"ok\":true}}\n".utf8)
            try pipe.fileHandleForWriting.write(contentsOf: prefix)
            reader.captureReadableData()
            try pipe.fileHandleForWriting.write(contentsOf: suffix)
            reader.finishAfterTermination()
            var events: [WhatsAppRPCProcessOutputReader.Event] = []
            for await event in reader.events { events.append(event) }
            #expect(events == [.data(prefix), .data(suffix), .terminated])
        }

        @Test(.timeLimit(.minutes(1))) func cancellationFinishesAndIgnoresQueuedOldCallbacks() async throws {
            let pipe = Pipe()
            defer { try? pipe.fileHandleForWriting.close() }
            let reader = try WhatsAppRPCProcessOutputReader(handle: pipe.fileHandleForReading)
            let frame = Data("{\"old\":true}\n".utf8)
            try pipe.fileHandleForWriting.write(contentsOf: frame)
            reader.captureReadableData()
            reader.cancel()
            reader.captureReadableData()
            reader.finishAfterTermination()
            var events: [WhatsAppRPCProcessOutputReader.Event] = []
            for await event in reader.events { events.append(event) }
            #expect(events == [.data(frame)])
        }
    }
#endif
