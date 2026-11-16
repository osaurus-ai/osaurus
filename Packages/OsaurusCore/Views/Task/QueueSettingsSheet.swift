//
//  QueueSettingsSheet.swift
//  osaurus
//
//  Creates or edits one queue: how many of its tasks run at once, how many
//  may wait, what happens when it is full, the order they start in, and
//  pause. Default can be tuned but not renamed or deleted.
//

import SwiftUI

struct QueueSettingsSheet: View {
    /// nil creates a new queue.
    let queue: TaskQueue?
    let onClose: () -> Void

    @State private var name: String
    @State private var maxConcurrent: Int
    @State private var maxWaiting: Int
    @State private var overflow: TaskOverflowPolicy
    @State private var ordering: TaskOrderingMode
    @State private var paused: Bool
    private var store: TaskStore { .shared }

    init(queue: TaskQueue?, onClose: @escaping () -> Void) {
        self.queue = queue
        self.onClose = onClose
        let policy = queue?.policy ?? TaskQueuePolicy()
        _name = State(initialValue: queue?.name ?? "")
        _maxConcurrent = State(initialValue: policy.maxConcurrent)
        _maxWaiting = State(initialValue: policy.maxPending ?? 0)
        _overflow = State(initialValue: policy.overflow)
        _ordering = State(initialValue: policy.orderingMode)
        _paused = State(initialValue: policy.paused)
    }

    private var isSystem: Bool { queue?.isSystem == true }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameConflict: Bool {
        guard !trimmedName.isEmpty, let match = store.queue(named: trimmedName) else { return false }
        return match.id != queue?.id
    }

    var body: some View {
        SettingsSheet(
            icon: "tray.2",
            title: queue == nil ? "Add Queue" : LocalizedStringKey(queue?.name ?? ""),
            subtitle: isSystem ? "Tasks without a queue of their own run here." : nil,
            width: SettingsSheetWidth.regular,
            primary: .init(
                label: queue == nil ? "Add Queue" : "Save Changes",
                isEnabled: (isSystem || !trimmedName.isEmpty) && !nameConflict,
                handler: save),
            secondary: .init(label: "Cancel", handler: onClose),
            warning: nameConflict ? L("A queue with this name already exists.") : nil,
            onClose: onClose
        ) {
            if !isSystem {
                SettingsSection(title: "Queue") {
                    SettingsTextFieldRow(
                        label: "Name",
                        text: $name,
                        placeholder: L("Research"),
                        help: L("Automations pick a queue by this name."))
                }
            }

            SettingsSection(title: "Limits") {
                SettingsStepperRow(
                    label: "Max Concurrent Tasks",
                    help: L("How many of this queue's tasks run at the same time."),
                    value: $maxConcurrent,
                    range: 1 ... TaskQueuePolicy.maxConcurrentCeiling,
                    anchorId: "tasks.queue.maxConcurrent")
                SettingsStepperRow(
                    label: "Max Waiting Tasks",
                    help: maxWaiting == 0
                        ? L("No limit on how many tasks wait for a turn.")
                        : L("Up to \(maxWaiting) tasks wait for a turn."),
                    value: $maxWaiting,
                    range: 0 ... TaskQueuePolicy.maxPendingCeiling,
                    anchorId: "tasks.queue.maxWaiting")
                if maxWaiting > 0 {
                    SettingsPickerRow(
                        title: "When Full",
                        description: L("What happens to a new task when the queue is full."),
                        anchorId: "tasks.queue.overflow",
                        style: .menu,
                        selection: $overflow,
                        options: TaskOverflowPolicy.allCases.map { .init($0, $0.displayName, verbatim: true) })
                }
                SettingsPickerRow(
                    title: "Start Order",
                    description: L("Which waiting task starts when a slot frees up."),
                    anchorId: "tasks.queue.ordering",
                    style: .menu,
                    selection: $ordering,
                    options: TaskOrderingMode.allCases.map { .init($0, $0.displayName, verbatim: true) })
                SettingsRow(
                    title: "Paused",
                    description: L("Hold new tasks without starting them. Running tasks finish."),
                    anchorId: "tasks.queue.paused",
                    verbatimDescription: true
                ) {
                    Toggle("", isOn: $paused).settingsSwitch()
                }
            }

            if let queue, !queue.isSystem {
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Delete Queue",
                        description: L("Waiting tasks move to Default. Automations on this queue use Default."),
                        actionTitle: "Delete"
                    ) {
                        store.deleteQueue(id: queue.id)
                        onClose()
                    }
                }
            }
        }
    }

    private func save() {
        var policy = queue?.policy ?? TaskQueuePolicy()
        policy.maxConcurrent = maxConcurrent
        policy.maxPending = maxWaiting == 0 ? nil : maxWaiting
        policy.overflow = overflow
        policy.orderingMode = ordering
        policy.paused = paused
        if var existing = queue {
            if !existing.isSystem { existing.name = trimmedName }
            existing.policy = policy
            store.updateQueue(existing)
        } else {
            store.createQueue(name: trimmedName, policy: policy)
        }
        onClose()
    }
}
