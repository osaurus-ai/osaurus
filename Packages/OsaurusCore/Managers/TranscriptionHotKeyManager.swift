//
//  TranscriptionHotKeyManager.swift
//  osaurus
//
//  Manages the global hotkey for activating Transcription Mode.
//  Uses a separate signature from the main chat hotkey to avoid conflicts.
//

import AppKit
import Carbon.HIToolbox

/// Manages global hotkey registration for Transcription Mode
@MainActor
public final class TranscriptionHotKeyManager {
    public static let shared = TranscriptionHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// Unique signature for transcription mode hotkey: 'OTMS' (Osaurus Transcription Mode)
    private let hotKeySignature: OSType = 0x4F54_4D53

    /// Unique ID for transcription hotkey (different from chat hotkey ID 100)
    private let hotKeyID: UInt32 = 200

    private init() {}

    /// Unregister the current hotkey
    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        action = nil
    }

    /// Register a hotkey with the given handler
    /// - Parameters:
    ///   - hotkey: The hotkey configuration (nil to disable)
    ///   - handler: The closure to call when hotkey is pressed
    public func register(hotkey: Hotkey?, handler: @escaping () -> Void) {
        unregister()
        guard let hotkey else { return }
        action = handler

        var hotKeyIDStruct = EventHotKeyID()
        hotKeyIDStruct.signature = hotKeySignature
        hotKeyIDStruct.id = hotKeyID

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotKeyIDStruct,
            GetEventDispatcherTarget(),
            UInt32(0),
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            print("[TranscriptionHotKeyManager] Failed to register hotkey: \(status)")
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(UInt32(kEventClassKeyboard)),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerUPP: EventHandlerUPP = { _, event, userData in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let size = MemoryLayout.size(ofValue: hkID)
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                size,
                nil,
                &hkID
            )
            // Check signature matches our transcription hotkey
            if err == noErr && hkID.signature == 0x4F54_4D53 && hkID.id == 200 {
                if let userData {
                    let manager = Unmanaged<TranscriptionHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in manager.action?() }
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }
        var refHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            handlerUPP,
            1,
            &eventSpec,
            selfPtr,
            &refHandler
        )
        if installStatus == noErr {
            eventHandlerRef = refHandler
        } else {
            print("[TranscriptionHotKeyManager] Failed to install event handler: \(installStatus)")
        }
    }
}
