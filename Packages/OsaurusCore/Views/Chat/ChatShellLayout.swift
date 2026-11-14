//
//  ChatShellLayout.swift
//  osaurus
//
//  The chat window's column model, computed once per window width: which
//  breakpoint the window is in, whether the sidebar and the context panel
//  are docked beside the content column or float over it, and how wide
//  every column is. Pure so the whole matrix is unit-testable; `ChatView`
//  reads it instead of deriving widths inline.
//
//  Shell anatomy (left to right): navigation rail, sidebar, content column,
//  context panel. The thread, composer, notices and prompt cards all share
//  the content column's one readable width and one horizontal inset.
//
//  Breakpoints are measured on the space beside the rail:
//
//  - compact (< 760): sidebar and context panel float over the content as
//    dismissible overlays; the content keeps the full width.
//  - regular (760..<1200): sidebar docked (clamped so the content keeps
//    its minimum); the context panel docks too, and the sidebar steps
//    aside when all three cannot fit.
//  - wide (>= 1200): everything docked.
//
//  The widths here are layout geometry, not spacing: the design library's
//  layout assignments resolve to spacing tokens (0...64pt), so column
//  widths and breakpoints live in this one place instead.
//

import SwiftUI

enum ChatShellBreakpoint: String, Sendable, CaseIterable {
    case compact
    case regular
    case wide
}

struct ChatShellLayout: Equatable, Sendable {
    enum PaneMode: Equatable, Sendable {
        case hidden
        case docked
        case overlay
    }

    // MARK: Geometry

    /// Width of the main navigation rail (Chat, Workflows / Usage, Settings).
    static let railWidth: CGFloat = 44
    /// Below this much room beside the rail, side panes stop docking.
    static let compactUpperBound: CGFloat = 760
    /// From this much room beside the rail, every pane docks.
    static let wideLowerBound: CGFloat = 1200
    /// Outer width of the readable column (thread, composer, notices,
    /// prompt cards), side insets included.
    static let readableColumnWidth: CGFloat = 800
    /// Horizontal inset inside the readable column. The thread's bubbles,
    /// the composer card and every notice share these left and right edges.
    static let columnInset: CGFloat = 20
    /// Transparent padding the composer view keeps around its card.
    static let composerOuterInset: CGFloat = 12
    /// The content column never docks narrower than this beside the sidebar.
    static let minimumContentWidth: CGFloat = 480
    /// Content column kept readable beside the docked context panel.
    static let minimumContentWidthWithPanel: CGFloat = 440
    /// Content an overlay pane leaves uncovered, so the window still reads
    /// as the chat and a click there dismisses the overlay.
    static let overlayEdgeClearance: CGFloat = 56
    /// Smallest chat window content area the shell is designed for.
    static let minimumWindowSize = CGSize(width: 560, height: 480)
    /// Window controls plus the sidebar toggle, measured from the window's
    /// leading edge; titlebar content starts past them.
    static let toolbarLeadingChromeWidth: CGFloat = 124
    /// Trailing toolbar buttons (Inbox, context panel), measured from the
    /// window's trailing edge.
    static let toolbarTrailingChromeWidth: CGFloat = 96
    /// Widest the find bar grows inside the readable column.
    static let findBarMaxWidth: CGFloat = 360

    // MARK: Floating context card

    /// The File Changes card floats over the content's top trailing corner.
    static let floatingContextWidth: CGFloat = 360
    /// Gap between the card and the content's trailing edge and the
    /// titlebar strip above it.
    static let floatingContextInset: CGFloat = 12
    static let floatingContextMaxHeight: CGFloat = 560
    /// Height kept clear under the card so it never covers the composer.
    static let floatingContextBottomClearance: CGFloat = 140
    /// Column a wide window sets aside for the card (the card plus its
    /// insets), so the conversation re-centers beside it instead of
    /// running under it.
    static let reservedContextWidth: CGFloat = floatingContextWidth + 2 * floatingContextInset

    /// Whether the card takes a column of its own: only in wide windows.
    /// Narrower ones let it float over the content.
    static func contextReservesColumn(_ breakpoint: ChatShellBreakpoint) -> Bool {
        breakpoint == .wide
    }

    /// The card's width and height cap for a content column `contentWidth`
    /// wide in a window `height` tall whose titlebar strip is
    /// `headerHeight`: full width when it fits, otherwise the column less
    /// its insets; never taller than the room above the composer.
    static func floatingContextSize(contentWidth: CGFloat, height: CGFloat, headerHeight: CGFloat) -> CGSize {
        let width = min(floatingContextWidth, max(0, contentWidth - 2 * floatingContextInset))
        let room = height - headerHeight - floatingContextInset - floatingContextBottomClearance
        return CGSize(width: width, height: min(floatingContextMaxHeight, max(0, room)))
    }

    static let sidebarWidthRange: ClosedRange<CGFloat> = 240...460
    static let contextWidthRange: ClosedRange<CGFloat> = 300...520
    static let defaultContextWidth: CGFloat = 380

    // MARK: Result

    let breakpoint: ChatShellBreakpoint
    let sidebarMode: PaneMode
    /// On-screen sidebar width (docked or overlay); 0 while hidden.
    let sidebarWidth: CGFloat
    let contextMode: PaneMode
    /// On-screen context panel width (docked or overlay); 0 while hidden.
    let contextWidth: CGFloat
    /// The content column: the window less the rail and any docked pane.
    let contentWidth: CGFloat
    /// True when the sidebar was asked for but gave way to the context
    /// panel because all three columns could not fit.
    let sidebarStepsAside: Bool

    init(
        windowWidth: CGFloat,
        sidebarRequested: Bool,
        preferredSidebarWidth: CGFloat,
        contextRequested: Bool,
        preferredContextWidth: CGFloat = ChatShellLayout.defaultContextWidth,
        railWidth: CGFloat = ChatShellLayout.railWidth
    ) {
        let available = max(0, windowWidth - railWidth)
        let breakpoint = Self.breakpoint(forAvailableWidth: available)
        self.breakpoint = breakpoint

        let sidebar = Self.clampSidebarWidth(preferredSidebarWidth)
        let context = Self.clampContextWidth(preferredContextWidth)

        switch breakpoint {
        case .compact:
            let overlayLimit = max(0, available - Self.overlayEdgeClearance)
            sidebarMode = sidebarRequested ? .overlay : .hidden
            sidebarWidth = sidebarRequested ? min(sidebar, overlayLimit) : 0
            contextMode = contextRequested ? .overlay : .hidden
            contextWidth = contextRequested ? min(context, overlayLimit) : 0
            contentWidth = available
            sidebarStepsAside = false
        case .regular, .wide:
            let dockedSidebar = max(
                Self.sidebarWidthRange.lowerBound,
                min(sidebar, available - Self.minimumContentWidth))
            let stepsAside =
                sidebarRequested && contextRequested
                && available < dockedSidebar + Self.minimumContentWidthWithPanel + Self.contextWidthRange.lowerBound
            let showsSidebar = sidebarRequested && !stepsAside
            sidebarMode = showsSidebar ? .docked : .hidden
            sidebarWidth = showsSidebar ? dockedSidebar : 0
            contextMode = contextRequested ? .docked : .hidden
            contextWidth =
                contextRequested
                ? Self.dockedContextWidth(available: available, sidebarWidth: sidebarWidth, preferred: context) : 0
            contentWidth = max(0, available - sidebarWidth - contextWidth)
            sidebarStepsAside = stepsAside
        }
    }

    static func breakpoint(forAvailableWidth available: CGFloat) -> ChatShellBreakpoint {
        if available < compactUpperBound { return .compact }
        if available < wideLowerBound { return .regular }
        return .wide
    }

    static func clampSidebarWidth(_ raw: CGFloat) -> CGFloat {
        min(max(raw, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    static func clampContextWidth(_ raw: CGFloat) -> CGFloat {
        min(max(raw, contextWidthRange.lowerBound), contextWidthRange.upperBound)
    }

    /// The user's context panel width when it fits, otherwise squeezed to
    /// its floor before the content column gives.
    static func dockedContextWidth(available: CGFloat, sidebarWidth: CGFloat, preferred: CGFloat) -> CGFloat {
        let room = available - sidebarWidth - minimumContentWidthWithPanel
        return min(clampContextWidth(preferred), max(contextWidthRange.lowerBound, room))
    }

    // MARK: Content column

    /// Outer width of the readable column inside the content column.
    var readableWidth: CGFloat { Self.readableWidth(in: contentWidth) }

    /// Width the thread's text column (and the composer card) render at.
    var threadContentWidth: CGFloat { Self.threadContentWidth(in: contentWidth) }

    /// Frame width for the composer view, whose own outer padding is
    /// narrower than the column inset: its card then lands exactly on the
    /// thread's edges.
    var composerFrameWidth: CGFloat { Self.composerFrameWidth(in: contentWidth) }

    /// Composer chips collapse to icons only when the window is compact.
    var usesCompactComposer: Bool { breakpoint == .compact }

    static func readableWidth(in contentWidth: CGFloat) -> CGFloat {
        max(0, min(contentWidth, readableColumnWidth))
    }

    static func threadContentWidth(in contentWidth: CGFloat) -> CGFloat {
        max(0, readableWidth(in: contentWidth) - 2 * columnInset)
    }

    static func composerFrameWidth(in contentWidth: CGFloat) -> CGFloat {
        max(0, readableWidth(in: contentWidth) - 2 * (columnInset - composerOuterInset))
    }

    // MARK: Workflow creation split

    /// Below this much content width the workflow-creation chat and draft
    /// stack behind a Chat / Workflow switch instead of sitting side by side.
    static let workflowSplitMinimumWidth: CGFloat = 760
    /// The narrowest a creation chat (workflow or agent) gets beside its
    /// draft, dragged or not.
    static let creationChatMinimumWidth: CGFloat = 340
    static let workflowDraftMinimumWidth: CGFloat = 380
    static let workflowChatFraction: CGFloat = 0.4

    /// Widths the workflow-creation chat can be dragged to, or nil when the
    /// chat and the draft stack.
    static func workflowCreationChatRange(contentWidth: CGFloat, spacing: CGFloat) -> ClosedRange<CGFloat>? {
        guard contentWidth >= workflowSplitMinimumWidth else { return nil }
        let upper = max(creationChatMinimumWidth, contentWidth - spacing - workflowDraftMinimumWidth)
        return creationChatMinimumWidth...upper
    }

    /// Outer width of the workflow-creation chat panel beside the draft, or
    /// nil when the two should stack. Unless the user dragged it to
    /// `preferred`, the chat takes its share up to the thread's readable
    /// width, and whatever the draft's column can't use.
    static func workflowCreationChatWidth(
        contentWidth: CGFloat, spacing: CGFloat, preferred: CGFloat? = nil
    ) -> CGFloat? {
        guard let range = workflowCreationChatRange(contentWidth: contentWidth, spacing: spacing) else { return nil }
        let automatic = min(
            max(contentWidth * workflowChatFraction, contentWidth - spacing - WorkflowCanvasLayout.columnWidth),
            readableColumnWidth)
        return min(max(preferred ?? automatic, range.lowerBound), range.upperBound)
    }

    /// The conversation leads; the agent card beside it stays a column.
    static let agentDraftWidthRange: ClosedRange<CGFloat> = 320...400
    static let agentDraftFraction: CGFloat = 0.34
    /// Settings hosts the New Agent chat in its content pane (its sidebar
    /// collapsed), so the card gives up some width to keep the two side by
    /// side there.
    static let embeddedAgentDraftWidthRange: ClosedRange<CGFloat> = 300...360
    static let embeddedAgentSplitMinimumWidth: CGFloat = 680
    /// The widest the agent card is dragged to; past it the card stretches.
    static let agentDraftMaximumWidth: CGFloat = 640

    /// Widths the New Agent chat can be dragged to: the card stays between
    /// its floor and `agentDraftMaximumWidth`. Nil when the two stack.
    static func agentCreationChatRange(
        contentWidth: CGFloat, spacing: CGFloat, embedded: Bool = false
    ) -> ClosedRange<CGFloat>? {
        guard contentWidth >= (embedded ? embeddedAgentSplitMinimumWidth : workflowSplitMinimumWidth) else {
            return nil
        }
        let panelFloor = (embedded ? embeddedAgentDraftWidthRange : agentDraftWidthRange).lowerBound
        let upper = max(creationChatMinimumWidth, contentWidth - spacing - panelFloor)
        let lower = max(creationChatMinimumWidth, contentWidth - spacing - agentDraftMaximumWidth)
        return min(lower, upper)...upper
    }

    /// Outer width of the New Agent chat beside its draft panel, or nil when
    /// the two should stack. Unless the user dragged it to `preferred`, the
    /// chat takes what the panel leaves.
    static func agentCreationChatWidth(
        contentWidth: CGFloat, spacing: CGFloat, embedded: Bool = false, preferred: CGFloat? = nil
    ) -> CGFloat? {
        guard let bounds = agentCreationChatRange(contentWidth: contentWidth, spacing: spacing, embedded: embedded)
        else { return nil }
        let range = embedded ? embeddedAgentDraftWidthRange : agentDraftWidthRange
        let panel = min(max(contentWidth * agentDraftFraction, range.lowerBound), range.upperBound)
        return min(max(preferred ?? contentWidth - panel - spacing, bounds.lowerBound), bounds.upperBound)
    }
}

extension View {
    /// Places a full-width row (a notice, a banner, a prompt card) in the
    /// readable column: the shared inset inside the shared cap, centered,
    /// so it lines up with the thread's bubbles and the composer card.
    func readableColumnRow() -> some View {
        padding(.horizontal, ChatShellLayout.columnInset)
            .frame(maxWidth: ChatShellLayout.readableColumnWidth)
            .frame(maxWidth: .infinity)
    }
}
