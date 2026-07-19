import ApplicationServices
import Foundation

enum SelectionAssistantAction: String, CaseIterable, Identifiable, Sendable {
    case summarize
    case rewrite
    case extractActions
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summarize: L("Summarize")
        case .rewrite: L("Rewrite")
        case .extractActions: L("Extract actions")
        case .ask: L("Ask")
        }
    }

    var systemImage: String {
        switch self {
        case .summarize: "text.alignleft"
        case .rewrite: "pencil.line"
        case .extractActions: "checklist"
        case .ask: "bubble.left"
        }
    }

    var instruction: String {
        switch self {
        case .summarize:
            L("Summarize the attached selection.")
        case .rewrite:
            L("Rewrite the attached selection. Preserve its meaning and return only the revised text.")
        case .extractActions:
            L("Extract the concrete action items from the attached selection.")
        case .ask:
            L("Help me with the attached selection.")
        }
    }
}

/// Reads a frontmost app's selected text without changing the pasteboard.
///
/// When a source app is known, unsupported or unverifiable accessibility
/// trees fail closed. Synthetic copy is reserved for the rare case where no
/// source application can be identified, because copying from an unverified
/// focused element could expose secure or otherwise private content.
@MainActor
final class NativeSelectionCapture {
    enum Result: Equatable, Sendable {
        case captured(String)
        case permissionDenied
        case secureField
        case unverifiedField
        case noSelection
        case tooLarge(byteLimit: Int)
        case unavailable
    }

    struct Dependencies {
        var read: @Sendable (pid_t) async -> Result
    }

    nonisolated static let maximumUTF8Bytes = 256 * 1024

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func live() -> NativeSelectionCapture {
        NativeSelectionCapture(
            dependencies: Dependencies { pid in
                await Task.detached(priority: .userInitiated) {
                    readSynchronously(pid: pid)
                }.value
            }
        )
    }

    static func unsupported() -> NativeSelectionCapture {
        NativeSelectionCapture(dependencies: Dependencies { _ in .unavailable })
    }

    func capture(pid: pid_t) async -> Result {
        await dependencies.read(pid)
    }

    nonisolated static func isSecure(
        role: String?,
        subrole: String?,
        roleDescription: String? = nil
    ) -> Bool {
        AccessibilityTextPolicy.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: roleDescription
        )
    }

    nonisolated private static func readSynchronously(pid: pid_t) -> Result {
        guard AXIsProcessTrusted() else { return .permissionDenied }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return .unavailable
        }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, 0.25)

        let role = stringAttribute(kAXRoleAttribute, from: focused)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused)
        let roleDescription = stringAttribute(kAXRoleDescriptionAttribute, from: focused)
        guard !isSecure(role: role, subrole: subrole, roleDescription: roleDescription) else {
            return .secureField
        }
        guard AccessibilityTextPolicy.canReadSelection(
            role: role,
            subrole: subrole,
            roleDescription: roleDescription
        ) else {
            return .unverifiedField
        }

        var selectedValue: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedStatus == .success else {
            return .unverifiedField
        }
        guard let selectedText = selectedValue as? String else { return .unverifiedField }
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noSelection
        }
        let byteCount = selectedText.utf8.count
        guard byteCount <= maximumUTF8Bytes else {
            return .tooLarge(byteLimit: maximumUTF8Bytes)
        }
        return .captured(selectedText)
    }

    nonisolated private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
