//
//  ResponsiveTypography.swift
//  osaurus
//
//  Scales font sizes based on container width for comfortable reading
//

import SwiftUI

enum Typography {
  static func scale(for width: CGFloat) -> CGFloat {
    // Map 640→1.0, 1024→1.15, 1400→1.25
    let clamped = max(640.0, min(1400.0, width))
    let s = (clamped - 640.0) / (1400.0 - 640.0)
    return 1.0 + s * 0.25
  }

  static func title(_ width: CGFloat) -> Font {
    .system(size: 18 * scale(for: width), weight: .semibold, design: .rounded)
  }

  static func body(_ width: CGFloat) -> Font { .system(size: 15 * scale(for: width)) }

  static func small(_ width: CGFloat) -> Font { .system(size: 13 * scale(for: width)) }

  static func code(_ width: CGFloat) -> Font {
    .system(size: 14 * scale(for: width), weight: .regular, design: .monospaced)
  }
}
