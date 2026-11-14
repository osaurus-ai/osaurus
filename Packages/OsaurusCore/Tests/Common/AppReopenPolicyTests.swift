import AppKit
import Testing

@testable import OsaurusCore

@MainActor
struct AppReopenPolicyTests {
    private typealias C = AppReopenPolicy.Candidate

    private let shown = C(isOnScreen: true, isMinimized: false, isChat: true)
    private let minimized = C(isOnScreen: false, isMinimized: true, isChat: true)
    private let hiddenChat = C(isOnScreen: false, isMinimized: false, isChat: true)
    private let settingsShown = C(isOnScreen: true, isMinimized: false, isChat: false)
    private let settingsMinimized = C(isOnScreen: false, isMinimized: true, isChat: false)
    private let settingsUnopened = C(isOnScreen: false, isMinimized: false, isChat: false)

    @Test
    func aWindowOnScreen_isBroughtForward_andMinimizedOnesStayInTheDock() {
        #expect(AppReopenPolicy.pick([minimized, settingsShown, shown]) == 1)
    }

    @Test
    func everythingMinimized_restoresOnlyTheLastOneInUse() {
        #expect(AppReopenPolicy.pick([settingsMinimized, minimized]) == 0)
        #expect(AppReopenPolicy.pick([minimized, settingsMinimized]) == 0)
    }

    @Test
    func aMinimizedWindow_winsOverAChatHiddenWithTheHotkey() {
        #expect(AppReopenPolicy.pick([hiddenChat, settingsMinimized]) == 1)
    }

    @Test
    func aChatHiddenWithTheHotkey_comesBack_butUnopenedSettingsNever() {
        #expect(AppReopenPolicy.pick([settingsUnopened, hiddenChat]) == 1)
        #expect(AppReopenPolicy.pick([settingsUnopened]) == nil)
        #expect(AppReopenPolicy.pick([]) == nil)
    }

    @Test
    func focusHistory_ordersMostRecentFirst_andForgetsClosedWindows() {
        let history = WindowFocusHistory()
        let a = NSWindow(), b = NSWindow(), c = NSWindow()
        #expect(history.mostRecentFirst([a, b, c]) == [a, b, c])

        history.record(b)
        history.record(c)
        #expect(history.mostRecentFirst([a, b, c]) == [c, b, a])

        history.record(b)
        #expect(history.mostRecentFirst([a, b, c]) == [b, c, a])

        history.forget(b)
        #expect(history.mostRecentFirst([a, b, c]) == [c, a, b])
    }
}
