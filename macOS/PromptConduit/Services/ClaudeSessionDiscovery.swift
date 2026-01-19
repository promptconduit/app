import Foundation
import Combine

/// Represents the live status of a Claude Code session
enum ClaudeSessionStatus: String, Codable {
    case running    // File modified within 30 seconds
    case waiting    // File modified within 5 minutes (needs attention)
    case idle       // File not recently modified
    case error      // Session file missing or invalid

    var icon: String {
        switch self {
        case .running: return "circle.fill"
        case .waiting: return "circle.lefthalf.filled"
        case .idle: return "circle"
        case .error: return "xmark.circle"
        }
    }

    var color: String {
        switch self {
        case .running: return "green"
        case .waiting: return "yellow"
        case .idle: return "gray"
        case .error: return "red"
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        case .error: return "Error"
        }
    }
}

/// Represents a discovered Claude Code session
struct DiscoveredSession: Identifiable, Equatable {
    let id: String          // Session ID (filename without .jsonl)
    let filePath: String    // Full path to the session file
    let repoPath: String    // Repository path this session belongs to
    var title: String       // Session title (from summary or first prompt)
    var status: ClaudeSessionStatus
    var lastActivity: Date
    var messageCount: Int

    /// Repository name derived from path
    var repoName: String {
        URL(fileURLWithPath: repoPath).lastPathComponent
    }

    /// Relative time description
    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActivity, relativeTo: Date())
    }
}

/// Represents a repository group with its sessions
struct RepoSessionGroup: Identifiable {
    let id: String          // Full repo path
    var displayName: String // Display name (may include parent path for disambiguation)
    var sessions: [DiscoveredSession]
    var isExpanded: Bool = true

    /// Aggregate status (highest priority among sessions)
    var aggregateStatus: ClaudeSessionStatus {
        if sessions.contains(where: { $0.status == .running }) { return .running }
        if sessions.contains(where: { $0.status == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.status == .error }) { return .error }
        return .idle
    }

    /// Total session count
    var sessionCount: Int { sessions.count }
}

/// Service for discovering and monitoring Claude Code sessions
class ClaudeSessionDiscovery: ObservableObject {
    static let shared = ClaudeSessionDiscovery()

    @Published private(set) var repoGroups: [RepoSessionGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 5.0 // Refresh every 5 seconds

    private init() {}

    // MARK: - Public API

    /// Starts automatic refresh of session statuses
    func startMonitoring() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
    }

    /// Stops automatic refresh
    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Performs a full refresh of all sessions
    func refresh() {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let groups = self?.discoverSessions() ?? []

            DispatchQueue.main.async {
                self?.repoGroups = groups
                self?.isLoading = false
                self?.lastRefresh = Date()
            }
        }
    }

    /// Refreshes just the status of existing sessions (faster)
    func refreshStatuses() {
        for i in repoGroups.indices {
            for j in repoGroups[i].sessions.indices {
                let session = repoGroups[i].sessions[j]
                if let info = try? FileManager.default.attributesOfItem(atPath: session.filePath),
                   let modDate = info[.modificationDate] as? Date {
                    repoGroups[i].sessions[j].lastActivity = modDate
                    repoGroups[i].sessions[j].status = detectStatus(modificationDate: modDate)
                }
            }
        }
        lastRefresh = Date()
    }

    /// Toggles expansion state of a repo group
    func toggleExpanded(_ repoPath: String) {
        if let index = repoGroups.firstIndex(where: { $0.id == repoPath }) {
            repoGroups[index].isExpanded.toggle()
        }
    }

    // MARK: - Discovery

    private func discoverSessions() -> [RepoSessionGroup] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return []
        }

        var groups: [String: RepoSessionGroup] = [:]

        // Walk the projects directory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else {
            return []
        }

        for entry in entries {
            let projectDir = projectsDir.appendingPathComponent(entry)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            // Decode the repo path from the directory name
            guard let repoPath = decodeProjectPath(entry) else {
                continue
            }

            // Find session files
            let sessionFiles = findSessionFiles(in: projectDir.path)

            for sessionFile in sessionFiles {
                guard let session = parseSessionFile(sessionFile, repoPath: repoPath) else {
                    continue
                }

                if groups[repoPath] == nil {
                    groups[repoPath] = RepoSessionGroup(
                        id: repoPath,
                        displayName: URL(fileURLWithPath: repoPath).lastPathComponent,
                        sessions: []
                    )
                }

                groups[repoPath]?.sessions.append(session)
            }
        }

        // Sort sessions within each group by last activity (newest first)
        for key in groups.keys {
            groups[key]?.sessions.sort { $0.lastActivity > $1.lastActivity }
        }

        // Convert to array and disambiguate names
        var result = Array(groups.values)
        disambiguateNames(&result)

        // Sort groups alphabetically
        result.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }

        return result
    }

    /// Decodes the URL-encoded project path
    private func decodeProjectPath(_ encoded: String) -> String? {
        // Handle URL-encoded paths
        if let decoded = encoded.removingPercentEncoding, decoded != encoded {
            return decoded
        }

        // Handle dash-encoded paths (older format)
        if encoded.hasPrefix("-") {
            let decoded = "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
            return decoded
        }

        return encoded
    }

    /// Finds all .jsonl session files in a project directory
    private func findSessionFiles(in directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
            return []
        }

        var files: [String] = []
        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".jsonl") && !file.hasPrefix("agent-") {
                files.append(directory + "/" + file)
            }
        }
        return files
    }

    /// Parses a session file to extract metadata
    private func parseSessionFile(_ path: String, repoPath: String) -> DiscoveredSession? {
        guard let info = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = info[.modificationDate] as? Date else {
            return nil
        }

        let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let (title, messageCount) = extractSessionMetadata(path, sessionId: sessionId)

        return DiscoveredSession(
            id: sessionId,
            filePath: path,
            repoPath: repoPath,
            title: title ?? String(sessionId.prefix(8)) + "...",
            status: detectStatus(modificationDate: modDate),
            lastActivity: modDate,
            messageCount: messageCount
        )
    }

    /// Extracts title and message count from a session file
    private func extractSessionMetadata(_ path: String, sessionId: String) -> (title: String?, messageCount: Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return (nil, 0)
        }
        defer { try? handle.close() }

        var title: String?
        var messageCount = 0
        var firstUserPrompt: String?

        // Read file line by line (simplified - reads whole file)
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return (nil, 0)
        }

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String ?? ""

            // Count user and assistant messages
            if type == "user" || type == "assistant" {
                messageCount += 1
            }

            // Get title from summary (highest priority)
            if type == "summary" {
                if let leafTitle = json["leafTitle"] as? String, !leafTitle.isEmpty {
                    title = leafTitle
                } else if let summary = json["summary"] as? String, !summary.isEmpty {
                    title = summary.count > 60 ? String(summary.prefix(57)) + "..." : summary
                }
            }

            // Capture first user prompt for fallback title generation
            if type == "user" && firstUserPrompt == nil {
                firstUserPrompt = extractPromptText(from: json)
            }
        }

        // If no title from summary, try to get or generate one
        if title == nil {
            // Check cache first
            if let cachedTitle = SessionTitleCache.shared.getTitle(sessionId: sessionId) {
                title = cachedTitle
            }
            // Generate from first prompt if available
            else if let prompt = firstUserPrompt, !prompt.isEmpty {
                let generatedTitle = SessionTitleCache.generateTitle(from: prompt)
                SessionTitleCache.shared.setTitle(sessionId: sessionId, title: generatedTitle)
                title = generatedTitle
            }
        }

        return (title, messageCount)
    }

    /// Extracts text content from a user message JSON
    private func extractPromptText(from json: [String: Any]) -> String? {
        guard let message = json["message"] as? [String: Any] else {
            return nil
        }

        // Handle content as string
        if let content = message["content"] as? String {
            return content
        }

        // Handle content as array of blocks
        if let contentArray = message["content"] as? [[String: Any]] {
            var textParts: [String] = []
            for block in contentArray {
                if let blockType = block["type"] as? String, blockType == "text",
                   let text = block["text"] as? String {
                    textParts.append(text)
                }
            }
            return textParts.joined(separator: " ")
        }

        return nil
    }

    /// Determines session status based on file modification time
    private func detectStatus(modificationDate: Date) -> ClaudeSessionStatus {
        let age = Date().timeIntervalSince(modificationDate)

        switch age {
        case ..<30:
            return .running
        case ..<300: // 5 minutes
            return .waiting
        default:
            return .idle
        }
    }

    /// Disambiguates repo names when multiple repos have the same base name
    private func disambiguateNames(_ groups: inout [RepoSessionGroup]) {
        // Find groups with duplicate base names
        var nameCount: [String: [Int]] = [:]
        for (index, group) in groups.enumerated() {
            let baseName = URL(fileURLWithPath: group.id).lastPathComponent
            nameCount[baseName, default: []].append(index)
        }

        // For each set of duplicates, add parent path context
        for (_, indices) in nameCount where indices.count > 1 {
            for index in indices {
                let path = groups[index].id
                let components = path.split(separator: "/").map(String.init)

                // Use last 2 components (parent/name)
                if components.count >= 2 {
                    groups[index].displayName = components.suffix(2).joined(separator: "/")
                } else if components.count == 1 {
                    groups[index].displayName = components[0]
                }
            }
        }
    }
}
