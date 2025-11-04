//
//  ToolsManagerView.swift
//  osaurus
//
//  Manage chat tools: search and toggle enablement.
//

import AppKit
import Foundation
import SwiftUI

struct ToolsManagerView: View {
  @StateObject private var themeManager = ThemeManager.shared
  @Environment(\.theme) private var theme

  @State private var searchText: String = ""
  @State private var toolEntries: [ToolRegistry.ToolEntry] = []

  var body: some View {
    VStack(spacing: 0) {
      headerView
      Divider()
      contentView
    }
    .frame(minWidth: 720, minHeight: 600)
    .background(theme.primaryBackground)
    .environment(\.theme, themeManager.currentTheme)
    .onAppear { reload() }
    .onChange(of: searchText) { _, _ in reload() }
  }

  private var headerView: some View {
    HStack(spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Tools")
          .font(.system(size: 24, weight: .semibold))
          .foregroundColor(theme.primaryText)

        Text("Manage available tools for chat")
          .font(.system(size: 13))
          .foregroundColor(theme.secondaryText)
      }

      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
  }

  private var contentView: some View {
    VStack(spacing: 0) {
      // Search bar
      HStack(spacing: 12) {
        Spacer()
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 14))
            .foregroundColor(theme.tertiaryText)

          TextField("Search tools", text: $searchText)
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 14))
            .foregroundColor(theme.primaryText)

          if !searchText.isEmpty {
            Button(action: { searchText = "" }) {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 240)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(theme.tertiaryBackground)
        )
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(theme.secondaryBackground)

      ScrollView {
        LazyVStack(spacing: 12) {
          if filteredEntries.isEmpty {
            Text("No tools match your search")
              .font(.system(size: 13))
              .foregroundColor(theme.secondaryText)
              .padding(.vertical, 40)
          } else {
            ForEach(filteredEntries) { entry in
              toolRow(entry)
            }
          }
        }
        .padding(24)
      }
    }
  }

  private func toolRow(_ entry: ToolRegistry.ToolEntry) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.name)
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(theme.primaryText)
        Text(entry.description)
          .font(.system(size: 12))
          .foregroundColor(theme.secondaryText)
      }
      Spacer()
      Toggle(
        isOn: Binding(
          get: { entry.enabled },
          set: { newValue in
            ToolRegistry.shared.setEnabled(newValue, for: entry.name)
            reload()
          }
        )
      ) {
        Text("")
      }
      .toggleStyle(SwitchToggleStyle())
      .labelsHidden()
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(theme.tertiaryBackground)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(theme.glassEdgeLight.opacity(0.25), lineWidth: 1)
        )
    )
  }

  private var filteredEntries: [ToolRegistry.ToolEntry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return toolEntries }
    return toolEntries.filter { e in
      let candidates = [e.name.lowercased(), e.description.lowercased()]
      let q = query.lowercased()
      return candidates.contains { SearchService.fuzzyMatch(query: q, in: $0) }
    }
  }

  private func reload() {
    toolEntries = ToolRegistry.shared.listTools()
  }
}

#Preview {
  ToolsManagerView()
}
