//
//  HuggingFaceDeepLinkAlert.swift
//  osaurus
//
//  The alert shown when a Hugging Face model link (`huggingface://?model=`
//  or `osaurus://open_from_hf?model=`) cannot be opened. Shared by the
//  AppDelegate link handler and by the token card's post-save retry so the
//  wording and the "Add Token…" offer stay the same on both paths.
//

import AppKit
import Foundation

@MainActor
enum HuggingFaceDeepLinkAlert {
    enum Choice {
        case dismissed
        /// The user chose "Add Token…" on the unauthorized alert.
        case addToken
    }

    /// Presents the alert for a failed resolution and returns what the user
    /// chose. Runs modally; the hang watchdog is paused for the wait.
    @discardableResult
    static func present(_ resolution: ModelManager.DeepLinkResolution, modelId: String) -> Choice {
        let alert = NSAlert()
        var offersToken = false

        switch resolution {
        case .model:
            return .dismissed

        case .unsupported(.unauthorized):
            // Private (or mistyped) repo and no usable token. Offer the
            // token sheet instead of calling the repo "not MLX".
            alert.messageText = L("Hugging Face token needed")
            alert.informativeText = L(
                "Hugging Face would not show \(modelId) without a token. If it is a private or gated repository, add a Hugging Face token for an account that has access and Osaurus will open the model. If you did not expect that, check the repository id."
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("Add Token…"))
            alert.addButton(withTitle: L("Cancel"))
            offersToken = true

        case .unsupported(.notFound):
            alert.messageText = L("Model not found")
            alert.informativeText = L("Hugging Face has no repository called \(modelId).")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")

        case .unsupported(.rateLimited):
            alert.messageText = L("Hugging Face rate limit")
            alert.informativeText = L(
                "Hugging Face is rate-limiting anonymous requests from this Mac. Add a free Hugging Face token under Local Models, or try again in a minute."
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")

        case .unsupported(.unreachable):
            alert.messageText = L("Hugging Face unreachable")
            alert.informativeText = L(
                "Osaurus could not reach huggingface.co to check \(modelId). Check your connection and open the link again."
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")

        case .unsupported(.notMLX):
            alert.messageText = L("Unsupported model")
            alert.informativeText = L(
                "Osaurus supports MLX-compatible Hugging Face repositories, including MLX, MXFP, JANG, JANGTQ, and TurboQuant artifacts when required files are present."
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")

        case .registryGated:
            alert.messageText = L("Not in the Osaurus catalog")
            alert.informativeText = L(
                "\(modelId) is an OsaurusAI repository that is not part of the language-model catalog, so it cannot be opened here."
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
        }

        // `runModal` intentionally blocks the main run loop until the user
        // dismisses the alert; pause the hang watchdog so the wait isn't
        // reported as an app hang (Sentry APPLE-MACOS-VE).
        let response = CrashReportingService.shared.withAppHangTrackingPaused { alert.runModal() }
        return (offersToken && response == .alertFirstButtonReturn) ? .addToken : .dismissed
    }
}
