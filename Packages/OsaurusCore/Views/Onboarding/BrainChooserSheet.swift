//
//  BrainChooserSheet.swift
//  osaurus
//
//  The first-run chat's Choose a Brain: the onboarding window's Brain
//  chapter in a sheet over the chat, so a person who left the window
//  without a model picks one the way they would have there. Choosing pins
//  the Orchestrator and the team, then the sheet closes.
//

import AppKit
import SwiftUI

@MainActor
enum BrainChooserSheet {
    private static var sheet: NSWindow?

    static func present(over parent: NSWindow?) {
        if let sheet, sheet.isVisible {
            sheet.makeKeyAndOrderFront(nil)
            return
        }
        let state = ConfigureAIState()
        let width = OnboardingMetrics.windowWidth
        let height = OnboardingMetrics.windowHeight
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let theme = ThemeManager.shared.currentTheme
        let view = BrainChooserView(
            state: state,
            onComplete: {
                OnboardingBrainPin.pin(state, forAgents: pinTargets())
                dismiss()
            },
            onClose: dismiss
        )
        let hosting = NSHostingView(rootView: view.environment(\.theme, theme))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.backgroundColor = NSColor(OnboardingPalette.windowBackground)
        sheet = window
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The Orchestrator and every teammate, as at the end of onboarding.
    static func pinTargets() -> [UUID] {
        [Agent.defaultId] + AgentManager.shared.agents.filter { $0.teammate != nil }.map(\.id)
    }

    private static func dismiss() {
        guard let window = sheet else { return }
        sheet = nil
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}

private struct BrainChooserView: View {
    @ObservedObject var state: ConfigureAIState
    let onComplete: () -> Void
    let onClose: () -> Void

    @StateObject private var stage = OnboardingStage()
    @StateObject private var pointer = OnboardingPointer()

    var body: some View {
        ZStack {
            OnboardingPalette.windowBackground.ignoresSafeArea()
            OnboardingBackdropHost(stage: stage, pointer: pointer)

            ConfigureAIStepView(state: state, onComplete: onComplete)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            OnboardingStageDino(stage: stage)

            VStack {
                HStack {
                    Spacer(minLength: 0)
                    OnboardingCircleIconButton(systemName: "xmark", action: onClose, accessibilityLabelKey: "Close")
                }
                Spacer(minLength: 0)
            }
            .padding(OnboardingLayout.glassButtonInset)
            .zIndex(5)

            if state.isChoosingModel {
                ConfigureModelChooserModal(state: state)
                    .transition(OnboardingMotion.modalFade)
                    .zIndex(10)
            }
            if state.connectDialog != nil {
                ProviderConnectDialog(state: state)
                    .transition(OnboardingMotion.modalFade)
                    .zIndex(10)
            }
        }
        .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        .animation(OnboardingMotion.smooth, value: state.isChoosingModel)
        .animation(OnboardingMotion.smooth, value: state.connectDialog != nil)
        .ignoresSafeArea()
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                pointer.location = location
                stage.pointerMoved(to: location)
            case .ended:
                pointer.location = nil
            }
        }
    }
}
