import Foundation
import Testing
@testable import OsaurusCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct InterruptTokenObserverTests {
    @Test func callbackCanReenterAndInterruptIsIdempotent() {
        let token = InterruptToken()
        let counts = Counts()
        let id = token.observeInterrupt {
            #expect(token.isInterrupted)
            token.interrupt() // Would deadlock if callbacks held the token lock.
            counts.increment()
        }
        token.interrupt()
        token.interrupt()
        token.removeInterruptObserver(id)
        #expect(counts.value == 1)
    }

    @Test func alreadyInterruptedRegistrationDeliversImmediatelyOnce() {
        let token = InterruptToken()
        let counts = Counts()
        token.interrupt()
        let id = token.observeInterrupt { counts.increment() }
        #expect(counts.value == 1)
        token.interrupt()
        token.removeInterruptObserver(id)
        #expect(counts.value == 1)
    }

    @Test func removedRegistrationReleasesCallbackAndNeverFires() {
        let token = InterruptToken()
        let counts = Counts()
        var payload: Payload? = Payload()
        weak var released = payload
        let id = token.observeInterrupt { [owned = payload!] in
            owned.fired.increment()
            counts.increment()
        }
        payload = nil
        #expect(released != nil)
        token.removeInterruptObserver(id)
        #expect(released == nil)
        token.interrupt()
        #expect(counts.value == 0)
    }

    private final class Payload: @unchecked Sendable { let fired = Counts() }
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
