import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CUAFormsSettingsModel: ObservableObject {
    @Published var configuration = CUAFormsConfiguration() {
        didSet {
            guard !loading else { return }
            dirty = true
            invalidate()
        }
    }
    @Published private(set) var dirty = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var apps: [CUAppListing] = []
    @Published private(set) var windows: [CUWindowInfo] = []
    @Published var selectedPID: Int32? { didSet { invalidate() } }
    @Published var selectedWindowID: Int? { didSet { invalidate() } }
    @Published private(set) var plan: CUAFormPlan?
    @Published var selectedDecisions = Set<UUID>()
    private let store = CUAFormContextStore()
    private let driver = NativeMacDriver()
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var loading = false

    var profileIndex: Int? {
        configuration.profiles.firstIndex { $0.id == configuration.selectedProfileID }
    }

    var canPreview: Bool {
        configuration.enabled && !dirty && !busy && profileIndex != nil
            && configuration.modelDirectory != nil && selectedPID != nil && selectedWindowID != nil
    }

    func load() async {
        do {
            let config = try await store.load()
            loading = true
            configuration = config
            loading = false
            dirty = false
            status = L("Profiles stay local and are not shared with agents. Nothing is submitted automatically.")
        } catch { status = error.localizedDescription }
    }

    func save() {
        guard !busy else { return }
        let config = configuration
        start { [weak self] in
            guard let self else { return }
            try await self.store.save(config)
            if self.configuration == config { self.dirty = false }
            self.status = L("Form context saved locally.")
        }
    }

    func newProfile() {
        guard configuration.profiles.count < 16 else {
            status = L("At most 16 form-context profiles are supported.")
            return
        }
        let profile = CUAFormProfile(name: "Profile \(configuration.profiles.count + 1)")
        configuration.profiles.append(profile)
        configuration.selectedProfileID = profile.id
    }

    func deleteProfile() {
        guard let index = profileIndex else { return }
        configuration.profiles.remove(at: index)
        configuration.selectedProfileID = configuration.profiles.first?.id
    }

    func importDocument(_ url: URL) {
        guard let index = profileIndex, !busy else { return }
        let id = configuration.profiles[index].id
        start { [weak self] in
            let fields = try await CUAFormContextImport.document(url)
            guard let self, let current = self.configuration.profiles.firstIndex(where: { $0.id == id }) else { return }
            guard self.configuration.profiles[current].entities.count + fields.count <= 64 else {
                throw CUAFormsError.invalid("Import would exceed 64 fields; remove unneeded fields first.")
            }
            // This edit invalidates old plans, but does not cancel its own
            // completed extraction or persist unreviewed document candidates.
            self.loading = true
            self.configuration.profiles[current].entities.append(contentsOf: fields)
            self.loading = false
            self.dirty = true
            self.plan = nil
            self.status = L(
                "Review imported fields, resolve duplicate labels, then save. No inferred values were added."
            )
        }
    }

    func refreshApps() {
        guard !busy else { return }
        invalidate()
        start { [weak self] in
            guard let self else { return }
            self.apps = await self.driver.listApps().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.status = L("Choose the app and exact form window.")
        }
    }

    func refreshWindows() async {
        selectedWindowID = nil
        guard let pid = selectedPID else { windows = []; return }
        let result = await driver.listWindows(pid: pid)
        guard selectedPID == pid else { return }
        windows = result
    }

    func preview() {
        guard canPreview, let index = profileIndex, let directory = configuration.modelDirectory,
            let app = apps.first(where: { $0.pid == selectedPID }),
            let window = windows.first(where: { $0.windowId == selectedWindowID })
        else { return }
        let profile = configuration.profiles[index]
        invalidate()
        start { [weak self] in
            guard let self else { return }
            let scorer = try CUAFormsScorer(directory: URL(fileURLWithPath: directory, isDirectory: true))
            let plan = try await CUAFormsPlanner.preview(
                profile: profile,
                target: CUAFormTarget(app: app, window: window),
                driver: self.driver,
                scorer: scorer
            )
            try Task.checkCancellation()
            self.plan = plan
            // Text fills are selected for review. Agreements/checks require a
            // separate explicit selection; model-scored buttons are never eligible.
            self.selectedDecisions = Set(
                plan.decisions.filter {
                    if case .fill = $0.action { return $0.canApply }
                    return false
                }.map(\.id)
            )
            self.status = String(
                format: L("Scored %d elements in %.1f ms. Review every selected value before filling."),
                plan.decisions.count,
                plan.scoringSeconds * 1000
            )
        }
    }

    func applyConfirmed() {
        guard configuration.enabled, !dirty, !busy, let plan else { return }
        let selected = selectedDecisions
        start { [weak self] in
            guard let self else { return }
            let report = await CUAFormsExecutor.apply(
                plan: plan,
                selected: selected,
                confirmed: true,
                driver: self.driver,
                enabled: { [weak self] in
                    await MainActor.run { self?.configuration.enabled == true && self?.dirty == false }
                },
                policy: { await MainActor.run { ComputerUsePolicyStore.load() } }
            )
            self.plan = nil
            self.selectedDecisions.removeAll()
            self.status = report.summary
        }
    }

    func cancel() {
        operation?.cancel()
        plan = nil
        selectedDecisions.removeAll()
        // Keep busy until the operation acknowledges cancellation; don't let
        // another run overlap an in-flight AX mutation or extraction.
        if busy { status = L("Stopping; any already-applied changes remain in the form.") }
    }

    func invalidate() { cancel() }

    private func start(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        let id = UUID()
        operationID = id
        operation = Task {
            defer { if operationID == id { busy = false; operation = nil } }
            do { try await body() } catch is CancellationError {
                status = L("Cancelled. Inspect any already-applied changes before retrying.")
            } catch { status = error.localizedDescription }
        }
    }
}

struct CUAFormsSettingsView: View {
    private enum ImportKind { case scorer, document }

    @StateObject private var model = CUAFormsSettingsModel()
    @State private var importing = false
    @State private var importKind = ImportKind.scorer
    @State private var confirmFill = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                contextEditor
                targetPicker
                if let plan = model.plan { preview(plan) }
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).textSelection(.enabled)
                        .accessibilityIdentifier("forms.status")
                    Spacer()
                    if model.busy { Button(L("Stop")) { model.cancel() } }
                }
            }
            .padding(24)
        }
        .task { await model.load() }
        .task(id: model.selectedPID) { await model.refreshWindows() }
        .onDisappear { model.cancel() }
        // One presenter for both choices. Two fileImporter modifiers on this
        // same view leave only the last one active on macOS (the document
        // picker opened, but Choose scorer folder did nothing in the live app).
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: importKind == .scorer
                ? [.folder] : [.pdf, .plainText, UTType(filenameExtension: "docx") ?? .data]
        ) { result in
            if case .success(let url) = result {
                switch importKind {
                case .scorer: model.configuration.modelDirectory = url.path
                case .document: model.importDocument(url)
                }
            }
        }
        .alert(L("Fill selected fields?"), isPresented: $confirmFill) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Fill without submitting")) { model.applyConfirmed() }
        } message: {
            Text(
                L(
                    "Only the selected previewed values and checkboxes will be applied to the named window. Nothing will be submitted. Review sensitive information first."
                )
            )
        }
        .alert(L("Delete this form profile?"), isPresented: $confirmDelete) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Delete"), role: .destructive) { model.deleteProfile() }
        } message: {
            Text(L("Save changes to persist the deletion. Source documents will not be deleted."))
        }
    }

    private var intro: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("Enable experimental forms"), isOn: $model.configuration.enabled)
                    .accessibilityIdentifier("forms.enabled")
                    .settingsLandingAnchor("computerUse.forms.enabled")
                Text(
                    L(
                        "CUA S1 Forms matches fields to values you provide. This is not a chat or vision model. English labels work best; predictions need review."
                    )
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(
                    L(
                        "Profiles are local, unencrypted files. They are not sent to agents or telemetry. Do not store passwords or payment credentials."
                    )
                )
                .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(L("Choose scorer folder…")) {
                        importKind = .scorer
                        importing = true
                    }
                    Text(model.configuration.modelDirectory ?? L("No scorer selected"))
                        .font(.caption).lineLimit(2).textSelection(.enabled)
                }
                .disabled(model.busy)
                .settingsLandingAnchor("computerUse.forms.model")
                Text(
                    L(
                        "Choose a converted CUA S1 safetensors folder with config.json. Python .pt checkpoints are not executed by the app."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Label(L("Forms (Experimental)"), systemImage: "rectangle.and.pencil.and.ellipsis")
        }
    }

    private var contextEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker(L("Context profile"), selection: $model.configuration.selectedProfileID) {
                        Text(L("Choose a profile")).tag(UUID?.none)
                        ForEach(model.configuration.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button(L("New profile")) { model.newProfile() }
                    Button(L("Delete profile"), role: .destructive) { confirmDelete = true }
                        .disabled(model.profileIndex == nil)
                }
                if let index = model.profileIndex {
                    TextField(L("Profile name"), text: $model.configuration.profiles[index].name)
                        .accessibilityIdentifier("forms.profileName")
                    ForEach($model.configuration.profiles[index].entities) { $entity in
                        HStack(alignment: .top) {
                            TextField(L("Field label"), text: $entity.label).frame(width: 160)
                            TextField(L("Field value"), text: $entity.value)
                            Button {
                                model.configuration.profiles[index].entities.removeAll { $0.id == entity.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .accessibilityLabel(L("Remove field"))
                        }
                    }
                    HStack {
                        Button(L("Add field")) {
                            model.configuration.profiles[index].entities.append(CUAFormEntity(label: "", value: ""))
                        }.disabled(model.configuration.profiles[index].entities.count >= 64)
                        Button(L("Import PDF or text…")) {
                            importKind = .document
                            importing = true
                        }
                    }
                    Text(
                        L(
                            "Imports extract Label: value lines only, without OCR or invented values. Review before saving. The scorer sees at most 96 UTF-8 bytes of each option; the preview shows the full value that will be filled."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Save form context")) { model.save() }
                        .buttonStyle(.borderedProminent).disabled(!model.dirty)
                    if model.dirty { Text(L("Unsaved changes — preview is disabled")).font(.caption) }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(model.busy)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Text(L("Form context profiles"))
        }
        .settingsLandingAnchor("computerUse.forms.context")
    }

    private var targetPicker: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(L("Refresh apps")) { model.refreshApps() }
                    Picker(L("Target app"), selection: $model.selectedPID) {
                        Text(L("Choose an app")).tag(Int32?.none)
                        ForEach(model.apps, id: \.pid) { Text("\($0.name) (\($0.pid))").tag(Optional($0.pid)) }
                    }
                }
                Picker(L("Target window"), selection: $model.selectedWindowID) {
                    Text(L("Choose a window")).tag(Int?.none)
                    ForEach(model.windows, id: \.windowId) {
                        Text("\($0.title ?? L("Untitled")) (#\($0.windowId))").tag(Optional($0.windowId))
                    }
                }
                Button(L("Preview form matches")) { model.preview() }.disabled(!model.canPreview)
                Text(
                    L(
                        "Accessibility permission is required. Existing Computer Use allowlists and autonomy policy still apply. No submit buttons, password fields, dropdown selection or keyboard fallbacks are executed."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.busy || !model.configuration.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Text(L("Form preview and fill"))
        }
        .settingsLandingAnchor("computerUse.forms.preview")
    }

    private func preview(_ plan: CUAFormPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(plan.target.app.name) — \(plan.target.window.title ?? "")")
                    .font(.headline).textSelection(.enabled)
                Text(plan.profileName).font(.caption)
                ForEach(plan.decisions) { decision in
                    Toggle(
                        isOn: Binding(
                            get: { model.selectedDecisions.contains(decision.id) },
                            set: {
                                if $0 {
                                    model.selectedDecisions.insert(decision.id)
                                } else {
                                    model.selectedDecisions.remove(decision.id)
                                }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                "\(decision.element.label ?? decision.element.role) — \(Int(decision.probability * 100))%"
                            )
                            Text(actionDescription(decision)).font(.caption).textSelection(.enabled)
                            if let old = decision.element.value, !old.isEmpty {
                                Text(String(format: L("Current: %@"), old))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!decision.canApply || model.busy)
                }
                Button(L("Fill selected fields…")) { confirmFill = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.selectedDecisions.isEmpty || model.busy || model.dirty || !model.configuration.enabled
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Text(L("Review proposed changes"))
        }
    }

    private func actionDescription(_ decision: CUAFormDecision) -> String {
        let action: String
        switch decision.action {
        case .fill(let field): action = "\(field.label): \(field.value)"
        case .check: action = L("Check this box (requires your explicit selection)")
        case .click: action = L("Click predicted — blocked; submission is never automatic")
        case .skip: action = L("Skip — no change")
        }
        return decision.canApply ? action : action + " · " + L("Not eligible for apply")
    }
}
