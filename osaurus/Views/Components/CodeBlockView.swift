//
//  CodeBlockView.swift
//  osaurus
//

import AppKit
import SwiftUI

struct CodeBlockView: View {
  let code: String
  let language: String?
  let baseWidth: CGFloat
  @State private var copied = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      ScrollView(.horizontal, showsIndicators: true) {
        Text(code)
          .font(Typography.code(baseWidth))
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(codeBackground)
      }

      HStack(spacing: 6) {
        if let language, !language.isEmpty {
          Text(language.uppercased())
            .font(.system(size: 9))
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        Button(action: copy) {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy code")
      }
      .padding(8)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.08)))
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { copied = false }
  }
}

private var codeBackground: Color {
  let theme = ThemeManager.shared.currentTheme
  return theme.codeBlockBackground
}
