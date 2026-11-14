//
//  AgentRuntimesView.swift
//  osaurus
//
//  Agents → Runtimes: the external harnesses (Claude Code, Pi over RPC, and
//  Pi-based wrappers) an agent can run on instead of Osaurus's own loop.
//

import AppKit
import SwiftUI

struct AgentRuntimesView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var store = HarnessRuntimeStore.shared
    @ObservedObject private var agentManager = AgentManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var isCreating = false
    @State private var editingRuntime: HarnessRuntime?
    @State private var signInRuntime: HarnessRuntime?
    @State private var pendingDelete: HarnessRuntime?
    @State private var showDeleteAlert = false
    @State private var testing: Set<UUID> = []
    @State private var testResults: [UUID: HarnessProbeResult] = [:]

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    aboutCard
                    if store.runtimes.isEmpty {
                        emptyCard
                    } else {
                        VStack(spacing: 8) {
                            ForEach(store.runtimes) { runtime in
                                runtimeRow(runtime)
                            }
                        }
                        .settingsLandingAnchor("agentRuntimes.list")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            store.loadIfNeeded()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $isCreating) {
            HarnessRuntimeEditorSheet(runtime: nil) { save($0) }
        }
        .sheet(item: $editingRuntime) { runtime in
            HarnessRuntimeEditorSheet(runtime: runtime) { save($0) }
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
            .frame(width: 520, height: 560)
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

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Agent Runtimes"),
            subtitle: L("External agent harnesses, like Claude Code or Pi, that can run an agent's chats"),
            count: store.runtimes.isEmpty ? nil : store.runtimes.count
        ) {
            HeaderPrimaryButton("Add Runtime", icon: "plus") {
                isCreating = true
            }
            .settingsLandingAnchor("agentRuntimes.add")
        }
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text("How runtimes work", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            Text(
                "Pick a runtime in an agent's Configure tab. Each chat gets its own long-running process in the chat's folder, and Osaurus relays your messages to it. The harness brings its own model, tools, and history.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Runtimes run on this Mac with your account's access. Osaurus can scope Claude Code's file edits to the chat folder, but it can't confine shell commands or a Pi harness's tools.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        )
        .settingsLandingAnchor("agentRuntimes.safety")
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundColor(theme.tertiaryText)
            Text("No runtimes yet", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("Add Claude Code, Pi, or a Pi-based harness to run agents on it.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    // MARK: - Rows

    private func runtimeRow(_ runtime: HarnessRuntime) -> some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.accentColor.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(verbatim: runtime.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text(verbatim: runtime.kind.displayName)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.tertiaryBackground))
                        }
                        Text(verbatim: commandLine(runtime))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(usageLabel(runtime))
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                        if runtime.kind == .piRPC, !runtime.resumesSessions {
                            Text(
                                "Chats start over when the process restarts. Add --session-id {chat_id} to the arguments to resume them.",
                                bundle: .module
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        if runtime.kind == .claudeCode {
                            rowTextButton(L("Sign In")) { signInRuntime = runtime }
                                .localizedHelp("Check or start Claude Code's sign-in")
                        }
                        rowTextButton(L("Test"), busy: testing.contains(runtime.id)) { runTest(runtime) }
                            .localizedHelp("Start this runtime once to check that a chat can launch it")
                        iconButton("pencil", tint: theme.secondaryText) { editingRuntime = runtime }
                            .localizedHelp("Edit runtime")
                        iconButton("trash", tint: theme.errorColor) {
                            pendingDelete = runtime
                            showDeleteAlert = true
                        }
                        .localizedHelp("Delete runtime")
                    }
                }

                if let result = testResults[runtime.id] {
                    testResultView(result)
                }
            }
        }
    }

    private func testResultView(_ result: HarnessProbeResult) -> some View {
        let tint: Color = {
            switch result.status {
            case .ready: return theme.successColor
            case .needsSetup: return theme.warningColor
            case .failed: return theme.errorColor
            }
        }()
        let icon: String = {
            switch result.status {
            case .ready: return "checkmark.circle.fill"
            case .needsSetup: return "exclamationmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }()
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let executable = result.resolvedExecutable {
                    Text(verbatim: executable)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
        .padding(.leading, 48)
    }

    private func rowTextButton(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                } else {
                    Text(verbatim: title).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func iconButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
        }
        .buttonStyle(.plain)
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
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let runtime: HarnessRuntime?
    let onSave: (HarnessRuntime) -> Void

    @State private var name = ""
    @State private var kind: HarnessKind = .piRPC
    @State private var executable = ""
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var errors: [String] = []

    private var theme: ThemeProtocol { themeManager.currentTheme }
    private var isEditing: Bool { runtime != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Runtime" : "Add Runtime", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L("Protocol")) {
                        Picker("", selection: $kind) {
                            ForEach(HarnessKind.allCases) { kind in
                                Text(verbatim: kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(isEditing)
                        .onChange(of: kind) { old, new in applyKindDefaults(from: old, to: new) }
                        hint(
                            kind == .piRPC
                                ? L("Pi, or any harness built on Pi, driven over its RPC mode.")
                                : L("Your signed-in Claude Code CLI, driven over stream-json.")
                        )
                    }

                    field(L("Name")) {
                        textField(L("e.g. Spotlight"), text: $name)
                    }

                    field(L("Executable")) {
                        HStack(spacing: 8) {
                            textField(kind.defaultExecutable, text: $executable, monospaced: true)
                            Button(L("Choose…")) { chooseExecutable() }
                        }
                        hint(L("A command on your PATH, or a full path. ~ is allowed."))
                    }

                    field(L("Arguments")) {
                        textEditor(text: $argumentsText, placeholder: kind == .piRPC ? "--mode\nrpc" : "")
                        hint(
                            kind == .piRPC
                                ? L(
                                    "One argument per line. Keep --mode rpc. Add --session-id {chat_id} so chats resume after a restart, and --append-system-prompt {system_prompt_file} to pass the agent's system prompt. Narrow its tools with --tools."
                                )
                                : L(
                                    "One argument per line, added after the flags Osaurus sets (model, session, permissions). Usually empty."
                                )
                        )
                        hint(L("Placeholders: {chat_id}, {agent_id}, {cwd}, {system_prompt_file}."))
                    }

                    field(L("Environment")) {
                        textEditor(text: $environmentText, placeholder: "KEY=value")
                        hint(
                            L(
                                "One KEY=value per line. Saved unencrypted, so don't put API keys here; sign in through the harness instead. Osaurus sets the OSAURUS_* variables itself."
                            )
                        )
                    }

                    if !errors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(errors, id: \.self) { error in
                                Text(verbatim: error)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.errorColor)
                            }
                        }
                    } else if let warning = argumentWarning {
                        Text(verbatim: warning)
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.3)

            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
                    .buttonStyle(SlashCommandButtonStyle(theme: theme))
                Button { save() } label: { Text(isEditing ? "Save" : "Add Runtime", bundle: .module) }
                    .buttonStyle(SlashCommandButtonStyle(isPrimary: true, theme: theme))
            }
            .padding(16)
        }
        .frame(width: 500, height: 620)
        .background(theme.cardBackground)
        .onAppear(perform: load)
    }

    // MARK: - Building blocks

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textField(_ placeholder: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .foregroundColor(theme.primaryText)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
            )
    }

    private func textEditor(text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty, !placeholder.isEmpty {
                Text(verbatim: placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.placeholderText)
                    .padding(.top, 10)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
        )
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
