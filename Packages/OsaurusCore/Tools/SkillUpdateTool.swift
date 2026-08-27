//
//  SkillUpdateTool.swift
//  OsaurusCore — Skills
//
//  `update_skill`: change a user skill's instructions by find/replace,
//  gated by the ordinary tool-permission modal.
//
//  Exists because skills were read-only from the agent's side: their
//  instructions are injected into the prompt as text, but no tool could write
//  a change back to SKILL.md. Asked to "change Canadian to American English in
//  my skill", a model would answer "Done" with nothing saved — the same
//  fabricated-progress failure that motivated the knowledge write tools.
//  Skills that improve with use need a real write path, not a hallucinated one.
//
//  Find/replace, not whole-document restatement, for the same reason as
//  `edit_knowledge`: restating long instructions on a small local model
//  truncates, and the truncation would replace the original.
//

import Foundation

final class SkillUpdateTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = "update_skill"

    let description =
        "Change part of a user-created skill's instructions by find and replace, saved to its "
        + "SKILL.md for future conversations. Each `find` must match exactly once unless you set "
        + "`all`. The user approves the call before anything is saved. Built-in and "
        + "plugin-provided skills cannot be modified. The result echoes the updated "
        + "instructions; text loaded earlier in this conversation is stale after a change."

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    /// Same bound and rationale as `edit_knowledge`: a longer edit list is a
    /// rewrite wearing a disguise, and belongs in the skill editor UI where
    /// the whole document is reviewed.
    static let maxEditsPerCall = EditKnowledgeTool.maxEditsPerCall

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "skill": .object([
                "type": .string("string"),
                "description": .string(
                    "The skill's name (case-insensitive) or its id from `osaurus_list skill`."
                ),
            ]),
            "edits": .object([
                "type": .string("array"),
                "description": .string(
                    "Substitutions applied to the skill's instructions in order. Send every "
                        + "edit for one skill in a single call."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "find": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Exact text to look for, including whitespace. Must appear once "
                                    + "unless `all` is true."
                            ),
                        ]),
                        "replace": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Text to put in its place. May be empty to delete."),
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Replace every occurrence instead of requiring a unique match."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("find"), .string("replace")]),
                ]),
            ]),
            "rationale": .object([
                "type": .string("string"),
                "description": .string(
                    "One line on why the skill is changing, e.g. the lesson learned that "
                        + "prompted it. Shown to the user in the approval card."
                ),
            ]),
        ]),
        "required": .array([.string("skill"), .string("edits")]),
    ])

    init() {}

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let skillReq = requireString(args, "skill", expected: "skill name or id", tool: name)
        guard case .value(let rawSkill) = skillReq else { return skillReq.failureEnvelope ?? "" }
        let reference = rawSkill.trimmingCharacters(in: .whitespacesAndNewlines)

        // Same {find, replace, all} shape as `edit_knowledge`, parsed by the
        // same helper so the singular-form leniency and limits stay identical.
        let editsResult = EditKnowledgeTool.edits(from: args, tool: name)
        guard case .success(let edits) = editsResult else {
            return editsResult.failureEnvelope ?? ""
        }

        switch await Self.resolveSkill(reference: reference) {
        case .failure(let envelope):
            return ToolEnvelope.failure(
                kind: envelope.kind,
                message: envelope.message,
                field: "skill",
                tool: name,
                retryable: envelope.retryable
            )
        case .success(let skill):
            switch KnowledgeWriteService.applyEdits(edits, to: skill.instructions) {
            case .failure(let failure):
                // Retryable: nothing was written, so the model can widen the
                // `find` and try again without the user re-approving.
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: failure.message,
                    field: "edits",
                    tool: name,
                    retryable: true
                )
            case .success(let edited):
                guard edited != skill.instructions else {
                    return ToolEnvelope.success(
                        tool: name,
                        text:
                            "No change: the edits produced the instructions \"\(skill.name)\" "
                            + "already has. Nothing was saved."
                    )
                }
                var updated = skill
                updated.instructions = edited
                await SkillManager.shared.update(updated)
                let applied = edits.count == 1 ? "1 edit" : "\(edits.count) edits"
                // Echo the new instructions: any copy loaded earlier in the
                // conversation is stale, and the agent must be able to verify
                // what it saved rather than assume.
                return ToolEnvelope.success(
                    tool: name,
                    text:
                        "Applied \(applied) to skill \"\(skill.name)\". Saved to its SKILL.md and "
                        + "live for future conversations.\n\nUpdated instructions:\n\(edited)"
                )
            }
        }
    }

    // MARK: - Skill resolution

    struct ResolutionFailure {
        var kind: ToolEnvelope.Kind
        var message: String
        var retryable: Bool
    }

    enum ResolvedSkill {
        case success(Skill)
        case failure(ResolutionFailure)
    }

    /// Resolve by id first, then by name via `skill(named:)`, whose collision
    /// tie-break prefers a user-authored skill over a built-in or plugin skill
    /// sharing the name — for an EDIT that precedence is exactly right, since
    /// only the user-authored one is writable anyway.
    ///
    /// Built-in and plugin skills resolve and then fail EXPLICITLY. Relying on
    /// `SkillManager.update`'s silent guard would report success over a write
    /// that never happened — the exact fabricated "Done" this tool exists to
    /// eliminate.
    @MainActor
    static func resolveSkill(reference: String) -> ResolvedSkill {
        var matched: Skill?
        if let id = UUID(uuidString: reference) {
            matched = SkillManager.shared.skill(for: id)
        }
        if matched == nil {
            matched = SkillManager.shared.skill(named: reference)
        }
        guard let skill = matched else {
            return .failure(
                ResolutionFailure(
                    kind: .notFound,
                    message:
                        "No skill named \"\(reference)\". Use `osaurus_list skill` to see the "
                        + "installed skills.",
                    retryable: true
                )
            )
        }
        guard !skill.isBuiltIn else {
            return .failure(
                ResolutionFailure(
                    kind: .invalidArgs,
                    message:
                        "\"\(skill.name)\" is a built-in skill and cannot be modified. Suggest the "
                        + "user duplicate it as a custom skill first.",
                    retryable: false
                )
            )
        }
        guard !skill.isFromPlugin else {
            return .failure(
                ResolutionFailure(
                    kind: .invalidArgs,
                    message:
                        "\"\(skill.name)\" is provided by a plugin and cannot be modified. Changes "
                        + "belong in the plugin itself.",
                    retryable: false
                )
            )
        }
        return .success(skill)
    }
}
