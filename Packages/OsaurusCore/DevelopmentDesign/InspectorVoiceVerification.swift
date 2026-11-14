#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Original production overlay views with local display state only. No audio service is started.
struct InspectorVoiceVerification: View {
    @Environment(\.theme) private var theme
    @State private var state: VoiceInputState = .paused(remaining: 1.5)
    @State private var callbacks = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Chat voice input").font(.headline)
            HStack {
                Button("Idle") { state = .idle }
                Button("Listening") { state = .recording }
                Button("Countdown") { state = .paused(remaining: 1.5) }
                Button("Processing") { state = .sending }
            }
            VoiceInputOverlay(state: $state, audioLevel: 0.45,
                transcription: "A second line of local transcript.", confirmedText: "Display-only voice sample.",
                silenceDuration: 0.7, silenceTimeoutDuration: 10, silenceTimeoutProgress: 7,
                onCancel: { callbacks += 1 }, onSend: { _ in callbacks += 1 }, onEdit: { callbacks += 1 })
            Text("Transcription Mode · Floating overlay").font(.headline)
            TranscriptionOverlayView(audioLevel: 0.45, isActive: true, showsStopButton: true,
                onDone: { callbacks += 1 }, onCancel: { callbacks += 1 })
            TranscriptionOverlayView(audioLevel: 0, isActive: false, isProcessing: true,
                onDone: { callbacks += 1 }, onCancel: { callbacks += 1 })
        }
        .id(theme.inspectionRevision)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
