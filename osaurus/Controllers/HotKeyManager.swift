//
//  HotKeyManager.swift
//  osaurus
//
//  Created by Terence on 10/26/25.
//

import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
  static let shared = HotKeyManager()
  private var monitor: Any?
  private var localMonitor: Any?
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private var action: (() -> Void)?

  func registerOptionSpace(_ handler: @escaping () -> Void) {
    unregister()
    monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
      if event.modifierFlags.contains(.option), event.keyCode == kVK_Space {
        handler()
      }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.modifierFlags.contains(.option), event.keyCode == kVK_Space {
        handler()
        return nil
      }
      return event
    }
  }

  func registerControlC(_ handler: @escaping () -> Void) {
    unregister()
    action = handler

    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = OSType(0x4F53_5553)  // 'OSUS'
    hotKeyID.id = UInt32(1)
    let mods: UInt32 = UInt32(controlKey)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_C), mods, hotKeyID, GetEventDispatcherTarget(), UInt32(0), &ref)
    if status == noErr { hotKeyRef = ref }

    var eventSpec = EventTypeSpec(
      eventClass: OSType(UInt32(kEventClassKeyboard)), eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    let handler: EventHandlerUPP = { _, event, userData in
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
      if err == noErr && hkID.signature == OSType(0x4F53_5553) {
        if let userData {
          let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
          Task { @MainActor in manager.action?() }
        }
      }
      return noErr
    }
    var refHandler: EventHandlerRef?
    let installStatus = InstallEventHandler(
      GetEventDispatcherTarget(), handler, 1, &eventSpec, selfPtr, &refHandler)
    if installStatus == noErr { eventHandlerRef = refHandler }
  }

  func registerControlShiftC(_ handler: @escaping () -> Void) {
    unregister()
    action = handler

    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = OSType(0x4F53_5553)  // 'OSUS'
    hotKeyID.id = UInt32(2)
    let mods: UInt32 = UInt32(controlKey) | UInt32(shiftKey)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_C), mods, hotKeyID, GetEventDispatcherTarget(), UInt32(0), &ref)
    if status == noErr { hotKeyRef = ref }

    var eventSpec = EventTypeSpec(
      eventClass: OSType(UInt32(kEventClassKeyboard)), eventKind: UInt32(kEventHotKeyPressed))
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
      if err == noErr && hkID.signature == OSType(0x4F53_5553) {
        if let userData {
          let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
          Task { @MainActor in manager.action?() }
        }
      }
      return noErr
    }
    var refHandler: EventHandlerRef?
    let installStatus = InstallEventHandler(
      GetEventDispatcherTarget(), handlerUPP, 1, &eventSpec, selfPtr, &refHandler)
    if installStatus == noErr { eventHandlerRef = refHandler }
  }

  func unregister() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
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

  func registerCommandSemicolon(_ handler: @escaping () -> Void) {
    unregister()
    action = handler

    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = OSType(0x4F53_5553)  // 'OSUS'
    hotKeyID.id = UInt32(3)
    let mods: UInt32 = UInt32(cmdKey)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_Semicolon), mods, hotKeyID, GetEventDispatcherTarget(), UInt32(0), &ref)
    if status == noErr { hotKeyRef = ref }

    var eventSpec = EventTypeSpec(
      eventClass: OSType(UInt32(kEventClassKeyboard)), eventKind: UInt32(kEventHotKeyPressed))
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
      if err == noErr && hkID.signature == OSType(0x4F53_5553) {
        if let userData {
          let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
          Task { @MainActor in manager.action?() }
        }
      }
      return noErr
    }
    var refHandler: EventHandlerRef?
    let installStatus = InstallEventHandler(
      GetEventDispatcherTarget(), handlerUPP, 1, &eventSpec, selfPtr, &refHandler)
    if installStatus == noErr { eventHandlerRef = refHandler }
  }

  // MARK: - Generic registration using Chat Hotkey model
  func register(hotkey: Hotkey?, handler: @escaping () -> Void) {
    unregister()
    guard let hotkey else { return }
    action = handler

    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = OSType(0x4F53_5553)  // 'OSUS'
    hotKeyID.id = UInt32(100)

    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      hotkey.keyCode, hotkey.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), UInt32(0), &ref)
    if status == noErr { hotKeyRef = ref }

    var eventSpec = EventTypeSpec(
      eventClass: OSType(UInt32(kEventClassKeyboard)), eventKind: UInt32(kEventHotKeyPressed))
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
      if err == noErr && hkID.signature == OSType(0x4F53_5553) {
        if let userData {
          let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
          Task { @MainActor in manager.action?() }
        }
      }
      return noErr
    }
    var refHandler: EventHandlerRef?
    let installStatus = InstallEventHandler(
      GetEventDispatcherTarget(), handlerUPP, 1, &eventSpec, selfPtr, &refHandler)
    if installStatus == noErr { eventHandlerRef = refHandler }
  }
}
