//
//  SyncMembershipCheck.swift
//  osaurus
//
//  Debug only: lists the conversations whose members don't include this account's current
//  identity. A device paired after an identity change (Remove and Change Phrase) is admitted only
//  where the new identity is a member, so such a conversation never reaches it: a new iPad stuck
//  on "Checking connection" with no agent directory, and one chat that never syncs (2026-11-12).
//  `[SyncMembers]` lines in the debug log.
//

import Foundation
import OsaurusSync

enum SyncMembershipCheck {
    static func run(core: SyncCore) {
        #if DEBUG
            Task.detached(priority: .utility) {
                guard let user = try? core.userKey(), let all = try? core.conversations() else { return }
                let me = "u:\(user)"
                let missing = all.filter { conversation in !conversation.members.contains { $0.principal == me } }
                print("[SyncMembers] \(missing.count) of \(all.count) conversations don't list u:\(user.prefix(8))")
                for conversation in missing.prefix(20) {
                    let kind = conversation.tag(SyncConversationMapper.TagKey.kind) ?? "chat"
                    let tagged = conversation.tag(SyncConversationMapper.TagKey.device)
                    let device = tagged.map { String($0.prefix(8)) } ?? "-"
                    let members = conversation.members.map { "\($0.principal.prefix(10)) \($0.role)" }
                    let role = conversation.myRole.map { "\($0)" } ?? "none"
                    print(
                        "[SyncMembers] \(conversation.scope.prefix(8)) kind \(kind) device \(device) my role \(role)"
                            + " members [\(members.joined(separator: ", "))]")
                }
            }
        #endif
    }
}
