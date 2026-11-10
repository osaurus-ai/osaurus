//
//  OnboardingHandoff.swift
//  osaurus
//
//  The move from the onboarding window to the first chat. The onboarding
//  window morphs into the chat's compact frame and the chat crossfades in
//  on top of it. Under Reduce Motion it is a plain crossfade.
//

import AppKit

@MainActor
enum OnboardingHandoff {
    /// The first chat window's size before the person resizes it.
    static let compactChatSize = CGSize(width: 960, height: 720)

    /// Centered on `visibleFrame`, never below the chat's minimum, never
    /// larger than the screen.
    static func compactChatFrame(
        in visibleFrame: CGRect,
        minimum: CGSize = ChatShellLayout.minimumWindowSize
    ) -> CGRect {
        let width = min(max(compactChatSize.width, minimum.width), visibleFrame.width)
        let height = min(max(compactChatSize.height, minimum.height), visibleFrame.height)
        return CGRect(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: (visibleFrame.midY - height / 2).rounded(),
            width: width,
            height: height
        )
    }

    /// Runs the handoff and calls `opened` once the chat is up.
    static func run(from window: NSWindow, opened: @escaping @MainActor () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let screen = window.screen ?? NSScreen.main else {
            window.close()
            opened()
            return
        }
        let target = compactChatFrame(in: screen.visibleFrame)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : OnboardingChoreography.time(0.45)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: {
            Task { @MainActor in
                let chatId = ChatWindowManager.shared.createWindow(initialFrame: target)
                let chat = ChatWindowManager.shared.getNSWindow(id: chatId)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = OnboardingChoreography.time(0.35)
                    chat?.animator().alphaValue = 1
                    window.animator().alphaValue = 0
                } completionHandler: {
                    Task { @MainActor in
                        window.close()
                        opened()
                    }
                }
                if reduceMotion { chat?.alphaValue = 1 }
            }
        }
    }
}
