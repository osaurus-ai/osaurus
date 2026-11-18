//
//  OnboardingKeep.swift
//  osaurus
//
//  Turning on a default workflow from a discovery card. It creates the
//  automation through the same plan and approval card as `osaurus_config`,
//  then asks for the macOS permissions it will need while the person is
//  here.
//

import Foundation

enum OnboardingKeep {
    enum Outcome: Equatable, Sendable {
        case turnedOn
        case declined
        case failed(String)

        var telemetryName: String {
            switch self {
            case .turnedOn: return "taken"
            case .declined: return "declined"
            case .failed: return "failed"
            }
        }
    }

    static let saveNoteId = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000324")!

    /// Who configuration history credits with an automation turned on here.
    static let historyCaller = ConfigChangeCaller.other("Setup")

    /// The automation an offer turns on, and how the offer says when it runs.
    /// `workflowId` is the default workflow's template id; the entry names
    /// the installed copy, which has its own id.
    @MainActor
    static func automation(workflowId: UUID, name: String) -> (entry: EventEntry, when: String)? {
        guard let schedule = schedule(workflowId: workflowId) else { return nil }
        var entry = EventEntry(name: name)
        entry.enabled = true
        entry.source = schedule.source
        entry.workflow = (OnboardingPaths.installed(workflowId)?.id ?? workflowId).uuidString
        return (entry, schedule.when)
    }

    /// When a default workflow runs on its own, by template id.
    static func schedule(workflowId: UUID) -> (source: EventSourceEntry, when: String)? {
        var source = EventSourceEntry()
        let when: String
        switch workflowId {
        case OnboardingPaths.morningBriefId:
            source.kind = EventSourceKind.schedule.rawValue
            source.frequency = "cron"
            source.frequencyValue = "0 8 * * 1-5"
            when = L("on weekday mornings")
        case OnboardingPaths.meetingPrepId:
            source.kind = EventSourceKind.schedule.rawValue
            source.frequency = "cron"
            source.frequencyValue = "30 7 * * 1-5"
            when = L("early on weekday mornings")
        case OnboardingPaths.mailTriageId:
            source.kind = EventSourceKind.schedule.rawValue
            source.frequency = "cron"
            source.frequencyValue = "0 15 * * 1-5"
            when = L("on weekday afternoons")
        case OnboardingPaths.newDownloadId:
            source.kind = EventSourceKind.folder.rawValue
            source.path = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
            when = L("when a file lands in Downloads")
        case OnboardingPaths.endOfDayId:
            source.kind = EventSourceKind.schedule.rawValue
            source.frequency = "cron"
            source.frequencyValue = "0 18 * * 1-5"
            when = L("on weekday evenings")
        case TeamSeeder.repoDigestTemplateID:
            source.kind = EventSourceKind.schedule.rawValue
            source.frequency = "cron"
            source.frequencyValue = "0 16 * * 5"
            when = L("on Friday afternoons")
        default:
            return nil
        }
        return (source, when)
    }

    /// Plans the automation, raises the approval card, and applies it.
    @MainActor
    static func turnOn(_ entry: EventEntry) async -> Outcome {
        var document = OsaurusConfigDocument()
        document.automations = [entry]
        let plan: ConfigPlan
        do {
            plan = try ConfigPlanner.plan(document: document, prune: false)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard !plan.isEmpty else { return .turnedOn }
        guard await ConfigApprovalService.requestApproval(plan: plan, prune: false) == .approved else {
            return .declined
        }
        let results = await ConfigApplier.apply(document: document, prune: false, caller: historyCaller)
        if let failure = results.first(where: { $0.status == .failed }) {
            return .failed(failure.message ?? failure.target)
        }
        return .turnedOn
    }

    /// The macOS permissions a default workflow's tool steps need, in step
    /// order, by template id.
    @MainActor
    static func permissions(forWorkflow id: UUID) -> [SystemPermission] {
        guard let workflow = OnboardingPaths.installed(id) else { return [] }
        var permissions: [SystemPermission] = []
        for ref in workflow.definition.nodes.flatMap(\.calledTools) {
            for permission in AppleApp.app(forTool: ref.name)?.systemPermissions ?? []
            where !permissions.contains(permission) {
                permissions.append(permission)
            }
        }
        return permissions
    }

    /// Asks for the grants an automation will need while the person is here.
    @MainActor
    static func requestGrants(
        forWorkflow id: UUID,
        isGranted: (SystemPermission) -> Bool,
        request: (SystemPermission) async -> Bool,
        readDownloads: () async -> Bool
    ) async {
        for permission in permissions(forWorkflow: id) where !isGranted(permission) {
            _ = await request(permission)
        }
        if id == OnboardingPaths.newDownloadId { _ = await readDownloads() }
    }
}
