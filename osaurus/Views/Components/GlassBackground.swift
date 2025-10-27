//
//  GlassBackground.swift
//  osaurus
//
//  HUD-style glass background using NSVisualEffectView (.hudWindow)
//

import AppKit
import SwiftUI

struct GlassBackground: NSViewRepresentable {
  var cornerRadius: CGFloat = 16

  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    v.wantsLayer = true
    v.layer?.cornerRadius = cornerRadius
    v.layer?.masksToBounds = true
    return v
  }

  func updateNSView(_ v: NSVisualEffectView, context: Context) {
    // No dynamic updates required for now
  }
}
