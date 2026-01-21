import Foundation

/// Status of a session group
enum SessionGroupStatus: String, Codable {
    case active     // Sessions are running
    case waiting    // At least one session is waiting for input
    case completed  // All sessions have completed
    case archived   // User archived the group
}

/// Persistent session group - tracks sessions launched together to multiple repos
struct SessionGroup: Codable, Identifiable {
    let id: UUID
    var name: String                    // Auto-generated from prompt or user-provided
    var prompt: String                  // The prompt sent to all repos
    var repoPaths: [String]             // Repository paths in this group
    var layout: GridLayout              // Grid layout for terminal display
    var createdAt: Date
    var lastActivity: Date
    var status: SessionGroupStatus      // active, waiting, completed, archived
    var claudeSessionIds: [String: String]  // repoPath -> claudeSessionId mapping

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        repoPaths: [String],
        layout: GridLayout = .auto,
        createdAt: Date = Date(),
        lastActivity: Date = Date(),
        status: SessionGroupStatus = .active,
        claudeSessionIds: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.repoPaths = repoPaths
        self.layout = layout
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.status = status
        self.claudeSessionIds = claudeSessionIds
    }

    // MARK: - Computed Properties

    /// Number of repositories in this group
    var repoCount: Int {
        repoPaths.count
    }

    /// Short display name derived from first few repo names
    var displayName: String {
        if !name.isEmpty {
            return name
        }

        // Generate from repo names
        let repoNames = repoPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        if repoNames.count <= 2 {
            return repoNames.joined(separator: " & ")
        } else {
            return "\(repoNames[0]) + \(repoNames.count - 1) more"
        }
    }

    /// Short prompt preview (first 50 chars)
    var promptPreview: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 50 {
            return trimmed
        }
        return String(trimmed.prefix(50)) + "..."
    }

    /// Whether this group is considered active (not completed or archived)
    var isActive: Bool {
        status == .active || status == .waiting
    }

    /// Relative time string for last activity
    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActivity, relativeTo: Date())
    }

    // MARK: - Static Helpers

    /// Generate a name from the prompt
    static func generateName(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Take first line or first 40 characters
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        if firstLine.count <= 40 {
            return firstLine
        }

        // Find a good break point (word boundary)
        let prefix = String(firstLine.prefix(40))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "..."
        }
        return prefix + "..."
    }
}

// MARK: - Session Group Extensions

extension SessionGroup {
    /// Create a new active session group from a launch action
    static func create(
        prompt: String,
        repoPaths: [String],
        layout: GridLayout
    ) -> SessionGroup {
        let name = prompt.isEmpty ? "Multi-session" : generateName(from: prompt)
        return SessionGroup(
            name: name,
            prompt: prompt,
            repoPaths: repoPaths,
            layout: layout,
            status: .active
        )
    }

    /// Update status based on session states
    mutating func updateStatus(runningCount: Int, waitingCount: Int) {
        let now = Date()
        lastActivity = now

        if runningCount == 0 && waitingCount == 0 {
            // All sessions have terminated
            if status != .archived {
                status = .completed
            }
        } else if waitingCount > 0 {
            status = .waiting
        } else {
            status = .active
        }
    }

    /// Archive the session group
    mutating func archive() {
        status = .archived
        lastActivity = Date()
    }

    /// Associate a Claude session ID with a repo path
    mutating func setClaudeSessionId(_ sessionId: String, for repoPath: String) {
        claudeSessionIds[repoPath] = sessionId
        lastActivity = Date()
    }
}
