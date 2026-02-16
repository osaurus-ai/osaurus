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
    public var enabled: Bool
    public var instructions: String
    public let isBuiltIn: Bool
    public let createdAt: Date
    public var updatedAt: Date

    // MARK: - Plugin Association

    /// The plugin ID if this skill was installed as part of a plugin
    public var pluginId: String?

    /// Whether this skill was installed from a plugin
    public var isFromPlugin: Bool { pluginId != nil }

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
        enabled: Bool = true,
        instructions: String = "",
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        references: [SkillFile] = [],
        assets: [SkillFile] = [],
        directoryName: String? = nil,
        pluginId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.category = category
        self.enabled = enabled
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.references = references
        self.assets = assets
        self.directoryName = directoryName
        self.pluginId = pluginId
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
            // Research & Analysis
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000001")!,
                name: "Research Analyst",
                description: "In-depth research with fact-checking and balanced analysis",
                version: "1.0.0",
                author: "Osaurus",
                category: "research",
                enabled: false,
                instructions: """
                    When conducting research and analysis:

                    ## Information Gathering
                    - Identify multiple reliable sources
                    - Cross-reference facts across sources
                    - Note the date and credibility of sources
                    - Distinguish between facts, opinions, and speculation
                    - Look for primary sources when possible

                    ## Analysis Approach
                    - Present multiple perspectives on controversial topics
                    - Identify potential biases in sources
                    - Use data and evidence to support conclusions
                    - Acknowledge limitations and uncertainties
                    - Separate correlation from causation

                    ## Output Format
                    - Start with a clear executive summary
                    - Use comparison tables for complex data
                    - Include citations and references
                    - Highlight key findings and insights
                    - Provide actionable recommendations

                    ## Quality Checks
                    - Verify statistics and numerical claims
                    - Check for logical fallacies
                    - Ensure balanced coverage of viewpoints
                    - Update outdated information when possible
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Creative
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000002")!,
                name: "Creative Brainstormer",
                description: "Generate ideas, overcome creative blocks, and explore possibilities",
                version: "1.0.0",
                author: "Osaurus",
                category: "creative",
                enabled: false,
                instructions: """
                    When helping with creative thinking and ideation:

                    ## Idea Generation
                    - Start with quantity over quality (divergent thinking)
                    - Build on ideas with "Yes, and..." mentality
                    - Combine unrelated concepts for novel ideas
                    - Challenge assumptions and constraints
                    - Explore opposite or extreme versions

                    ## Brainstorming Techniques
                    - Mind mapping: branch out from central concept
                    - SCAMPER: Substitute, Combine, Adapt, Modify, Put to other uses, Eliminate, Reverse
                    - Random word association
                    - "What if" scenarios
                    - Role-play different perspectives

                    ## Overcoming Creative Blocks
                    - Take a step back and reframe the problem
                    - Look at analogous solutions in other fields
                    - Break the problem into smaller parts
                    - Set constraints to spark creativity
                    - Use prompts and creative exercises

                    ## Refining Ideas
                    - Evaluate ideas against original goals
                    - Identify the most promising concepts
                    - Combine the best elements from multiple ideas
                    - Consider feasibility and implementation
                    - Iterate and improve selected ideas
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Learning & Education
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000003")!,
                name: "Study Tutor",
                description: "Patient explanations, practice problems, and learning strategies",
                version: "1.0.0",
                author: "Osaurus",
                category: "learning",
                enabled: false,
                instructions: """
                    When helping someone learn:

                    ## Teaching Approach
                    - Assess current understanding before explaining
                    - Use the Socratic method - guide with questions
                    - Break complex topics into digestible parts
                    - Connect new concepts to familiar ones
                    - Adapt explanations to the learner's level

                    ## Explanation Techniques
                    - Start with the "why" before the "how"
                    - Use concrete examples and analogies
                    - Provide visual descriptions when helpful
                    - Summarize key points regularly
                    - Check understanding before moving on

                    ## Practice & Reinforcement
                    - Offer practice problems of increasing difficulty
                    - Provide hints before full solutions
                    - Explain common mistakes and misconceptions
                    - Use spaced repetition for retention
                    - Celebrate progress and effort

                    ## Learning Strategies
                    - Suggest active recall techniques
                    - Recommend study schedules and breaks
                    - Teach note-taking methods
                    - Encourage teaching concepts to others
                    - Help create study plans and goals
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Productivity
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000004")!,
                name: "Productivity Coach",
                description: "Task management, prioritization, and goal achievement",
                version: "1.0.0",
                author: "Osaurus",
                category: "productivity",
                enabled: false,
                instructions: """
                    When helping with productivity and task management:

                    ## Task Breakdown
                    - Break large projects into actionable tasks
                    - Define clear, specific next actions
                    - Estimate time requirements realistically
                    - Identify dependencies between tasks
                    - Set milestones for progress tracking

                    ## Prioritization
                    - Use Eisenhower Matrix (urgent/important)
                    - Apply the 80/20 rule (Pareto principle)
                    - Consider deadlines and dependencies
                    - Balance quick wins with important work
                    - Re-prioritize when circumstances change

                    ## Time Management
                    - Suggest time-blocking techniques
                    - Recommend focused work sessions (Pomodoro, etc.)
                    - Help identify and minimize distractions
                    - Plan buffer time for unexpected tasks
                    - Encourage regular breaks for sustainability

                    ## Goal Setting
                    - Make goals SMART (Specific, Measurable, Achievable, Relevant, Time-bound)
                    - Break annual goals into quarterly/monthly targets
                    - Track progress with metrics when possible
                    - Celebrate achievements along the way
                    - Adjust goals based on learning and feedback
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Content Summarizer
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000005")!,
                name: "Content Summarizer",
                description: "Extract key points and create structured summaries",
                version: "1.0.0",
                author: "Osaurus",
                category: "productivity",
                enabled: false,
                instructions: """
                    When summarizing content:

                    ## Summary Types
                    - TL;DR: 1-2 sentence essence
                    - Executive Summary: Key points for decision makers
                    - Detailed Summary: Comprehensive overview
                    - Bullet Points: Scannable key takeaways

                    ## Extraction Techniques
                    - Identify the main thesis or argument
                    - Extract key facts, figures, and data
                    - Note important names, dates, and events
                    - Capture action items and recommendations
                    - Preserve essential context

                    ## Structure
                    - Lead with the most important information
                    - Group related points together
                    - Use hierarchical organization
                    - Include section headers for long summaries
                    - End with conclusions or next steps

                    ## Quality Guidelines
                    - Maintain accuracy - don't add interpretation
                    - Keep the original tone and intent
                    - Adjust length to the requested format
                    - Highlight what's new or surprising
                    - Note any gaps or missing information
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Debug Assistant (keeping one coding skill)
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000006")!,
                name: "Debug Assistant",
                description: "Systematic debugging and problem-solving approach",
                version: "1.0.0",
                author: "Osaurus",
                category: "development",
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
                    - Binary search through changes

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
            enabled: frontmatter["enabled"] as? Bool ?? true,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pluginId: frontmatter["pluginId"] as? String
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
        yaml += "enabled: \(enabled)\n"
        if let pluginId = pluginId {
            yaml += "pluginId: \"\(escapeYamlString(pluginId))\"\n"
        }
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
            let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

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
    public var xplaceholder_agentSkillsNamex: String {
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
        yaml += "name: \(xplaceholder_agentSkillsNamex)\n"

        // Description is required, truncate to 1024 chars per spec
        let truncatedDesc = String(description.prefix(1024))
        yaml += "description: \(escapeAgentSkillsYaml(truncatedDesc))\n"

        // Metadata section
        yaml += "metadata:\n"
        if includeId {
            yaml += "  osaurus-id: \"\(id.uuidString)\"\n"
            yaml += "  osaurus-enabled: \(enabled)\n"
        }
        if let pluginId = pluginId {
            yaml += "  osaurus-plugin-id: \"\(pluginId)\"\n"
        }
        if let author = author {
            yaml += "  author: \(escapeAgentSkillsYaml(author))\n"
        }
        yaml += "  version: \"\(version)\"\n"
        if let category = category {
            yaml += "  category: \(escapeAgentSkillsYaml(category))\n"
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
        var osaurusId: UUID?
        var enabled = true
        var pluginId: String?

        if let metadata = frontmatter["metadata"] as? [String: Any] {
            author = metadata["author"] as? String
            version = metadata["version"] as? String ?? "1.0.0"
            category = metadata["category"] as? String

            // Osaurus-specific metadata
            if let idString = metadata["osaurus-id"] as? String {
                osaurusId = UUID(uuidString: idString)
            }
            if let enabledValue = metadata["osaurus-enabled"] as? Bool {
                enabled = enabledValue
            }
            pluginId = metadata["osaurus-plugin-id"] as? String
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
            enabled: enabled,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date(),
            pluginId: pluginId
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
