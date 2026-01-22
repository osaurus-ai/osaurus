//
//  Skill.swift
//  osaurus
//
//  Defines a Skill - markdown instructions that guide AI behavior.
//  Skills are stored as directories with SKILL.md files following the Agent Skills spec.
//  See: https://agentskills.io/specification
//

import Foundation

/// Represents a file within a skill's references or assets directory
public struct SkillFile: Codable, Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let relativePath: String
    public let size: Int64

    public init(name: String, relativePath: String, size: Int64 = 0) {
        self.name = name
        self.relativePath = relativePath
        self.size = size
    }
}

/// A skill containing instructions/guidance for the AI
/// Follows the Agent Skills specification: https://agentskills.io/specification
public struct Skill: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var description: String
    public var version: String
    public var author: String?
    public var category: String?
    public var icon: String?
    public var enabled: Bool
    public var instructions: String
    public let isBuiltIn: Bool
    public let createdAt: Date
    public var updatedAt: Date

    // MARK: - Directory Structure

    /// Files in the references/ directory (loaded into context)
    public var references: [SkillFile]
    /// Files in the assets/ directory (supporting files)
    public var assets: [SkillFile]
    /// The directory name (Agent Skills format: lowercase-with-hyphens)
    public var directoryName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        version: String = "1.0.0",
        author: String? = nil,
        category: String? = nil,
        icon: String? = nil,
        enabled: Bool = true,
        instructions: String = "",
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        references: [SkillFile] = [],
        assets: [SkillFile] = [],
        directoryName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.category = category
        self.icon = icon
        self.enabled = enabled
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.references = references
        self.assets = assets
        self.directoryName = directoryName
    }

    /// Total count of associated files
    public var totalFileCount: Int {
        references.count + assets.count
    }

    /// Whether this skill has any associated files
    public var hasAssociatedFiles: Bool {
        totalFileCount > 0
    }

    // MARK: - Built-in Skills

    /// All built-in skills
    public static var builtInSkills: [Skill] {
        [
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000001")!,
                name: "Code Review Expert",
                description: "Thorough code review with security and performance focus",
                version: "1.0.0",
                author: "Osaurus",
                category: "development",
                icon: "checkmark.shield",
                enabled: false,
                instructions: """
                    When reviewing code, follow these guidelines:

                    ## Security Review
                    - Check for SQL injection vulnerabilities
                    - Validate all user inputs
                    - Look for hardcoded credentials or secrets
                    - Review authentication and authorization logic
                    - Check for XSS vulnerabilities in web code

                    ## Performance Review
                    - Identify N+1 query patterns
                    - Check for unnecessary computations in loops
                    - Review memory allocation patterns
                    - Look for potential memory leaks
                    - Check for inefficient algorithms

                    ## Code Quality
                    - Verify error handling is comprehensive
                    - Check for proper logging
                    - Ensure code follows project conventions
                    - Look for code duplication
                    - Verify tests cover edge cases
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000002")!,
                name: "Technical Writer",
                description: "Documentation and README best practices",
                version: "1.0.0",
                author: "Osaurus",
                category: "writing",
                icon: "doc.text",
                enabled: false,
                instructions: """
                    When writing technical documentation:

                    ## Structure
                    - Start with a clear, concise overview
                    - Use hierarchical headings (H1 > H2 > H3)
                    - Include a table of contents for long documents
                    - End with next steps or related resources

                    ## Content Guidelines
                    - Write for your target audience's skill level
                    - Define acronyms and technical terms on first use
                    - Use active voice and present tense
                    - Keep sentences short and scannable
                    - Include practical examples for complex concepts

                    ## Code Examples
                    - Provide complete, runnable examples
                    - Include expected output where helpful
                    - Comment non-obvious parts of the code
                    - Use consistent formatting and style

                    ## README Best Practices
                    - Lead with what the project does
                    - Include installation instructions
                    - Show basic usage examples
                    - List prerequisites and dependencies
                    - Add badges for build status, version, etc.
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000003")!,
                name: "API Designer",
                description: "RESTful API design guidelines",
                version: "1.0.0",
                author: "Osaurus",
                category: "development",
                icon: "network",
                enabled: false,
                instructions: """
                    When designing APIs, follow these guidelines:

                    ## URL Structure
                    - Use nouns for resources, not verbs
                    - Use plural nouns (e.g., /users, /posts)
                    - Use hyphens for multi-word resources
                    - Keep URLs lowercase
                    - Nest resources logically (e.g., /users/{id}/posts)

                    ## HTTP Methods
                    - GET: Retrieve resources (idempotent)
                    - POST: Create new resources
                    - PUT: Replace entire resource
                    - PATCH: Partial update
                    - DELETE: Remove resource

                    ## Response Design
                    - Use appropriate HTTP status codes
                    - Return consistent response structure
                    - Include pagination for list endpoints
                    - Provide meaningful error messages
                    - Use ISO 8601 for dates

                    ## Best Practices
                    - Version your API (e.g., /v1/users)
                    - Support filtering, sorting, and field selection
                    - Implement rate limiting
                    - Use HTTPS everywhere
                    - Document with OpenAPI/Swagger
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000004")!,
                name: "Debug Assistant",
                description: "Systematic debugging approach",
                version: "1.0.0",
                author: "Osaurus",
                category: "development",
                icon: "ant",
                enabled: false,
                instructions: """
                    When helping debug issues:

                    ## Initial Assessment
                    - What is the expected behavior?
                    - What is the actual behavior?
                    - When did it start happening?
                    - What changed recently?
                    - Is it reproducible?

                    ## Systematic Approach
                    1. Reproduce the issue consistently
                    2. Isolate the problem area
                    3. Form hypotheses about the cause
                    4. Test each hypothesis methodically
                    5. Document findings as you go

                    ## Common Debugging Techniques
                    - Add logging at key points
                    - Use debugger breakpoints
                    - Check input/output at boundaries
                    - Compare working vs non-working cases
                    - Binary search through commits

                    ## Questions to Ask
                    - Are all dependencies correct versions?
                    - Is the environment configured properly?
                    - Are there any error messages in logs?
                    - Does it work in a different environment?
                    - Have you tried clearing caches?

                    ## Resolution
                    - Fix the root cause, not just symptoms
                    - Add tests to prevent regression
                    - Document the fix for future reference
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),
        ]
    }
}

// MARK: - YAML Frontmatter Parsing

extension Skill {
    /// Parse a skill from markdown content with YAML frontmatter
    public static func parse(from markdown: String) throws -> Skill {
        let (frontmatter, body) = try extractFrontmatter(from: markdown)

        guard let name = frontmatter["name"] as? String, !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }

        let id: UUID
        if let idString = frontmatter["id"] as? String, let parsedId = UUID(uuidString: idString) {
            id = parsedId
        } else {
            id = UUID()
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let createdAt: Date
        if let dateString = frontmatter["createdAt"] as? String,
            let parsed = dateFormatter.date(from: dateString)
        {
            createdAt = parsed
        } else {
            createdAt = Date()
        }

        let updatedAt: Date
        if let dateString = frontmatter["updatedAt"] as? String,
            let parsed = dateFormatter.date(from: dateString)
        {
            updatedAt = parsed
        } else {
            updatedAt = Date()
        }

        return Skill(
            id: id,
            name: name,
            description: frontmatter["description"] as? String ?? "",
            version: frontmatter["version"] as? String ?? "1.0.0",
            author: frontmatter["author"] as? String,
            category: frontmatter["category"] as? String,
            icon: frontmatter["icon"] as? String,
            enabled: frontmatter["enabled"] as? Bool ?? true,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Convert skill to markdown with YAML frontmatter
    public func toMarkdown() -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var yaml = "---\n"
        yaml += "id: \"\(id.uuidString)\"\n"
        yaml += "name: \"\(escapeYamlString(name))\"\n"
        yaml += "description: \"\(escapeYamlString(description))\"\n"
        yaml += "version: \"\(version)\"\n"
        if let author = author {
            yaml += "author: \"\(escapeYamlString(author))\"\n"
        }
        if let category = category {
            yaml += "category: \"\(escapeYamlString(category))\"\n"
        }
        if let icon = icon {
            yaml += "icon: \"\(icon)\"\n"
        }
        yaml += "enabled: \(enabled)\n"
        yaml += "createdAt: \"\(dateFormatter.string(from: createdAt))\"\n"
        yaml += "updatedAt: \"\(dateFormatter.string(from: updatedAt))\"\n"
        yaml += "---\n\n"
        yaml += instructions

        return yaml
    }

    /// Extract YAML frontmatter and body from markdown
    private static func extractFrontmatter(from markdown: String) throws -> ([String: Any], String) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("---") else {
            throw SkillParseError.noFrontmatter
        }

        // Find the closing ---
        let lines = trimmed.components(separatedBy: .newlines)
        var frontmatterEndIndex: Int?

        for (index, line) in lines.enumerated() {
            if index > 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
                frontmatterEndIndex = index
                break
            }
        }

        guard let endIndex = frontmatterEndIndex else {
            throw SkillParseError.malformedFrontmatter
        }

        let frontmatterLines = lines[1 ..< endIndex]
        let bodyLines = lines[(endIndex + 1)...]

        let frontmatter = parseYaml(Array(frontmatterLines))
        let body = bodyLines.joined(separator: "\n")

        return (frontmatter, body)
    }

    /// Simple YAML parser for frontmatter (handles basic key: value pairs and nested objects)
    private static func parseYaml(_ lines: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var currentNestedKey: String?
        var nestedObject: [String: Any] = [:]

        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            else { continue }

            // Check indentation level
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            // Check if this is a nested key (indented)
            if leadingSpaces >= 2 && currentNestedKey != nil {
                // This is a nested value
                let parsedValue = parseYamlValue(value)
                nestedObject[key] = parsedValue
            } else {
                // Save previous nested object if exists
                if let nestedKey = currentNestedKey, !nestedObject.isEmpty {
                    result[nestedKey] = nestedObject
                    nestedObject = [:]
                }

                if value.isEmpty {
                    // This is a parent key for nested object
                    currentNestedKey = key
                } else {
                    // Regular key-value pair
                    currentNestedKey = nil
                    result[key] = parseYamlValue(value)
                }
            }
        }

        // Save final nested object if exists
        if let nestedKey = currentNestedKey, !nestedObject.isEmpty {
            result[nestedKey] = nestedObject
        }

        return result
    }

    /// Parse a single YAML value
    private static func parseYamlValue(_ value: String) -> Any {
        var v = value

        // Remove quotes if present
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
            // Unescape quotes
            v = v.replacingOccurrences(of: "\\\"", with: "\"")
            v = v.replacingOccurrences(of: "\\'", with: "'")
        }

        // Parse booleans
        if v.lowercased() == "true" {
            return true
        } else if v.lowercased() == "false" {
            return false
        }

        return v
    }

    /// Escape special characters for YAML string
    private func escapeYamlString(_ string: String) -> String {
        return
            string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Errors

public enum SkillParseError: Error, LocalizedError {
    case noFrontmatter
    case malformedFrontmatter
    case missingRequiredField(String)

    public var errorDescription: String? {
        switch self {
        case .noFrontmatter:
            return "Skill file must start with YAML frontmatter (---)"
        case .malformedFrontmatter:
            return "Could not parse YAML frontmatter"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        }
    }
}

// MARK: - Export/Import Support

extension Skill {
    /// Export format for sharing skills
    public struct ExportData: Codable {
        public let version: Int
        public let skill: Skill

        public init(skill: Skill) {
            self.version = 1
            // Create a copy without built-in flag for export
            self.skill = Skill(
                id: UUID(),  // Generate new ID on export
                name: skill.name,
                description: skill.description,
                version: skill.version,
                author: skill.author,
                category: skill.category,
                icon: skill.icon,
                enabled: skill.enabled,
                instructions: skill.instructions,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        }
    }

    /// Export this skill to JSON data
    public func exportToJSON() throws -> Data {
        let exportData = ExportData(skill: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exportData)
    }

    /// Import a skill from JSON data
    public static func importFromJSON(_ data: Data) throws -> Skill {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportData = try decoder.decode(ExportData.self, from: data)
        return exportData.skill
    }
}

// MARK: - Agent Skills Format Compatibility
// Compatible with https://agentskills.io/specification

extension Skill {
    /// Convert name to Agent Skills format (lowercase, hyphens)
    public var agentSkillsName: String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Export to Agent Skills SKILL.md format
    /// Compatible with: https://agentskills.io/specification
    public func toAgentSkillsFormat() -> String {
        toAgentSkillsFormatInternal(includeId: false)
    }

    /// Export to Agent Skills format with internal ID for local storage
    public func toAgentSkillsFormatWithId() -> String {
        toAgentSkillsFormatInternal(includeId: true)
    }

    private func toAgentSkillsFormatInternal(includeId: Bool) -> String {
        var yaml = "---\n"
        yaml += "name: \(agentSkillsName)\n"

        // Description is required, truncate to 1024 chars per spec
        let truncatedDesc = String(description.prefix(1024))
        yaml += "description: \(escapeAgentSkillsYaml(truncatedDesc))\n"

        // Metadata section
        yaml += "metadata:\n"
        if includeId {
            yaml += "  osaurus-id: \"\(id.uuidString)\"\n"
            yaml += "  osaurus-enabled: \(enabled)\n"
        }
        if let author = author {
            yaml += "  author: \(escapeAgentSkillsYaml(author))\n"
        }
        yaml += "  version: \"\(version)\"\n"
        if let category = category {
            yaml += "  category: \(escapeAgentSkillsYaml(category))\n"
        }
        if let icon = icon {
            yaml += "  icon: \(icon)\n"
        }

        yaml += "---\n\n"
        yaml += instructions

        return yaml
    }

    /// Parse from Agent Skills SKILL.md format
    /// Compatible with: https://agentskills.io/specification
    public static func parseAgentSkillsFormat(from markdown: String) throws -> Skill {
        let (frontmatter, body) = try extractFrontmatter(from: markdown)

        // Agent Skills format requires 'name' field
        guard let name = frontmatter["name"] as? String, !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }

        // Description is required in Agent Skills format
        let description = frontmatter["description"] as? String ?? ""

        // Extract metadata if present
        var author: String?
        var version = "1.0.0"
        var category: String?
        var icon: String?
        var osaurusId: UUID?
        var enabled = true

        if let metadata = frontmatter["metadata"] as? [String: Any] {
            author = metadata["author"] as? String
            version = metadata["version"] as? String ?? "1.0.0"
            category = metadata["category"] as? String
            icon = metadata["icon"] as? String

            // Osaurus-specific metadata
            if let idString = metadata["osaurus-id"] as? String {
                osaurusId = UUID(uuidString: idString)
            }
            if let enabledValue = metadata["osaurus-enabled"] as? Bool {
                enabled = enabledValue
            }
        }

        // Convert Agent Skills name (lowercase-hyphen) to display name (Title Case)
        let displayName =
            name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        return Skill(
            id: osaurusId ?? UUID(),
            name: displayName,
            description: description,
            version: version,
            author: author,
            category: category,
            icon: icon,
            enabled: enabled,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Check if markdown content is in Agent Skills format
    public static func isAgentSkillsFormat(_ markdown: String) -> Bool {
        guard let (frontmatter, _) = try? extractFrontmatter(from: markdown) else {
            return false
        }
        // Agent Skills format has 'name' but no 'id' field
        let hasName = frontmatter["name"] != nil
        let hasId = frontmatter["id"] != nil
        return hasName && !hasId
    }

    /// Parse from either Osaurus or Agent Skills format (auto-detect)
    public static func parseAnyFormat(from markdown: String) throws -> Skill {
        if isAgentSkillsFormat(markdown) {
            return try parseAgentSkillsFormat(from: markdown)
        } else {
            return try parse(from: markdown)
        }
    }

    /// Escape string for Agent Skills YAML format
    private func escapeAgentSkillsYaml(_ string: String) -> String {
        // If string contains special chars, wrap in quotes
        let needsQuotes =
            string.contains(":") || string.contains("#") || string.contains("\"") || string.contains("'")
            || string.contains("\n") || string.hasPrefix(" ") || string.hasSuffix(" ")

        if needsQuotes {
            let escaped =
                string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return string
    }
}
