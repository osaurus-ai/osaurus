//
//  ToolPromptSupport.swift
//  osaurus
//
//  Internal metadata and rendering helpers for concise tool guidance inside
//  work-mode system prompts.
//

import Foundation

struct ToolMetadata: Sendable, Equatable {
    enum ConcurrencyClass: String, Sendable {
        case readOnly
        case workspaceWrite
        case shell
        case coordination
        case completion
        case externalSideEffect
        case unknown
    }

    let purpose: String
    let whenToUse: String?
    let avoidWhen: String?
    let preconditions: [String]
    let sideEffects: [String]
    let refusalGuidance: String?
    let example: String?
    let concurrencyClass: ConcurrencyClass
    let promptPriority: Int

    init(
        purpose: String,
        whenToUse: String? = nil,
        avoidWhen: String? = nil,
        preconditions: [String] = [],
        sideEffects: [String] = [],
        refusalGuidance: String? = nil,
        example: String? = nil,
        concurrencyClass: ConcurrencyClass = .unknown,
        promptPriority: Int
    ) {
        self.purpose = purpose
        self.whenToUse = whenToUse
        self.avoidWhen = avoidWhen
        self.preconditions = preconditions
        self.sideEffects = sideEffects
        self.refusalGuidance = refusalGuidance
        self.example = example
        self.concurrencyClass = concurrencyClass
        self.promptPriority = promptPriority
    }
}

struct ToolPromptCard: Sendable, Equatable {
    private static let summaryMaxLength = 160
    private static let detailMaxLength = 160
    private static let nonCompactExampleMaxLength = 320

    let name: String
    let summary: String
    let whenToUse: String?
    let avoidWhen: String?
    let example: String?
    let promptPriority: Int

    init(name: String, description: String, metadata: ToolMetadata) {
        self.name = Self.sanitize(name, maxLength: 80)
        let fallbackSummary = description.isEmpty ? metadata.purpose : description
        self.summary = Self.sanitize(
            metadata.purpose.isEmpty ? fallbackSummary : metadata.purpose,
            maxLength: Self.summaryMaxLength
        )
        self.whenToUse = Self.optionalSanitize(metadata.whenToUse, maxLength: Self.detailMaxLength)
        self.avoidWhen = Self.optionalSanitize(metadata.avoidWhen, maxLength: Self.detailMaxLength)
        self.example = Self.optionalSanitize(metadata.example, maxLength: Self.nonCompactExampleMaxLength)
        self.promptPriority = metadata.promptPriority
    }

    func render(compact: Bool) -> String {
        var parts = ["- `\(name)`: \(summary)."]
        if let whenToUse, !whenToUse.isEmpty {
            parts.append("Use when \(whenToUse).")
        }
        if let avoidWhen, !avoidWhen.isEmpty {
            parts.append("Avoid \(avoidWhen).")
        }
        if !compact, let example, !example.isEmpty {
            parts.append("Example: \(example)")
        }
        return parts.joined(separator: " ")
    }

    static func sanitize(_ text: String, maxLength: Int) -> String {
        let collapsed =
            text
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxLength else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func optionalSanitize(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let sanitized = sanitize(text, maxLength: maxLength)
        return sanitized.isEmpty ? nil : sanitized
    }
}

enum ToolMetadataCatalog {
    static func metadata(for name: String) -> ToolMetadata? {
        switch name {
        case "complete_task":
            return ToolMetadata(
                purpose:
                    "Finish the task with verified, partial, or blocked status plus concrete verification evidence",
                whenToUse: "the requested work is done and you have real evidence",
                avoidWhen: "using it for progress updates or before sharing user-visible outputs",
                preconditions: ["Share every user-visible file first"],
                sideEffects: ["Ends the current task loop"],
                refusalGuidance: "If evidence is weak, keep working and gather proof before completion",
                example:
                    #"{"status":"verified","summary":"Fixed the bug","verification_performed":"Ran unit tests","remaining_risks":"none","remaining_work":"none"}"#,
                concurrencyClass: .completion,
                promptPriority: 100
            )
        case "share_artifact":
            return ToolMetadata(
                purpose: "Expose a file, directory, or inline content to the user",
                whenToUse: "you created output the user needs to see",
                avoidWhen: "assuming written files are automatically visible",
                sideEffects: ["Publishes an artifact to the user-facing thread"],
                example: #"{"path":"reports/final.md","description":"Final report"}"#,
                concurrencyClass: .externalSideEffect,
                promptPriority: 95
            )
        case "save_notes":
            return ToolMetadata(
                purpose: "Persist findings, decisions, and file locations across long tasks and compaction",
                whenToUse: "you discover information that must survive resume or context loss",
                avoidWhen: "using it as a replacement for the final completion summary",
                sideEffects: ["Appends persistent task notes"],
                concurrencyClass: .coordination,
                promptPriority: 82
            )
        case "read_notes":
            return ToolMetadata(
                purpose: "Reload notes saved earlier in the current task",
                whenToUse: "resuming work or recovering after context loss",
                avoidWhen: "calling it repeatedly when no saved notes exist",
                concurrencyClass: .readOnly,
                promptPriority: 78
            )
        case "request_clarification":
            return ToolMetadata(
                purpose:
                    "Ask the user for a missing decision that cannot be derived safely from the repo or current task state",
                whenToUse: "the task is blocked on a high-impact ambiguity",
                avoidWhen: "asking questions you can answer by exploring the codebase",
                concurrencyClass: .coordination,
                promptPriority: 68
            )
        case "create_issue":
            return ToolMetadata(
                purpose: "Record adjacent follow-up work without derailing the current task",
                whenToUse: "you uncover real follow-up work that should be tracked separately",
                avoidWhen: "using it for work you can complete inside the current task",
                sideEffects: ["Creates a tracked follow-up issue"],
                concurrencyClass: .coordination,
                promptPriority: 62
            )
        case "file_tree":
            return ToolMetadata(
                purpose: "Get a quick tree view of the workspace or a subdirectory",
                whenToUse: "starting in an unfamiliar folder",
                avoidWhen: "you already know the exact file to inspect",
                concurrencyClass: .readOnly,
                promptPriority: 48
            )
        case "file_search":
            return ToolMetadata(
                purpose: "Search across the workspace for symbols, strings, or file matches before opening files",
                whenToUse: "locating the right file or code region",
                avoidWhen: "treating matches as enough without reading the file",
                concurrencyClass: .readOnly,
                promptPriority: 96
            )
        case "file_read":
            return ToolMetadata(
                purpose: "Read exact file contents or line ranges before making changes",
                whenToUse: "validating search hits or understanding current implementation",
                avoidWhen: "editing files you have not read first",
                concurrencyClass: .readOnly,
                promptPriority: 98
            )
        case "file_edit":
            return ToolMetadata(
                purpose: "Make targeted edits to an existing file while preserving untouched content",
                whenToUse: "the change is localized and you know the current file contents",
                avoidWhen: "rewriting an entire file for a narrow change",
                sideEffects: ["Mutates an existing file"],
                concurrencyClass: .workspaceWrite,
                promptPriority: 97
            )
        case "file_write":
            return ToolMetadata(
                purpose: "Create a new file or intentionally replace a whole file",
                whenToUse: "adding a new artifact or doing a deliberate full rewrite",
                avoidWhen: "small in-place edits that `file_edit` can handle safely",
                sideEffects: ["Creates or replaces file content"],
                concurrencyClass: .workspaceWrite,
                promptPriority: 84
            )
        case "shell_run":
            return ToolMetadata(
                purpose: "Run build, test, lint, or diagnostic shell commands inside the workspace",
                whenToUse: "verification, debugging, or repo-native workflows",
                avoidWhen: "reading or editing files when dedicated tools exist",
                sideEffects: ["Runs workspace commands and may create build artifacts"],
                concurrencyClass: .shell,
                promptPriority: 88
            )
        case "git_status":
            return ToolMetadata(
                purpose: "Inspect the current branch and working tree state",
                whenToUse: "checking repo state before summarizing or committing",
                avoidWhen: "using it when you need the actual patch details",
                concurrencyClass: .readOnly,
                promptPriority: 42
            )
        case "git_diff":
            return ToolMetadata(
                purpose: "Inspect code changes before verification or summary",
                whenToUse: "reviewing what changed",
                avoidWhen: "calling it before any edits exist",
                concurrencyClass: .readOnly,
                promptPriority: 56
            )
        case "git_commit":
            return ToolMetadata(
                purpose: "Create a commit after changes are verified and the workflow calls for a commit",
                whenToUse: "the user explicitly wants a commit or the task requires one",
                avoidWhen: "committing speculative or unverified work",
                sideEffects: ["Creates a git commit"],
                concurrencyClass: .externalSideEffect,
                promptPriority: 38
            )
        case "sandbox_search_files":
            return ToolMetadata(
                purpose: "Search the sandbox workspace for text matches before opening files",
                whenToUse: "locating files or symbols in the sandbox",
                avoidWhen: "treating a search hit as enough without reading it",
                concurrencyClass: .readOnly,
                promptPriority: 92
            )
        case "sandbox_read_file":
            return ToolMetadata(
                purpose: "Read sandbox files before you edit or execute against them",
                whenToUse: "checking exact file contents or tailing logs",
                avoidWhen: "editing a file you have not inspected",
                concurrencyClass: .readOnly,
                promptPriority: 94
            )
        case "sandbox_edit_file":
            return ToolMetadata(
                purpose: "Apply targeted edits to an existing sandbox file",
                whenToUse: "the change is local and you already read the file",
                avoidWhen: "rewriting large files for a small patch",
                sideEffects: ["Mutates sandbox file content"],
                concurrencyClass: .workspaceWrite,
                promptPriority: 91
            )
        case "sandbox_write_file":
            return ToolMetadata(
                purpose: "Create or replace a sandbox file in one shot",
                whenToUse: "new files or deliberate full rewrites",
                avoidWhen: "small edits better handled by sandbox_edit_file",
                sideEffects: ["Writes sandbox file content"],
                concurrencyClass: .workspaceWrite,
                promptPriority: 70
            )
        case "sandbox_exec":
            return ToolMetadata(
                purpose: "Run a shell command inside the sandbox for build, test, install, or diagnostics",
                whenToUse: "verification or environment-level commands",
                avoidWhen: "using shell commands for file reading or editing when dedicated tools exist",
                sideEffects: ["Runs sandbox commands and may change the environment"],
                concurrencyClass: .shell,
                promptPriority: 86
            )
        case "sandbox_run_script":
            return ToolMetadata(
                purpose: "Run a multi-line script inside the sandbox for batch edits or setup",
                whenToUse: "coordinated multi-step logic is cleaner than many one-line commands",
                avoidWhen: "a single dedicated tool call would do the job",
                sideEffects: ["Runs scripted sandbox operations"],
                concurrencyClass: .shell,
                promptPriority: 74
            )
        case "sandbox_list_directory":
            return ToolMetadata(
                purpose: "List sandbox directories to understand structure",
                whenToUse: "you need a quick directory overview",
                avoidWhen: "you already know the exact file path",
                concurrencyClass: .readOnly,
                promptPriority: 44
            )
        case "sandbox_find_files":
            return ToolMetadata(
                purpose: "Locate sandbox files by name pattern",
                whenToUse: "you know a filename shape but not its location",
                avoidWhen: "full-text search is the real need",
                concurrencyClass: .readOnly,
                promptPriority: 46
            )
        default:
            return nil
        }
    }

    static func workPromptGuide(
        toolDescriptions: [String: String],
        executionMode: WorkExecutionMode,
        compact: Bool
    ) -> String {
        let budget = promptGuideBudget(compact: compact)
        let intro =
            if compact {
                "Choose the narrowest tool for the current step. Read before editing. Share outputs before `complete_task`."
            } else {
                "Choose the narrowest tool for the current step. Prefer search/read/edit tools over shell when possible. Share every user-visible output before `complete_task`."
            }

        var lines = ["## Tool Guide", intro]
        var used = lines.joined(separator: "\n").count

        let cards = promptCards(toolDescriptions: toolDescriptions, executionMode: executionMode)
        var omitted: [String] = []

        for card in cards {
            let rendered = card.render(compact: compact)
            let candidateLength = used + rendered.count + 1
            if !lines.isEmpty && candidateLength > budget {
                omitted.append(card.name)
                continue
            }
            lines.append(rendered)
            used = candidateLength
        }

        if !omitted.isEmpty {
            let maxOmitted = compact ? 4 : 6
            let renderedNames = omitted.prefix(maxOmitted).map { "`\($0)`" }.joined(separator: ", ")
            let overflowLine =
                if compact {
                    "Also available when needed: \(renderedNames)."
                } else {
                    "Other specialized tools remain available when needed: \(renderedNames)."
                }
            if used + overflowLine.count + 1 <= budget {
                lines.append(overflowLine)
            }
        }

        return lines.joined(separator: "\n")
    }

    static func promptGuideBudget(compact: Bool) -> Int {
        compact ? 1100 : 2400
    }

    private static func promptCards(
        toolDescriptions: [String: String],
        executionMode: WorkExecutionMode
    ) -> [ToolPromptCard] {
        let candidateNames = candidatePromptToolNames(for: executionMode)
        var seen = Set<String>()

        return candidateNames.compactMap { name in
            guard seen.insert(name).inserted, let metadata = metadata(for: name) else { return nil }
            let description = toolDescriptions[name] ?? metadata.purpose
            return ToolPromptCard(name: name, description: description, metadata: metadata)
        }
        // Candidate enumeration decides inclusion and de-duplication. Final card order is
        // always driven by prompt priority so the rendered guide stays predictable.
        .sorted {
            if $0.promptPriority != $1.promptPriority {
                return $0.promptPriority > $1.promptPriority
            }
            return $0.name < $1.name
        }
    }

    private static func candidatePromptToolNames(for executionMode: WorkExecutionMode) -> [String] {
        let core = [
            "complete_task",
            "share_artifact",
            "save_notes",
            "read_notes",
            "request_clarification",
            "create_issue",
        ]

        switch executionMode {
        case .none:
            return core
        case .sandbox:
            return core + [
                "sandbox_search_files",
                "sandbox_read_file",
                "sandbox_edit_file",
                "sandbox_write_file",
                "sandbox_exec",
                "sandbox_run_script",
                "sandbox_list_directory",
                "sandbox_find_files",
            ]
        case .hostFolder(let context):
            var names =
                core
                + [
                    "file_search",
                    "file_read",
                    "file_edit",
                    "file_write",
                    "file_tree",
                ]
            if context.projectType != .unknown {
                names.append("shell_run")
            }
            if context.isGitRepo {
                names += ["git_status", "git_diff", "git_commit"]
            }
            return names
        }
    }
}
