//
//  WorkflowDialogAttention.swift
//  osaurus
//
//  A workflow form as the iPhone reads it from the attention feed
//  (`workflow_dialog`, SYNC_MOBILE_CONTRACT §4): the form's fields and the
//  answers it starts with, so the phone can show the form itself instead
//  of only "Open on your Mac". The phone answers with `submit` and the
//  values, which go through `DialogCoordinator.answer` exactly as the
//  Mac's own form does.
//

import Foundation

enum WorkflowDialogAttention {
    /// The longest message carried; the form on the Mac has the rest.
    static let messageCharacters = 2_000

    /// Field types the iPhone fills in. A file or folder is a path on this
    /// Mac, and a secret isn't written into synced data: forms that require
    /// one are answered on the Mac.
    static let phoneTypes: Set<DialogFieldType> = [.text, .longText, .number, .bool, .choice, .date]

    /// The `detail` for `dialog`'s attention item.
    static func detail(for dialog: PendingDialog) -> Data? {
        let message = AttentionDetail.clip(dialog.message, messageCharacters)
        var object: [String: Any] = [
            "workflow": dialog.workflowName,
            "run_id": dialog.runID.uuidString.lowercased(),
            "node_id": dialog.nodeID,
            "title": dialog.title,
            "message": message.text,
            "fields": dialog.fields.map(field),
            "phone_answerable": phoneAnswerable(dialog),
        ]
        if message.cut { object["message_truncated"] = true }
        let prefill = dialog.prefill.filter { key, _ in
            // Never a secret's value, even a remembered one.
            dialog.fields.first { $0.key == key }.map { $0.type != .secret } ?? false
        }
        if !prefill.isEmpty { object["prefill"] = prefill.mapValues(\.sendableValue) }
        return AttentionDetail.encode(object, listKey: "fields")
    }

    /// Whether every required field is one the iPhone fills in.
    static func phoneAnswerable(_ dialog: PendingDialog) -> Bool {
        dialog.fields.allSatisfy { !$0.required || phoneTypes.contains($0.type) }
    }

    private static func field(_ field: DialogField) -> [String: Any] {
        var out: [String: Any] = [
            "key": field.key,
            "label": field.label,
            "type": field.type.rawValue,
            "required": field.required,
        ]
        if let options = field.options, !options.isEmpty { out["options"] = options }
        if let help = field.help, !help.isEmpty { out["help"] = help }
        if field.type != .secret, let value = field.defaultValue { out["default"] = value.sendableValue }
        return out
    }
}
