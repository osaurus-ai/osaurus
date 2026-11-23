//
//  ChatSelectionTests.swift
//  osaurusTests
//
//  Selecting chats for a batch action: a plain click always opens a chat,
//  Command-click toggles, Shift-click selects the visible range from the
//  anchor, and a row's menu acts on the selection only when that row is
//  part of a selection of several.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ChatSelectionTests {

    private let ids = (0 ..< 8).map { _ in UUID() }

    @Test("a plain click opens, Command toggles, Shift extends; Command wins over Shift")
    func clickOutcomes() {
        #expect(ChatSelection.clickOutcome(command: false, shift: false) == .open)
        #expect(ChatSelection.clickOutcome(command: true, shift: false) == .toggle)
        #expect(ChatSelection.clickOutcome(command: false, shift: true) == .extendRange)
        #expect(ChatSelection.clickOutcome(command: true, shift: true) == .toggle)
    }

    @Test("toggling adds and removes a chat and moves the anchor")
    func toggle() {
        var selection = ChatSelection()
        #expect(!selection.isActive)
        selection.toggle(ids[0])
        #expect(selection.contains(ids[0]))
        #expect(selection.anchorId == ids[0])
        #expect(selection.isActive)
        selection.toggle(ids[0])
        #expect(selection.count == 0)
        #expect(selection.anchorId == ids[0])
        #expect(!selection.isActive)
    }

    @Test("Shift-click selects the visible rows between the anchor and the clicked row, in either direction")
    func rangeFromAnchor() {
        var selection = ChatSelection()
        selection.toggle(ids[2])
        selection.selectRange(to: ids[5], visibleOrder: ids, fallbackAnchor: nil)
        #expect(selection.selectedIds == Set(ids[2 ... 5]))

        var upward = ChatSelection()
        upward.toggle(ids[6])
        upward.selectRange(to: ids[3], visibleOrder: ids, fallbackAnchor: nil)
        #expect(upward.selectedIds == Set(ids[3 ... 6]))
    }

    @Test("with nothing toggled yet, the range starts at the chat on screen")
    func rangeFromChatOnScreen() {
        var selection = ChatSelection()
        selection.selectRange(to: ids[4], visibleOrder: ids, fallbackAnchor: ids[1])
        #expect(selection.selectedIds == Set(ids[1 ... 4]))
        #expect(selection.anchorId == ids[1])
    }

    @Test("a range across agents only covers the rows on screen: chats of a folded agent are not in the order")
    func rangeSkipsFoldedRows() {
        // Agent A open (0, 1, 2), agent B folded (3, 4 hidden), agent C open (5, 6).
        let visible = [ids[0], ids[1], ids[2], ids[5], ids[6]]
        var selection = ChatSelection()
        selection.toggle(ids[1])
        selection.selectRange(to: ids[5], visibleOrder: visible, fallbackAnchor: nil)
        #expect(selection.selectedIds == [ids[1], ids[2], ids[5]])
    }

    @Test("with no anchor on screen, Shift-click toggles the clicked row alone")
    func rangeWithoutVisibleAnchor() {
        var selection = ChatSelection()
        selection.toggle(ids[7])
        selection.selectRange(to: ids[2], visibleOrder: Array(ids[0 ... 4]), fallbackAnchor: nil)
        #expect(selection.selectedIds == [ids[7], ids[2]])
        #expect(selection.anchorId == ids[2])
    }

    @Test("folding an agent keeps its chats selected: the selection is ids, not rows")
    func foldingKeepsSelection() {
        var selection = ChatSelection()
        selection.toggle(ids[3])
        selection.toggle(ids[4])
        selection.prune(existing: Set(ids))
        #expect(selection.count == 2)
    }

    @Test("chats removed elsewhere drop out silently; selection mode stays")
    func prune() {
        var selection = ChatSelection()
        selection.requestMode()
        selection.toggle(ids[0])
        selection.toggle(ids[1])
        selection.prune(existing: [ids[0]])
        #expect(selection.selectedIds == [ids[0]])
        #expect(selection.anchorId == nil)
        selection.prune(existing: [])
        #expect(selection.count == 0)
        #expect(selection.isActive)
    }

    @Test("selection mode can be asked for with nothing ticked, and clearing leaves it")
    func modeAndClear() {
        var selection = ChatSelection()
        selection.requestMode()
        #expect(selection.isActive)
        #expect(selection.count == 0)
        selection.toggle(ids[0])
        selection.clear()
        #expect(selection == ChatSelection())
        #expect(!selection.isActive)
    }

    @Test("a row's menu acts on the selection only when the row is one of several selected")
    func menuScope() {
        var selection = ChatSelection()
        #expect(selection.menuScope(for: ids[0]) == .single)
        selection.toggle(ids[0])
        #expect(selection.menuScope(for: ids[0]) == .single)
        selection.toggle(ids[1])
        selection.toggle(ids[2])
        #expect(selection.menuScope(for: ids[0]) == .batch(3))
        #expect(selection.menuScope(for: ids[5]) == .single)
    }

    @Test("select and deselect act on a group at once")
    func groupSelect() {
        var selection = ChatSelection()
        selection.select(ids[0 ... 3])
        #expect(selection.count == 4)
        selection.deselect(ids[2 ... 3])
        #expect(selection.selectedIds == Set(ids[0 ... 1]))
    }
}
