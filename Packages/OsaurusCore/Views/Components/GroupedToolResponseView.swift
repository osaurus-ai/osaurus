//
//  GroupedToolResponseView.swift
//  osaurus
//
//  Collapsible UI to display assistant tool calls and their results, grouped under a message.
//

import SwiftUI

struct GroupedToolResponseView: View {
  let calls: [ToolCall]
  let resultsById: [String: String]
  @State private var isExpanded: Bool = false
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(spacing: 8) {
      header
      if isExpanded { content }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(theme.secondaryBackground.opacity(0.7))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.glassEdgeLight.opacity(0.35), lineWidth: 1)
        )
    )
  }

  private var header: some View {
    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
      HStack(spacing: 8) {
        Image(systemName: "wrench.and.screwdriver")
          .foregroundColor(theme.secondaryText)
        Text("Tools (\(calls.count))")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(theme.secondaryText)
        Spacer()
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(theme.tertiaryText)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var content: some View {
    VStack(spacing: 8) {
      ForEach(Array(calls.enumerated()), id: \.0) { (_, call) in
        ToolCallRow(call: call, result: resultsById[call.id])
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(theme.primaryBackground.opacity(0.6))
          )
      }
    }
  }
}

private struct ToolCallRow: View {
  let call: ToolCall
  let result: String?
  @State private var showArgs: Bool = false
  @State private var showResult: Bool = true
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(call.function.name)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(theme.primaryText)
        Spacer()
        if result == nil {
          ProgressView().scaleEffect(0.6)
        }
      }

      HStack(spacing: 8) {
        Button(action: { withAnimation { showArgs.toggle() } }) {
          Label(showArgs ? "Hide args" : "Show args", systemImage: "curlybraces.square")
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .foregroundColor(theme.secondaryText)

        if result != nil {
          Button(action: { withAnimation { showResult.toggle() } }) {
            Label(showResult ? "Hide result" : "Show result", systemImage: "doc.text")
          }
          .font(.system(size: 11, weight: .medium))
          .buttonStyle(.plain)
          .foregroundColor(theme.secondaryText)
        }
      }

      if showArgs {
        CodeBlock(text: prettyJSON(call.function.arguments))
      }
      if showResult, let result {
        CodeBlock(text: result)
      }
    }
  }

  private func prettyJSON(_ raw: String) -> String {
    guard let data = raw.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
    else { return raw }
    return String(data: pretty, encoding: .utf8) ?? raw
  }
}

private struct CodeBlock: View {
  let text: String
  @Environment(\.theme) private var theme

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Text(text)
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundColor(theme.primaryText)
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.codeBlockBackground)
        )
        .textSelection(.enabled)
    }
  }
}
