//
//  ServerSettingsHelpers.swift
//  osaurus
//
//  Shared SwiftUI helpers for the Server → Settings tab. The repeated
//  "string-state-mirrors-an-optional-Int/Double" boilerplate that used
//  to live inline in every section now lives here as
//  `OptionalIntField` / `OptionalDoubleField` / `OptionalStringField`,
//  along with the small `SectionStatus` / `PlannedSubsectionBanner`
//  badge rows that mark each section's bridging state.
//

import SwiftUI

// MARK: - Section status row

/// Section heading row that pairs a `ServerSettingsStatusBadge` with a
/// one-line explanation of how the section's controls feed the runtime.
struct ServerSettingsSectionStatus: View {
    let status: ServerSettingsStatusBadge.Status
    let blurb: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ServerSettingsStatusBadge(status: status)
            Text(LocalizedStringKey(blurb), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
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
