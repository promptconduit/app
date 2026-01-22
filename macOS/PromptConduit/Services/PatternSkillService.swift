import Foundation

// MARK: - Types

/// Where to save the skill
enum SkillSaveLocation: String, CaseIterable, Identifiable {
    case global = "Global"
    case project = "Project"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .global:
            return "Available in all projects (~/.claude/commands/)"
        case .project:
            return "Project-specific, can be committed to git"
        }
    }
}

/// Result of skill save operation
enum SkillSaveResult: Equatable {
    case success(path: String)
    case fileExists(path: String)
    case directoryCreationFailed(String)
    case writeFailed(String)
}

// MARK: - PatternSkillService

/// Service for converting detected patterns into Claude Code skills (slash commands)
class PatternSkillService {

    // MARK: - Path Helpers

    /// Global commands directory: ~/.claude/commands/
    private var globalCommandsPath: String {
        SettingsService.claudeCommandsPath
    }

    /// Project commands directory: [repoPath]/.claude/commands/
    private func projectCommandsPath(for repoPath: String) -> String {
        (repoPath as NSString).appendingPathComponent(".claude/commands")
    }

    /// Get the full path where a skill would be saved
    func skillPath(name: String, location: SkillSaveLocation, projectPath: String?) -> String {
        let directory: String
        switch location {
        case .global:
            directory = globalCommandsPath
        case .project:
            guard let project = projectPath else {
                return globalCommandsPath + "/\(name).md"
            }
            directory = projectCommandsPath(for: project)
        }
        return (directory as NSString).appendingPathComponent("\(name).md")
    }

    // MARK: - Skill Name Generation

    /// Generate a valid skill name from pattern content
    /// Converts to kebab-case, removes special characters, truncates if needed
    func suggestSkillName(from pattern: DetectedPattern) -> String {
        let content = pattern.representative.content

        // Take first ~50 characters or first sentence
        var preview = content.prefix(50)
        if let sentenceEnd = preview.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) {
            preview = preview[..<sentenceEnd]
        }

        // Convert to kebab-case
        let words = String(preview)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)  // Max 5 words

        let name = words.joined(separator: "-")

        // Ensure non-empty and valid
        if name.isEmpty {
            return "pattern-\(pattern.id.uuidString.prefix(8).lowercased())"
        }

        return name
    }

    /// Generate description from pattern metadata
    func suggestDescription(from pattern: DetectedPattern) -> String {
        let count = pattern.count
        let sessions = pattern.sessionCount
        let repos = pattern.repoCount

        var parts: [String] = []

        if count > 1 {
            parts.append("\(count) similar prompts")
        }

        if sessions > 1 {
            parts.append("across \(sessions) sessions")
        }

        if repos > 1 {
            parts.append("in \(repos) repositories")
        }

        if parts.isEmpty {
            return "Saved from detected pattern"
        }

        return "Pattern: " + parts.joined(separator: ", ")
    }

    /// Suggest location based on pattern's repo diversity
    /// Returns .project if pattern appears in only 1 repo, .global otherwise
    func suggestLocation(from pattern: DetectedPattern) -> SkillSaveLocation {
        return pattern.repoCount <= 1 ? .project : .global
    }

    // MARK: - Markdown Generation

    /// Generate skill markdown from a detected pattern
    func generateSkillMarkdown(
        pattern: DetectedPattern,
        name: String,
        description: String
    ) -> String {
        let content = pattern.representative.content

        return """
        ---
        description: \(description)
        ---

        \(content)
        """
    }

    // MARK: - File Operations

    /// Check if a skill with this name already exists at location
    func skillExists(name: String, location: SkillSaveLocation, projectPath: String?) -> Bool {
        let path = skillPath(name: name, location: location, projectPath: projectPath)
        return FileManager.default.fileExists(atPath: path)
    }

    /// Save skill to specified location
    func saveSkill(
        pattern: DetectedPattern,
        name: String,
        description: String,
        location: SkillSaveLocation,
        projectPath: String?,
        overwrite: Bool = false
    ) -> SkillSaveResult {
        let filePath = skillPath(name: name, location: location, projectPath: projectPath)
        let directory = (filePath as NSString).deletingLastPathComponent

        // Check if file already exists (unless overwriting)
        if !overwrite && FileManager.default.fileExists(atPath: filePath) {
            return .fileExists(path: filePath)
        }

        // Create directory if needed
        do {
            try SettingsService.shared.createDirectoryIfNeeded(directory)
        } catch {
            return .directoryCreationFailed(error.localizedDescription)
        }

        // Generate markdown content
        let markdown = generateSkillMarkdown(pattern: pattern, name: name, description: description)

        // Write file
        do {
            try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
            return .success(path: filePath)
        } catch {
            return .writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Utilities

    /// Get the primary repository path from a pattern (most common repo)
    func primaryRepoPath(from pattern: DetectedPattern) -> String? {
        // Count repo occurrences
        var repoCounts: [String: Int] = [:]
        for member in pattern.members {
            let repo = member.message.repoPath
            repoCounts[repo, default: 0] += 1
        }

        // Return the most common repo
        return repoCounts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Quick Save from Notification

    /// Quickly save a repeat candidate as a skill with auto-generated defaults
    /// - Parameters:
    ///   - candidate: The repeat candidate to convert
    ///   - originalMessage: The original indexed message
    ///   - suggestedName: Pre-suggested skill name
    ///   - suggestedDescription: Pre-suggested description
    ///   - suggestedLocation: Pre-suggested save location
    /// - Returns: Result of the save operation
    func quickSaveFromCandidate(
        candidate: RepeatCandidate,
        originalMessage: IndexedMessage,
        suggestedName: String,
        suggestedDescription: String,
        suggestedLocation: SkillSaveLocation
    ) -> SkillSaveResult {
        let filePath = skillPath(
            name: suggestedName,
            location: suggestedLocation,
            projectPath: candidate.repoPath
        )
        let directory = (filePath as NSString).deletingLastPathComponent

        // Check if file already exists - generate unique name if so
        var finalName = suggestedName
        var finalPath = filePath
        var counter = 1

        while FileManager.default.fileExists(atPath: finalPath) {
            finalName = "\(suggestedName)-\(counter)"
            finalPath = skillPath(
                name: finalName,
                location: suggestedLocation,
                projectPath: candidate.repoPath
            )
            counter += 1

            // Safety limit
            if counter > 100 {
                return .fileExists(path: filePath)
            }
        }

        // Create directory if needed
        do {
            try SettingsService.shared.createDirectoryIfNeeded(directory)
        } catch {
            return .directoryCreationFailed(error.localizedDescription)
        }

        // Generate markdown content
        let markdown = generateSkillMarkdownFromCandidate(
            content: originalMessage.content,
            name: finalName,
            description: suggestedDescription
        )

        // Write file
        do {
            try markdown.write(toFile: finalPath, atomically: true, encoding: .utf8)

            // Mark candidate as converted
            RepeatTracker.shared.markAsConverted(candidate.id)

            return .success(path: finalPath)
        } catch {
            return .writeFailed(error.localizedDescription)
        }
    }

    /// Generate skill markdown from a repeat candidate's content
    private func generateSkillMarkdownFromCandidate(
        content: String,
        name: String,
        description: String
    ) -> String {
        return """
        ---
        description: \(description)
        ---

        \(content)
        """
    }

    /// Sanitize a skill name to ensure it's valid for filenames
    func sanitizeSkillName(_ name: String) -> String {
        // Remove or replace invalid characters
        let invalidChars = CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-_"))
        var sanitized = name
            .components(separatedBy: invalidChars)
            .joined(separator: "-")
            .lowercased()

        // Collapse multiple consecutive dashes into a single dash
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }

        // Remove leading/trailing dashes
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? "skill" : sanitized
    }
}
