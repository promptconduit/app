import Foundation

/// Represents a saved session that can be resumed
struct SessionHistory: Codable, Identifiable {
    var id: String { sessionId }

    let sessionId: String
    let repositoryPath: String
    let prompt: String
    let createdAt: Date
    var lastActivity: Date
    var status: SessionHistoryStatus
    var messageCount: Int

    /// Repository name derived from path
    var repositoryName: String {
        URL(fileURLWithPath: repositoryPath).lastPathComponent
    }

    /// Short version of the prompt for display
    var shortPrompt: String {
        if prompt.count > 60 {
            return String(prompt.prefix(57)) + "..."
        }
        return prompt
    }

    /// Relative time description (e.g., "2 hours ago")
    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActivity, relativeTo: Date())
    }

    /// More detailed time description
    var detailedTime: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(lastActivity) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Today at \(formatter.string(from: lastActivity))"
        } else if calendar.isDateInYesterday(lastActivity) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Yesterday at \(formatter.string(from: lastActivity))"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: lastActivity)
        }
    }
}

enum SessionHistoryStatus: String, Codable {
    case completed = "Completed"
    case failed = "Failed"
    case interrupted = "Interrupted"

    var icon: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .interrupted: return "pause.circle.fill"
        }
    }
}
