#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// The production composer with local callbacks. This exercises appearance and
/// draft editing without starting a model request or changing any real session.
struct InspectorComposerVerification: View {
    var includeActionChecks = false
    var includeChipChecks = false
    var includeAttachmentChecks = false
    @State private var pendingSkill: UUID?
    @State private var text = ""
    @State private var draftGeneration = 0
    @State private var model: String?
    @State private var attachments: [Attachment] = []
    @State private var continuousVoice = false
    @State private var voice: VoiceInputState = .idle
    @State private var overlay = false
    @State private var options: [String: ModelOptionValue] = [:]
    @State private var queued: QueuedSend?
    @State private var phase = "Idle"
    @State private var sendCount = 0
    @State private var stopCount = 0
    @State private var queueCount = 0
    @State private var nowCount = 0
    @State private var lastSent = ""
    @StateObject private var folder = ChatFolderState()

    private var lock: ComposerLock? {
        phase == "Locked" ? .agentOffline(agentName: "Local fixture", ownerName: nil, lastSeen: nil) : nil
    }
    var body: some View {
        SettingsSection(title: "Native composer states", layout: .plain, verbatimTitle: true) {
            Picker("Composer phase", selection: $phase) {
                ForEach(["Idle", "Sending", "Queued", "Review", "Locked"], id: \.self) { value in
                    Text(verbatim: value).tag(value)
                }
            }
            HStack {
                SettingsButton(.secondary, "Fill local draft", verbatim: true) {
                    text = "A local draft with two lines.\nThe original native text editor remains in use."
                    draftGeneration += 1
                }
                SettingsButton(.secondary, "Clear local draft", verbatim: true) { text = ""; draftGeneration += 1 }
            }
            if includeAttachmentChecks {
                SettingsButton(.secondary, "Add local attachments", verbatim: true) {
                    attachments = InspectorAttachmentSamples.items
                }
                SettingsButton(.secondary, "Show local media metadata", verbatim: true) {
                    // Chip labels read metadata only. No media decoding, blob-store
                    // hydration, encryption keys or model request is involved.
                    attachments = [
                        .audio(Data(repeating: 0, count: 4096), format: "wav", filename: "Local-audio.wav"),
                        .video(Data(repeating: 0, count: 8192), filename: "Local-video.mp4"),
                        Attachment(kind: .audioRef(hash: "inspector-unread-audio", byteCount: 16384,
                            format: "ogg", filename: "Stored-audio.ogg")),
                        Attachment(kind: .videoRef(hash: "inspector-unread-video", byteCount: 32768,
                            filename: "Stored-video.mp4"))
                    ]
                }
            }
            if includeChipChecks {
                SettingsButton(.secondary, "Add existing local skill", verbatim: true) {
                    pendingSkill = SkillManager.shared.skills.first?.id
                }
            }
            FloatingInputCard(text: $text, selectedModel: $model, pendingAttachments: $attachments,
                isContinuousVoiceMode: $continuousVoice, voiceInputState: $voice, showVoiceOverlay: $overlay,
                pickerItems: [], activeModelOptions: $options, isStreaming: ["Sending", "Queued", "Review"].contains(phase),
                isPrivacyReviewSheetVisible: phase == "Review",
                supportsImages: false, estimatedContextTokens: 0,
                onSend: { value in
                    if phase == "Sending" {
                        queueCount += 1
                        queued = QueuedSend(text: value ?? text, attachments: [], oneOffSkillId: nil)
                        phase = "Queued"
                    } else { sendCount += 1; lastSent = value ?? text }
                },
                onStop: { stopCount += 1; phase = "Idle" },
                pendingSkillId: $pendingSkill, queuedSend: $queued,
                onSendNow: { nowCount += 1; sendCount += 1; lastSent = queued?.text ?? ""; queued = nil; phase = "Idle" },
                onCancelQueued: { queued = nil }, modelPin: .remoteAgent,
                pinnedModelLabel: "Local verification", composerLock: lock, isRemoteAgentRun: true,
                folderState: folder)
                .environment(\.composerGeneration, draftGeneration)
            if includeActionChecks { InspectorComposerVoiceActionVerification() }
            Text(verbatim: "Uses the actual app composer. Send and Stop only record local callbacks; no model request is made.")
                .font(SettingsFont.caption)
        }
        .onChange(of: phase) { _, value in
            if value == "Queued" {
                if queued == nil { queued = QueuedSend(text: "Existing local queue", attachments: [], oneOffSkillId: nil) }
            } else { queued = nil }
        }
    }
}
#endif
