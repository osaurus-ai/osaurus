//
//  ServerSettingsHelpers.swift
//  osaurus
//
//  Shared SwiftUI helpers for the Server → Settings tab:
//
//  • `ServerSettingsCard` — the consistent card wrapper used by every
//    section. Pulls title + icon from `ServerSettingsSection` and only
//    surfaces a status chip for `needsBridge` / `future` controls.
//  • `ServerSettingsPlannedBanner` — inline "Planned" callout used
//    inside `SettingsSubsection`s to flag fields vmlx persists today
//    but Osaurus doesn't yet bridge.
//  • `OptionalIntField` / `OptionalDoubleField` / `OptionalStringField`
//    — boilerplate-killing wrappers around `StyledSettingsTextField`
//    for the (very common) "text input mirrors an `Optional<T>` binding"
//    pattern.
//

import SwiftUI

// MARK: - Section card

/// Card wrapper used by every Server → Settings section. Renders a
/// proper card header (title + subtitle), only surfacing the
/// engineering-state status chip when the controls aren't fully wired
/// yet (`partial`, `needsBridge`, `future`).
///
/// `status` of `.engineReady` or `.hostOwned` is the common case and
/// shows no chip — the title speaks for itself. Partial, Planned, or
/// Future cards get the inline chip so the user knows which changes
/// take effect today.
struct ServerSettingsCard<Content: View>: View {
    let section: ServerSettingsSection
    let status: ServerSettingsStatusBadge.Status
    let blurb: String
    var spacing: CGFloat = 18
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme

    private var shouldShowChip: Bool {
        switch status {
        case .partial, .needsBridge, .future: return true
        case .engineReady, .hostOwned: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20)

                Text(LocalizedStringKey(section.title), bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                if shouldShowChip {
                    ServerSettingsStatusBadge(status: status)
                }

                Spacer(minLength: 0)
            }

            if !blurb.isEmpty {
                Text(LocalizedStringKey(blurb), bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
        }
    }
}

/// Inline "Planned" callout used inside `SettingsSubsection`s to flag
/// fields that vmlx persists today but Osaurus does not yet bridge.
struct ServerSettingsPlannedBanner: View {
    let blurb: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ServerSettingsStatusBadge(status: .needsBridge)
            Text(LocalizedStringKey(blurb), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }
}

// MARK: - Optional value text fields

/// `StyledSettingsTextField` wrapper that mirrors a `Binding<Int?>`.
/// Empty input clears the binding; non-numeric input is ignored.
/// `clamp` (optional) caps parsed values to the supplied range.
struct OptionalIntField: View {
    let label: String
    let placeholder: String
    let help: String
    @Binding var value: Int?
    var clamp: ClosedRange<Int>? = nil

    @State private var text: String = ""
    @State private var initialized: Bool = false

    var body: some View {
        StyledSettingsTextField(
            label: label,
            text: $text,
            placeholder: placeholder,
            help: help
        )
        .onAppear {
            guard !initialized else { return }
            initialized = true
            text = Self.stringValue(value)
        }
        .onChange(of: value) { _, newValue in
            let desired = Self.stringValue(newValue)
            if text != desired { text = desired }
        }
        .onChange(of: text) { _, _ in commit() }
    }

    private static func stringValue(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if value != nil { value = nil }
            return
        }
        guard let parsed = Int(trimmed) else { return }
        let final: Int = {
            guard let clamp else { return parsed }
            return min(max(parsed, clamp.lowerBound), clamp.upperBound)
        }()
        if value != final { value = final }
    }
}

/// `StyledSettingsTextField` wrapper that mirrors a `Binding<Double?>`.
/// Empty input clears the binding; non-numeric input is ignored.
/// `clamp` (optional) caps parsed values to the supplied range.
/// `format` (optional) controls how the bound value renders back into
/// the text field; defaults to `String(value)`.
struct OptionalDoubleField: View {
    let label: String
    let placeholder: String
    let help: String
    @Binding var value: Double?
    var clamp: ClosedRange<Double>? = nil
    var format: String? = nil

    @State private var text: String = ""
    @State private var initialized: Bool = false

    var body: some View {
        StyledSettingsTextField(
            label: label,
            text: $text,
            placeholder: placeholder,
            help: help
        )
        .onAppear {
            guard !initialized else { return }
            initialized = true
            text = stringValue(value)
        }
        .onChange(of: value) { _, newValue in
            let desired = stringValue(newValue)
            if text != desired { text = desired }
        }
        .onChange(of: text) { _, _ in commit() }
    }

    private func stringValue(_ value: Double?) -> String {
        guard let value else { return "" }
        if let format { return String(format: format, value) }
        return String(value)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if value != nil { value = nil }
            return
        }
        guard let parsed = Double(trimmed) else { return }
        let final: Double = {
            guard let clamp else { return parsed }
            return min(max(parsed, clamp.lowerBound), clamp.upperBound)
        }()
        if value != final { value = final }
    }
}

/// `StyledSettingsTextField` wrapper that mirrors a `Binding<String?>`.
/// Empty input clears the binding.
struct OptionalStringField: View {
    let label: String
    let placeholder: String
    let help: String
    @Binding var value: String?

    @State private var text: String = ""
    @State private var initialized: Bool = false

    var body: some View {
        StyledSettingsTextField(
            label: label,
            text: $text,
            placeholder: placeholder,
            help: help
        )
        .onAppear {
            guard !initialized else { return }
            initialized = true
            text = value ?? ""
        }
        .onChange(of: value) { _, newValue in
            let desired = newValue ?? ""
            if text != desired { text = desired }
        }
        .onChange(of: text) { _, _ in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized: String? = trimmed.isEmpty ? nil : trimmed
            if value != normalized { value = normalized }
        }
    }
}
