//
//  SpaceActions.swift
//  osaurus
//
//  Dock-menu Space actions. Each one records intent in the registry, then
//  restarts Osaurus so `SpaceLauncher` applies it before any service runs.
//  Only deleting a Space that is not open anywhere happens in place.
//

import AppKit
import Foundation
import OsaurusRepository

enum SpaceEditError: Error, Equatable {
    case defaultSpace
    case unknownSpace
    case emptyName
    case duplicateName
    case inUseElsewhere(bundleIds: [String])
}

enum SpaceDeleteMode: Equatable {
    /// The Space was not open; the caller removes it now.
    case immediate
    /// The Space is the current one; it is removed on the next launch.
    case afterRelaunch
}

extension OsaurusSpaceRegistryDocument {
    static let maxSpaceNameLength = 60

    func validatedName(_ raw: String, renaming id: String? = nil) throws -> String {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxSpaceNameLength))
        guard !name.isEmpty else { throw SpaceEditError.emptyName }
        let taken = spaces.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if taken || name.caseInsensitiveCompare(SpaceActions.defaultSpaceName) == .orderedSame {
            throw SpaceEditError.duplicateName
        }
        return name
    }

    /// Registers a new Space and makes it the bundle's active one.
    mutating func createSpace(named raw: String, bundleId: String) throws -> String {
        let name = try validatedName(raw)
        let id = SpaceRegistry.newSpaceId()
        spaces.append(OsaurusSpace(id: id, name: name))
        active[bundleId] = id
        return id
    }

    mutating func renameSpace(_ id: String, to raw: String) throws {
        guard id != SpaceRegistry.defaultSpaceId else { throw SpaceEditError.defaultSpace }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { throw SpaceEditError.unknownSpace }
        spaces[index].name = try validatedName(raw, renaming: id)
    }

    mutating func requestSwitch(to id: String, bundleId: String) throws {
        guard id == SpaceRegistry.defaultSpaceId || space(id: id) != nil else { throw SpaceEditError.unknownSpace }
        active[bundleId] = id
    }

    mutating func requestReset(of id: String, bundleId: String) throws {
        try checkEditable(id, bundleId: bundleId)
        pending[bundleId, default: []].append(OsaurusSpacePendingOperation(kind: .reset, spaceId: id))
    }

    mutating func requestDelete(of id: String, bundleId: String, currentSpaceId: String) throws -> SpaceDeleteMode {
        try checkEditable(id, bundleId: bundleId)
        guard id == currentSpaceId else { return .immediate }
        active[bundleId] = SpaceRegistry.defaultSpaceId
        pending[bundleId, default: []].append(OsaurusSpacePendingOperation(kind: .delete, spaceId: id))
        return .afterRelaunch
    }

    private func checkEditable(_ id: String, bundleId: String) throws {
        guard id != SpaceRegistry.defaultSpaceId else { throw SpaceEditError.defaultSpace }
        guard space(id: id) != nil else { throw SpaceEditError.unknownSpace }
        let others = otherBundlesUsing(spaceId: id, excluding: bundleId)
        guard others.isEmpty else { throw SpaceEditError.inUseElsewhere(bundleIds: others) }
    }
}

@MainActor
enum SpaceActions {
    nonisolated static var defaultSpaceName: String { L("Default Space") }

    static var bundleId: String { SpaceRegistry.currentBundleId }
    static var currentSpaceId: String { SpaceRegistry.activeSpaceId() }

    /// Spaces work only in a normal launch: test-root and keychain-free
    /// proof launches keep their own hermetic roots.
    static var isAvailable: Bool {
        SpaceRegistry.isEnabled && Bundle.main.bundleIdentifier != nil
    }

    static func displayName(of id: String, in document: OsaurusSpaceRegistryDocument?) -> String {
        if id == SpaceRegistry.defaultSpaceId { return defaultSpaceName }
        return document?.space(id: id)?.name ?? defaultSpaceName
    }

    // MARK: - Menu entry points

    static func promptCreate() {
        guard var document = loadForEditing() else { return }
        guard
            let name = promptForName(
                title: L("New Space"),
                message: L(
                    "A Space has its own chats, agents, settings, and saved keys. Osaurus restarts into the new Space and shows setup."
                ),
                confirm: L("Create and Restart"),
                initial: ""
            )
        else { return }
        do {
            _ = try document.createSpace(named: name, bundleId: bundleId)
            try SpaceRegistry.save(document)
        } catch {
            showError(error)
            return
        }
        FeatureTelemetry.spaceCreated()
        relaunch()
    }

    static func promptRenameCurrent() {
        guard var document = loadForEditing() else { return }
        let id = currentSpaceId
        guard
            let name = promptForName(
                title: L("Rename Space"),
                message: L("Choose a new name for this Space."),
                confirm: L("Rename"),
                initial: displayName(of: id, in: document)
            )
        else { return }
        do {
            try document.renameSpace(id, to: name)
            try SpaceRegistry.save(document)
        } catch {
            showError(error)
        }
    }

    static func confirmSwitch(to id: String) {
        guard id != currentSpaceId, var document = loadForEditing() else { return }
        let name = displayName(of: id, in: document)
        guard
            confirm(
                title: L("Switch to “\(name)”?"),
                message: L("Osaurus will quit and reopen in this Space. Running chats and workflows will stop."),
                confirm: L("Switch and Restart"),
                destructive: false
            )
        else { return }
        do {
            try document.requestSwitch(to: id, bundleId: bundleId)
            try SpaceRegistry.save(document)
        } catch {
            showError(error)
            return
        }
        FeatureTelemetry.spaceSwitched()
        relaunch()
    }

    static func confirmResetCurrent() {
        guard var document = loadForEditing() else { return }
        let id = currentSpaceId
        let name = displayName(of: id, in: document)
        guard
            confirm(
                title: L("Reset “\(name)”?"),
                message: L(
                    "This deletes everything in this Space, including its chats, agents, settings, and saved keys, then restarts Osaurus into setup. Other Spaces are not affected."
                ),
                confirm: L("Reset and Restart"),
                destructive: true
            )
        else { return }
        do {
            try document.requestReset(of: id, bundleId: bundleId)
            try SpaceRegistry.save(document)
        } catch {
            showError(error)
            return
        }
        relaunch()
    }

    static func confirmDelete(_ id: String) {
        guard var document = loadForEditing() else { return }
        let name = displayName(of: id, in: document)
        let isCurrent = id == currentSpaceId
        let message =
            isCurrent
            ? L(
                "This permanently deletes the Space and everything in it, including its saved keys. Osaurus will restart in the Default Space."
            )
            : L("This permanently deletes the Space and everything in it, including its saved keys.")
        guard confirm(title: L("Delete “\(name)”?"), message: message, confirm: L("Delete"), destructive: true)
        else { return }
        do {
            let mode = try document.requestDelete(of: id, bundleId: bundleId, currentSpaceId: currentSpaceId)
            if mode == .immediate {
                SpaceLauncher.removeSpace(id, from: &document)
            }
            try SpaceRegistry.save(document)
            FeatureTelemetry.spaceDeleted(mode: mode == .immediate ? "immediate" : "after_relaunch")
            if mode == .afterRelaunch { relaunch() }
        } catch {
            showError(error)
        }
    }

    static func revealCurrentInFinder() {
        let root = OsaurusPaths.root()
        OsaurusPaths.ensureExistsSilent(root)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - Relaunch

    /// Starts a helper that reopens the app once this process has exited
    /// (giving up after 60 s), then quits through the normal teardown.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script =
            "i=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt 300 ]; do /bin/sleep 0.2; i=$((i+1)); done; "
            + "/usr/bin/open \"$1\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "osaurus-space-relaunch", Bundle.main.bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment[SpaceRegistry.activeSpaceEnvironmentKey] = nil
        helper.environment = environment
        do {
            try helper.run()
        } catch {
            print("[Spaces] Could not start the relaunch helper: \(error)")
        }
        // A run-loop callout, not a main-queue task: see the terminate note
        // in `OnboardingService.performFactoryReset`.
        RunLoop.main.perform(inModes: [.common]) {
            CrashReportingService.shared.withAppHangTrackingPaused {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Dialogs

    private static func loadForEditing() -> OsaurusSpaceRegistryDocument? {
        do {
            return try SpaceRegistry.load() ?? OsaurusSpaceRegistryDocument()
        } catch {
            showMessage(
                title: L("Spaces could not be read"),
                message: L("Fix or remove \(SpaceRegistry.registryFile().path), then try again.")
            )
            return nil
        }
    }

    private static func promptForName(title: String, message: String, confirm: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = L("Space name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard run(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func confirm(title: String, message: String, confirm: String, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .informational
        alert.messageText = title
        alert.informativeText = message
        let button = alert.addButton(withTitle: confirm)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: L("Cancel"))
        return run(alert) == .alertFirstButtonReturn
    }

    private static func showError(_ error: Error) {
        let message: String
        switch error as? SpaceEditError {
        case .emptyName:
            message = L("Enter a name for the Space.")
        case .duplicateName:
            message = L("Another Space already uses that name.")
        case .defaultSpace:
            message = L("The Default Space can't be changed this way.")
        case .unknownSpace:
            message = L("That Space no longer exists.")
        case .inUseElsewhere(let bundleIds):
            message = L(
                "This Space is open in another Osaurus app (\(bundleIds.joined(separator: ", "))). Switch that app to a different Space first."
            )
        case nil:
            message = error.localizedDescription
        }
        showMessage(title: L("Couldn't update Spaces"), message: message)
    }

    private static func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        _ = run(alert)
    }

    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return CrashReportingService.shared.withAppHangTrackingPaused { alert.runModal() }
    }
}
