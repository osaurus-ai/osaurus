//
//  RedactionTools.swift
//  osaurus
//
//  `detect_pii` and `redact_file`: first-class agent access to the
//  PrivacyFilter engine (Rampart BERT NER + regex detectors) so
//  redaction-style tasks run as one deterministic pass instead of a
//  decode-bound agent loop re-emitting file content. Both tools register
//  unconditionally (stable tool list -> stable KV prefix hash); model
//  availability degrades in the RESULT via `RedactionToolSupport`.
//

import Foundation

// MARK: - detect_pii

struct DetectPIITool: OsaurusTool {
    let name = "detect_pii"
    let description =
        "Find names, emails, phone numbers, addresses, URLs, account numbers, and secrets in a "
        + "file or in inline text using the on-device PII model plus deterministic regex detectors. "
        + "Use this to preview what a replace/mask/anonymize/redact request would match before "
        + "calling `redact_file`. "
        + "Pass `path` (relative file path) OR `text`. Optionally pass `custom_rules`: an array of "
        + "{name, pattern, placeholder} regex rules for domain-specific patterns the built-in "
        + "categories miss (e.g. revenue figures) — rules apply to this call only. Returns detected "
        + "spans grouped by category with line numbers and counts. Read-only; use `redact_file` to "
        + "apply replacements."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path of the file to scan (mutually exclusive with `text`)"),
            ]),
            "text": .object([
                "type": .string("string"),
                "description": .string("Inline text to scan (mutually exclusive with `path`)"),
            ]),
            "custom_rules": .object([
                "type": .string("array"),
                "description": .string(
                    "Ephemeral regex rules for this call: [{name, pattern, placeholder?, case_sensitive?}]"
                ),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "pattern": .object(["type": .string("string")]),
                        "placeholder": .object(["type": .string("string")]),
                        "case_sensitive": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("pattern")]),
                ]),
            ]),
        ]),
        "required": .array([]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        guard let parsed = RedactionToolSupport.parseCustomRules(args["custom_rules"]) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`custom_rules` must be an array of {name, pattern, placeholder} objects.",
                field: "custom_rules",
                expected: "array of rule objects",
                tool: name
            )
        }

        let text: String
        var scannedPath: String? = nil
        if let inline = args["text"] as? String, !inline.isEmpty {
            text = inline
        } else {
            let pathReq = requireString(
                args,
                "path",
                expected: "relative file path (or pass `text` for inline content)",
                tool: name
            )
            guard case .value(let relativePath) = pathReq else {
                return pathReq.failureEnvelope ?? ""
            }
            switch await RedactionFileAccess.readText(
                relativePath: relativePath, fixedRoot: fixedRootPath, tool: name)
            {
            case .success(let content):
                text = content
                scannedPath = relativePath
            case .failureEnvelope(let envelope):
                return envelope
            }
        }

        let outcome = await RedactionToolSupport.detect(in: text, customRules: parsed.rules)
        var payload: [String: Any] = [
            "backend": outcome.backend,
            "total_detections": outcome.entities.count,
            "categories": Self.grouped(outcome.entities, in: text),
        ]
        if let scannedPath { payload["path"] = scannedPath }
        if !parsed.rejected.isEmpty {
            payload["rejected_rules"] = parsed.rejected.map {
                ["name": $0.name, "reason": $0.reason]
            }
        }
        var warnings: [String] = []
        if let degradation = outcome.degradation { warnings.append(degradation) }
        return ToolEnvelope.success(tool: name, result: payload, warnings: warnings)
    }

    /// Group entities as `{category: {count, samples: [{text, line, occurrences}]}}`
    /// with per-category sample caps so a dense file can't blow the envelope.
    static func grouped(_ entities: [DetectedEntity], in text: String) -> [String: Any] {
        let lineStarts = RedactionFileAccess.lineStartIndices(of: text)
        var byCategory: [String: [String: (line: Int, occurrences: Int)]] = [:]
        for entity in entities {
            let key = entity.category.rawValue
            let line = RedactionFileAccess.lineNumber(
                of: entity.range.lowerBound, in: text, lineStarts: lineStarts)
            var forCategory = byCategory[key] ?? [:]
            if let existing = forCategory[entity.original] {
                forCategory[entity.original] = (existing.line, existing.occurrences + 1)
            } else {
                forCategory[entity.original] = (line, 1)
            }
            byCategory[key] = forCategory
        }
        var result: [String: Any] = [:]
        let sampleCap = 40
        for (category, originals) in byCategory {
            let sorted = originals.sorted { $0.value.line < $1.value.line }
            var samples: [[String: Any]] = []
            for (original, info) in sorted.prefix(sampleCap) {
                samples.append([
                    "text": original,
                    "line": info.line,
                    "occurrences": info.occurrences,
                ])
            }
            var entry: [String: Any] = [
                "count": originals.values.reduce(0) { $0 + $1.occurrences },
                "samples": samples,
            ]
            if originals.count > sampleCap {
                entry["samples_truncated_at"] = sampleCap
            }
            result[category] = entry
        }
        return result
    }
}

// MARK: - redact_file

struct RedactFileTool: OsaurusTool, PermissionedTool {
    let name = "redact_file"
    let description =
        "Replace names, emails, phone numbers, addresses, account numbers, and other sensitive "
        + "values in a file with placeholder text like `[REDACTED NAME]` in ONE deterministic pass. "
        + "Use this whenever asked to replace, remove, mask, anonymize, or redact such values across "
        + "a file — prefer it over `file_edit` loops or writing a script. Detection uses the "
        + "on-device PII model plus regex detectors; every occurrence of each detected entity is "
        + "replaced. Optionally pass `custom_rules` (ephemeral regex rules "
        + "for domain-specific patterns), `categories` to limit which built-in categories are "
        + "redacted, `placeholders` to override the per-category placeholder text, and "
        + "`dry_run: true` to preview counts without writing. The change is undoable via `file_undo`."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path of the file to redact"),
            ]),
            "categories": .object([
                "type": .string("array"),
                "description": .string(
                    "Built-in categories to redact (default: all). Any of: accountNumber, address, email, person, phone, url, date, secret"
                ),
                "items": .object(["type": .string("string")]),
            ]),
            "placeholders": .object([
                "type": .string("object"),
                "description": .string(
                    "Per-category placeholder overrides, e.g. {\"person\": \"[REDACTED NAME]\"}. Custom-rule matches use the rule's `placeholder`."
                ),
            ]),
            "custom_rules": .object([
                "type": .string("array"),
                "description": .string(
                    "Ephemeral regex rules for this call: [{name, pattern, placeholder?, case_sensitive?}]"
                ),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "pattern": .object(["type": .string("string")]),
                        "placeholder": .object(["type": .string("string")]),
                        "case_sensitive": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("pattern")]),
                ]),
            ]),
            "dry_run": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Preview detection counts and the diff without modifying the file (default: false)"
                ),
            ]),
        ]),
        "required": .array([.string("path")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }
    var mutatesHostFolder: Bool { true }

    /// Default placeholder per category, aligned with the wording users
    /// naturally ask for ("replace names with [REDACTED NAME]").
    static func defaultPlaceholder(for category: EntityCategory) -> String {
        switch category {
        case .person: return "[REDACTED NAME]"
        case .email: return "[REDACTED EMAIL]"
        case .phone: return "[REDACTED PHONE]"
        case .address: return "[REDACTED ADDRESS]"
        case .accountNumber: return "[REDACTED ACCOUNT]"
        case .url: return "[REDACTED URL]"
        case .date: return "[REDACTED DATE]"
        case .secret: return "[REDACTED]"
        }
    }

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path under the working folder",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }
        let dryRun = coerceBool(args["dry_run"]) ?? false

        guard let parsed = RedactionToolSupport.parseCustomRules(args["custom_rules"]) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`custom_rules` must be an array of {name, pattern, placeholder} objects.",
                field: "custom_rules",
                expected: "array of rule objects",
                tool: name
            )
        }

        var allowedCategories: Set<EntityCategory>? = nil
        if let rawCategories = args["categories"] as? [String] {
            var resolved: Set<EntityCategory> = []
            for raw in rawCategories {
                guard let category = EntityCategory(rawValue: raw) else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "Unknown category `\(raw)`. Valid: \(EntityCategory.allCases.map(\.rawValue).joined(separator: ", ")).",
                        field: "categories",
                        expected: "array of valid category names",
                        tool: name
                    )
                }
                resolved.insert(category)
            }
            allowedCategories = resolved
        }

        var placeholderOverrides: [EntityCategory: String] = [:]
        if let rawPlaceholders = args["placeholders"] as? [String: Any] {
            for (key, value) in rawPlaceholders {
                guard let category = EntityCategory(rawValue: key), let label = value as? String,
                    !label.isEmpty
                else { continue }
                placeholderOverrides[category] = label
            }
        }

        let resolution = await RedactionFileAccess.resolveWritable(
            relativePath: relativePath, fixedRoot: fixedRootPath, tool: name)
        let fileURL: URL
        let rootPath: URL
        switch resolution {
        case .success(let resolved):
            (fileURL, rootPath) = resolved
        case .failureEnvelope(let envelope):
            return envelope
        }

        let originalContent: String
        switch WorkspaceWriteSafety.existingText(
            at: fileURL, relativePath: relativePath, toolName: name)
        {
        case .success(let content):
            guard let content else {
                throw FolderToolError.fileNotFound(relativePath)
            }
            originalContent = content
        case .failureEnvelope(let envelope):
            return envelope
        }

        let outcome = await RedactionToolSupport.detect(
            in: originalContent, customRules: parsed.rules)

        // Deduplicate overlapping spans (defensive: the engine merges,
        // but replacement must never double-apply), filter to allowed
        // categories, and replace back-to-front so earlier ranges stay
        // valid as the string mutates.
        var selected = outcome.entities
        if let allowedCategories {
            // Custom-rule matches carry a custom placeholder label; they
            // are always applied (the agent asked for them explicitly).
            selected = selected.filter {
                allowedCategories.contains($0.category)
                    || $0.placeholder.prefixOverride != nil
            }
        }
        selected.sort { $0.range.lowerBound < $1.range.lowerBound }
        var deduped: [DetectedEntity] = []
        var lastUpper: String.Index? = nil
        for entity in selected {
            if let lastUpper, entity.range.lowerBound < lastUpper { continue }
            deduped.append(entity)
            lastUpper = entity.range.upperBound
        }

        var content = originalContent
        var countsByCategory: [String: Int] = [:]
        for entity in deduped.reversed() {
            let replacement: String
            if let custom = entity.placeholder.prefixOverride {
                replacement = "[REDACTED \(custom)]"
            } else {
                replacement =
                    placeholderOverrides[entity.category]
                    ?? Self.defaultPlaceholder(for: entity.category)
            }
            content.replaceSubrange(entity.range, with: replacement)
            let key = entity.placeholder.prefixOverride.map { "custom:\($0)" }
                ?? entity.category.rawValue
            countsByCategory[key, default: 0] += 1
        }

        var preview = WorkspaceWriteSafety.preview(
            path: relativePath,
            previousContent: originalContent,
            proposedContent: content,
            operation: name,
            dryRun: dryRun,
            overwritesExistingFile: false,
            createsParentDirectories: false,
            fileURL: fileURL
        )
        preview.payload["backend"] = outcome.backend
        preview.payload["replacements"] = deduped.count
        preview.payload["replacements_by_category"] = countsByCategory
        if !parsed.rejected.isEmpty {
            preview.payload["rejected_rules"] = parsed.rejected.map {
                ["name": $0.name, "reason": $0.reason]
            }
        }
        var warnings = preview.warnings
        if let degradation = outcome.degradation { warnings.append(degradation) }

        if dryRun || deduped.isEmpty {
            preview.payload["written"] = false
            return ToolEnvelope.success(tool: name, result: preview.payload, warnings: warnings)
        }

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        if let sid = ChatExecutionContext.currentSessionId {
            let operation = FileOperation(
                type: .fileEdit,
                path: relativePath,
                previousContent: originalContent,
                sessionId: sid,
                batchId: ChatExecutionContext.currentBatchId,
                rootPath: rootPath.standardizedFileURL.path
            )
            await FileOperationLog.shared.log(operation)
            preview.payload["operation_id"] = operation.id.uuidString
        }
        preview.payload["written"] = true
        return ToolEnvelope.success(tool: name, result: preview.payload, warnings: warnings)
    }
}

// MARK: - Shared file access

/// File plumbing shared by the redaction tools: root resolution, the
/// same secret/structured-text gates as `file_edit`, and line-number
/// math for span reporting.
enum RedactionFileAccess {

    enum TextResult {
        case success(String)
        case failureEnvelope(String)
    }

    enum WritableResult {
        case success((URL, URL))
        case failureEnvelope(String)
    }

    /// Read-only resolution + content load (for `detect_pii`).
    static func readText(relativePath: String, fixedRoot: URL?, tool: String) async -> TextResult {
        guard let rootPath = FolderToolHelpers.resolveRoot(fixed: fixedRoot) else {
            return .failureEnvelope(FolderToolHelpers.noActiveFolderEnvelope(tool: tool))
        }
        guard let fileURL = try? FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        else {
            return .failureEnvelope(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Path `\(relativePath)` escapes the working folder.",
                    field: "path",
                    expected: "relative path under the working folder",
                    tool: tool
                ))
        }
        if FolderToolHelpers.shouldRefuseSecret(fileURL: fileURL) {
            return .failureEnvelope(
                FolderToolHelpers.secretRefusalEnvelope(relativePath: relativePath, tool: tool))
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failureEnvelope(
                ToolEnvelope.failure(
                    kind: .notFound,
                    message: "File not found: \(relativePath)",
                    field: "path",
                    expected: "existing file under the working folder",
                    tool: tool
                ))
        }
        switch WorkspaceWriteSafety.existingText(
            at: fileURL, relativePath: relativePath, toolName: tool)
        {
        case .success(let content):
            return .success(content ?? "")
        case .failureEnvelope(let envelope):
            return .failureEnvelope(envelope)
        }
    }

    /// Writable resolution with the same gates as `file_edit`.
    static func resolveWritable(relativePath: String, fixedRoot: URL?, tool: String) async
        -> WritableResult
    {
        guard let rootPath = FolderToolHelpers.resolveRoot(fixed: fixedRoot) else {
            return .failureEnvelope(FolderToolHelpers.noActiveFolderEnvelope(tool: tool))
        }
        guard let fileURL = try? FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        else {
            return .failureEnvelope(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Path `\(relativePath)` escapes the working folder.",
                    field: "path",
                    expected: "relative path under the working folder",
                    tool: tool
                ))
        }
        if FolderToolHelpers.shouldRefuseSecret(fileURL: fileURL) {
            return .failureEnvelope(
                FolderToolHelpers.secretWriteRefusalEnvelope(relativePath: relativePath, tool: tool))
        }
        if let rejected = WorkspaceWriteSafety.structuredTextWriteRejection(
            path: relativePath,
            fileExtension: fileURL.pathExtension.lowercased(),
            toolName: tool
        ) {
            return .failureEnvelope(rejected)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failureEnvelope(
                ToolEnvelope.failure(
                    kind: .notFound,
                    message: "File not found: \(relativePath)",
                    field: "path",
                    expected: "existing file under the working folder",
                    tool: tool
                ))
        }
        return .success((fileURL, rootPath))
    }

    // MARK: Line math

    static func lineStartIndices(of text: String) -> [String.Index] {
        var starts: [String.Index] = [text.startIndex]
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                starts.append(text.index(after: index))
            }
            index = text.index(after: index)
        }
        return starts
    }

    /// 1-based line number of `position` given precomputed line starts.
    static func lineNumber(of position: String.Index, in text: String, lineStarts: [String.Index])
        -> Int
    {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= position { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}
