//
//  AgentRuntimesView.swift
//  osaurus
//
//  Settings → Runtimes: the external harnesses (Claude Code, Pi over RPC, and
//  Pi-based wrappers) an agent can run on instead of Osaurus's own loop.
//

import AppKit
import SwiftUI

struct AgentRuntimesView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var store = HarnessRuntimeStore.shared
    @ObservedObject private var agentManager = AgentManager.shared

    @State private var isCreating = false
    @State private var editingRuntime: HarnessRuntime?
    @State private var signInRuntime: HarnessRuntime?
    @State private var pendingDelete: HarnessRuntime?
    @State private var showDeleteAlert = false
    @State private var testing: Set<UUID> = []
    @State private var testResults: [UUID: HarnessProbeResult] = [:]

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Agent Runtimes",
                subtitle: "External agent harnesses, like Claude Code or Pi, that run an agent's chats. Pick one in an agent's Configure tab.",
                count: store.runtimes.count,
                primary: {
                    SettingsButton(.primary, "Add Runtime", icon: "plus") {
                        isCreating = true
                    }
                    .settingsLandingAnchor("agentRuntimes.add")
                }
            )
        } content: {
            if store.runtimes.isEmpty {
                SettingsEmptyState(
                    inline: "terminal",
                    title: "No runtimes yet",
                    hint: "Add Claude Code, Pi, or a Pi-based harness to run agents on it."
                )
            } else {
                SettingsGroup {
                    ForEach(store.runtimes) { runtime in
                        runtimeRow(runtime)
                    }
                }
                .settingsLandingAnchor("agentRuntimes.list")
            }

            SettingsCallout(
                icon: "lock.shield",
                title: "Runs with your account's access",
                message:
                    "Each chat gets its own process in the chat's folder, and the harness brings its own model, tools, and history. Osaurus can scope Claude Code's file edits to the chat folder, but it can't confine shell commands or a Pi harness's tools."
            )
            .settingsLandingAnchor("agentRuntimes.safety")
        }
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { store.loadIfNeeded() }
        .sheet(isPresented: $isCreating) {
            HarnessRuntimeEditorSheet(runtime: nil) { save($0) }
                .environment(\.theme, themeManager.currentTheme)
        }
        .sheet(item: $editingRuntime) { runtime in
            HarnessRuntimeEditorSheet(runtime: runtime) { save($0) }
                .environment(\.theme, themeManager.currentTheme)
        }
        .sheet(item: $signInRuntime) { runtime in
            ClaudeCodeSetupStep(
                onBack: { signInRuntime = nil },
                onDone: {
                    signInRuntime = nil
                    runTest(runtime)
                },
                runtime: runtime
            )
            .frame(width: SettingsSheetWidth.regular, height: 560)
            .environment(\.theme, themeManager.currentTheme)
        }
        .themedAlert(
            L("Delete this runtime?"),
            isPresented: $showDeleteAlert,
            message: deleteMessage,
            buttons: [
                .cancel(L("Cancel")) { pendingDelete = nil },
                .destructive(L("Delete")) {
                    if let runtime = pendingDelete { delete(runtime) }
                    pendingDelete = nil
                },
            ]
        )
    }

    // MARK: - Rows

    private func runtimeRow(_ runtime: HarnessRuntime) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            LibraryRow(
                title: runtime.displayName,
                subtitle: commandLine(runtime),
                monospacedSubtitle: true,
                action: { editingRuntime = runtime }
            ) {
                SettingsIconTile(icon: "terminal.fill", size: 32)
            } badges: {
                if runtime.displayName != runtime.kind.displayName {
                    StatusChip(runtime.kind.displayName)
                }
                StatusChip(usageLabel(runtime))
            } trailing: {
                if runtime.kind == .claudeCode {
                    SettingsButton(
                        .secondary,
                        "Sign In",
                        size: .compact,
                        help: "Check or start Claude Code's sign-in"
                    ) { signInRuntime = runtime }
                }
                SettingsButton(
                    .secondary,
                    "Test",
                    isLoading: testing.contains(runtime.id),
                    size: .compact,
                    help: "Start this runtime once to check that a chat can launch it"
                ) { runTest(runtime) }
                .disabled(testing.contains(runtime.id))
            } menu: {
                Button(L("Edit")) { editingRuntime = runtime }
                Divider()
                Button(L("Delete"), role: .destructive) {
                    pendingDelete = runtime
                    showDeleteAlert = true
                }
            }

            if runtime.kind == .piRPC, !runtime.resumesSessions {
                SettingsFindingRow(
                    severity: .warning,
                    title: L(
                        "Chats start over when the process restarts. Add --session-id {chat_id} to the arguments to resume them."
                    )
                )
            }
            if let result = testResults[runtime.id] {
                SettingsFindingRow(
                    severity: severity(of: result),
                    title: result.message,
                    detail: result.resolvedExecutable
                )
            }
        }
    }

    private func severity(of result: HarnessProbeResult) -> SettingsFindingRow.Severity {
        switch result.status {
        case .ready: return .ok
        case .needsSetup: return .warning
        case .failed: return .blocked
        }
    }

    // MARK: - Helpers

    private func commandLine(_ runtime: HarnessRuntime) -> String {
        ([runtime.executable] + runtime.arguments).map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }

    private func agentsUsing(_ runtime: HarnessRuntime) -> [String] {
        agentManager.agents
            .filter { agentManager.effectiveRuntime(for: $0.id).harnessId == runtime.id }
            .map(\.name)
    }

    private func usageLabel(_ runtime: HarnessRuntime) -> String {
        let names = agentsUsing(runtime)
        switch names.count {
        case 0: return L("Not used by any agent")
        case 1: return String(format: L("Used by %@"), names[0])
        default: return String(format: L("Used by %d agents"), names.count)
        }
    }

    private var deleteMessage: String {
        guard let runtime = pendingDelete else { return "" }
        let names = agentsUsing(runtime)
        if names.isEmpty {
            return String(format: L("%@ will be removed."), runtime.displayName)
        }
        return String(
            format: L("%@ will be removed. %@ will stop working until you pick another runtime for them."),
            runtime.displayName,
            names.joined(separator: ", ")
        )
    }

    // MARK: - Actions

    private func save(_ runtime: HarnessRuntime) {
        store.upsert(runtime)
        testResults[runtime.id] = nil
        Task { await HarnessSessionManager.shared.closeIdleSessions(runtimeId: runtime.id) }
    }

    private func delete(_ runtime: HarnessRuntime) {
        store.remove(id: runtime.id)
        testResults[runtime.id] = nil
        Task { await HarnessSessionManager.shared.closeIdleSessions(runtimeId: runtime.id) }
    }

    private func runTest(_ runtime: HarnessRuntime) {
        guard !testing.contains(runtime.id) else { return }
        testing.insert(runtime.id)
        testResults[runtime.id] = nil
        Task {
            let result = await HarnessRuntimeProbe.run(runtime)
            testing.remove(runtime.id)
            testResults[runtime.id] = result
        }
    }
}

// MARK: - Editor

struct HarnessRuntimeEditorSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let runtime: HarnessRuntime?
    let onSave: (HarnessRuntime) -> Void

    @State private var name = ""
    @State private var kind: HarnessKind = .piRPC
    @State private var executable = ""
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var errors: [String] = []

    private var isEditing: Bool { runtime != nil }

    var body: some View {
        SettingsSheet(
            icon: "terminal.fill",
            title: isEditing ? "Edit Runtime" : "Add Runtime",
            width: SettingsSheetWidth.regular,
            maxBodyHeight: 520,
            primary: .init(label: isEditing ? "Save" : "Add Runtime", handler: save),
            secondary: .init(label: "Cancel") { dismiss() },
            onClose: { dismiss() }
        ) {
            SettingsFieldRow(
                label: "Protocol",
                hint: kind == .piRPC
                    ? L("Pi, or any harness built on Pi, driven over its RPC mode.")
                    : L("Your signed-in Claude Code CLI, driven over stream-json."),
                verbatimHint: true
            ) {
                AssignedBaseSegmentedPicker(
                    selection: $kind,
                    options: HarnessKind.allCases.map { .init($0, $0.displayName, verbatim: true) }
                )
                .fixedSize()
                .accessibilityLabel(Text("Protocol", bundle: .module))
                .disabled(isEditing)
                .onChange(of: kind) { old, new in applyKindDefaults(from: old, to: new) }
            }

            SettingsFieldRow(label: "Name") {
                SettingsTextField(placeholder: L("e.g. Spotlight"), text: $name)
            }

            SettingsFieldRow(label: "Executable", hint: "A command on your PATH, or a full path. ~ is allowed.") {
                HStack(spacing: theme.space.s8) {
                    SettingsTextField(placeholder: kind.defaultExecutable, text: $executable, monospaced: true)
                    SettingsButton(.secondary, "Choose…") { chooseExecutable() }
                }
            }

            SettingsFieldRow(label: "Arguments", hint: argumentsHint, verbatimHint: true) {
                SettingsTextEditor(
                    text: $argumentsText,
                    placeholder: kind == .piRPC ? "--mode\nrpc" : nil,
                    minHeight: 64,
                    maxHeight: 110,
                    monospaced: true
                )
            }

            SettingsFieldRow(
                label: "Environment",
                hint:
                    "One KEY=value per line. Saved unencrypted, so don't put API keys here; sign in through the harness instead. Osaurus sets the OSAURUS_* variables itself."
            ) {
                SettingsTextEditor(
                    text: $environmentText,
                    placeholder: "KEY=value",
                    minHeight: 64,
                    maxHeight: 110,
                    monospaced: true,
                    isInvalid: !errors.isEmpty
                )
            }

            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    ForEach(errors, id: \.self) { error in
                        SettingsFindingRow(severity: .blocked, title: error)
                    }
                }
            } else if let warning = argumentWarning {
                SettingsFindingRow(severity: .warning, title: warning)
            }
        }
        .onAppear(perform: load)
    }

    private var argumentsHint: String {
        let usage =
            kind == .piRPC
            ? L(
                "One argument per line. Keep --mode rpc, and --session-id {chat_id} so chats resume after a restart. The agent's system prompt is passed with --append-system-prompt unless the arguments place {system_prompt_file} themselves. Narrow its tools with --tools."
            )
            : L(
                "One argument per line, added after the flags Osaurus sets (model, session, permissions). Usually empty."
            )
        return usage + "\n" + L("Placeholders: {chat_id}, {agent_id}, {cwd}, {system_prompt_file}.")
    }

    // MARK: - Parsing

    private var parsedArguments: [String] {
        argumentsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var argumentWarning: String? {
        guard kind == .piRPC else { return nil }
        let args = parsedArguments
        if let index = args.firstIndex(of: "--mode"), args.indices.contains(index + 1), args[index + 1] == "rpc" {
            return nil
        }
        if args.contains("--mode=rpc") { return nil }
        return L("The arguments don't include --mode rpc. That's fine only if this command starts in RPC mode on its own.")
    }

    private func parseEnvironment() -> (values: [String: String], errors: [String]) {
        var values: [String: String] = [:]
        var errors: [String] = []
        for rawLine in environmentText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else {
                errors.append(String(format: L("\"%@\" isn't KEY=value."), line))
                continue
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            let validKey =
                !key.isEmpty && key.first.map { $0 == "_" || $0.isLetter } == true
                && key.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
            guard validKey else {
                errors.append(String(format: L("\"%@\" isn't a valid variable name."), key))
                continue
            }
            if key.uppercased().hasPrefix("OSAURUS_") {
                errors.append(String(format: L("%@ is set by Osaurus and can't be overridden."), key))
                continue
            }
            values[key] = value
        }
        return (values, errors)
    }

    // MARK: - Actions

    private func load() {
        guard let runtime else {
            applyKindDefaults(from: nil, to: kind)
            return
        }
        name = runtime.name
        kind = runtime.kind
        executable = runtime.executable
        argumentsText = runtime.arguments.joined(separator: "\n")
        environmentText = runtime.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    /// A new runtime follows the protocol's defaults until the user edits them.
    private func applyKindDefaults(from old: HarnessKind?, to new: HarnessKind) {
        guard !isEditing else { return }
        let trimmedExecutable = executable.trimmingCharacters(in: .whitespaces)
        if trimmedExecutable.isEmpty || trimmedExecutable == old?.defaultExecutable {
            executable = new.defaultExecutable
        }
        if parsedArguments.isEmpty || parsedArguments == old?.defaultArguments {
            argumentsText = new.defaultArguments.joined(separator: "\n")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty || trimmedName == old?.displayName {
            name = new.displayName
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        executable = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func save() {
        var problems: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { problems.append(L("Give the runtime a name.")) }
        if trimmedExecutable.isEmpty { problems.append(L("Enter the command to run.")) }
        let environment = parseEnvironment()
        problems += environment.errors
        guard problems.isEmpty else {
            errors = problems
            return
        }

        var saved = runtime ?? HarnessRuntime(name: trimmedName, kind: kind)
        saved.name = trimmedName
        saved.kind = kind
        saved.executable = trimmedExecutable
        saved.arguments = parsedArguments
        saved.environment = environment.values
        onSave(saved)
        dismiss()
    }
}
