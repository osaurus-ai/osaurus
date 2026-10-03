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
    var anchorId: String? = nil

    @State private var text: String = ""
    @State private var initialized: Bool = false

    var body: some View {
        StyledSettingsTextField(
            label: label,
            text: $text,
            placeholder: placeholder,
            help: help,
            anchorId: anchorId,
            onEditingChanged: { editing in
                if !editing { text = Self.stringValue(value) }
            }
        )
        .onAppear {
            guard !initialized else { return }
            initialized = true
            text = Self.stringValue(value)
        }
        .onChange(of: value) { _, newValue in
            let desired = OptionalIntFieldEditing.reconcile(text, value: newValue, clamp: clamp)
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

/// Decimal input is buffered until Return, focus loss, or the form's Save.
/// Invalid/non-finite input restores the existing bound value on commit.
struct OptionalDoubleField: View {
    let label: String
    let placeholder: String
    let help: String
    @Binding var value: Double?
    var clamp: ClosedRange<Double>? = nil
    var format: String? = nil

    @Environment(\.optionalDoubleFieldCommitter) private var committer
    @State private var editor = OptionalDoubleFieldEditing()
    @State private var fieldID = UUID()
    @State private var initialized = false

    var body: some View {
        StyledSettingsTextField(
            label: label,
            text: Binding(
                get: { editor.text },
                set: { text in
                    editor.edit(text)
                    updatePendingCommit()
                }
            ),
            placeholder: placeholder,
            help: help,
            onEditingChanged: { editing in
                if editing { editor.beginEditing() } else { commit() }
            }
        )
        .onSubmit { commit() }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            editor.reset(value: value, format: format)
        }
        .onChange(of: value) { _, newValue in
            editor.receive(value: newValue, format: format)
            committer?.clear(id: fieldID)
        }
        .onDisappear { commit() }
    }

    private func updatePendingCommit() {
        committer?.setPending(
            id: fieldID,
            changed: editor.text != OptionalDoubleFieldEditing.stringValue(value, format: format),
            commit: { commit() },
            discard: { editor.reset(value: value, format: format) }
        )
    }

    private func commit() {
        let next = editor.commit(value: value, clamp: clamp, format: format)
        if value != next { value = next }
        committer?.clear(id: fieldID)
    }
}

/// The editing draft never changes or clamps the numeric value before commit.
struct OptionalDoubleFieldEditing {
    private(set) var text = ""
    private(set) var isEditing = false

    mutating func beginEditing() { isEditing = true }

    mutating func edit(_ text: String) {
        self.text = text
        isEditing = true
    }

    mutating func receive(value: Double?, format: String?) {
        // The binding only changes on commit or through an external authority.
        // External Reset/model changes replace an old draft rather than later
        // allowing it to overwrite the new value.
        reset(value: value, format: format)
    }

    mutating func reset(value: Double?, format: String?) {
        text = Self.stringValue(value, format: format)
        isEditing = false
    }

    mutating func commit(value: Double?, clamp: ClosedRange<Double>?, format: String?) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: Double?
        if trimmed.isEmpty {
            next = nil
        } else if let parsed = Double(trimmed), parsed.isFinite {
            next = clamp.map { min(max(parsed, $0.lowerBound), $0.upperBound) } ?? parsed
        } else {
            next = value
        }
        reset(value: next, format: format)
        return next
    }

    static func stringValue(_ value: Double?, format: String?) -> String {
        guard let value else { return "" }
        return format.map { String(format: $0, value) } ?? String(value)
    }
}

/// A focused decimal draft must participate in Save/Reset before its binding changes.
@MainActor
final class OptionalDoubleFieldCommitter: ObservableObject {
    @Published private(set) var hasPendingChanges = false
    private var owner: UUID?
    private var commitDraft: (() -> Void)?
    private var discardDraft: (() -> Void)?

    /// Save may flush a correction whose binding still contains the old invalid
    /// value. The form must validate again after commit, before persistence.
    func blocksSaveAttempt(hasBlockingIssues: Bool) -> Bool {
        hasBlockingIssues && !hasPendingChanges
    }

    func setPending(id: UUID, changed: Bool, commit: @escaping () -> Void, discard: @escaping () -> Void) {
        guard changed else { clear(id: id); return }
        owner = id
        commitDraft = commit
        discardDraft = discard
        hasPendingChanges = true
    }

    func clear(id: UUID) {
        guard owner == id else { return }
        owner = nil
        commitDraft = nil
        discardDraft = nil
        hasPendingChanges = false
    }

    func commit() {
        let action = commitDraft
        if let owner { clear(id: owner) }
        action?()
    }

    func discard() {
        let action = discardDraft
        if let owner { clear(id: owner) }
        action?()
    }
}

private struct OptionalDoubleFieldCommitterKey: EnvironmentKey {
    static let defaultValue: OptionalDoubleFieldCommitter? = nil
}

extension EnvironmentValues {
    var optionalDoubleFieldCommitter: OptionalDoubleFieldCommitter? {
        get { self[OptionalDoubleFieldCommitterKey.self] }
        set { self[OptionalDoubleFieldCommitterKey.self] = newValue }
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

/// Binding echoes must not replace a partially typed number with its clamped
/// value. The binding remains valid immediately (including Save while focused);
/// leaving the field canonicalizes the display. A different external value still
/// replaces the draft.
enum OptionalIntFieldEditing {
    static func reconcile(_ text: String, value: Int?, clamp: ClosedRange<Int>?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, value == nil { return text }
        if let parsed = Int(trimmed) {
            let resolved = clamp.map { min(max(parsed, $0.lowerBound), $0.upperBound) } ?? parsed
            if resolved == value { return text }
        }
        return value.map(String.init) ?? ""
    }
}
