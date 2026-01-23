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
    var lastEventType: String? = nil  // Last JSONL event type for state tracking
    var lastStopReason: String? = nil // Stop reason for assistant messages

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
    private let refreshInterval: TimeInterval = 5.0 // Refresh every 5 seconds (backup)

    /// File system watchers for project directories
    private var directoryWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var fileDescriptors: [String: Int32] = [:]

    /// Callback when a session transitions to waiting state
    var onSessionBecameWaiting: ((DiscoveredSession) -> Void)?

    /// Track previous states to detect transitions
    private var previousSessionStates: [String: ClaudeSessionStatus] = [:]

    private init() {}

    // MARK: - Public API

    /// Starts automatic refresh of session statuses
    func startMonitoring() {
        // Pre-warm the process cache asynchronously
        refreshProcessCacheIfNeeded()

        refresh()

        // Start file system watchers for real-time updates
        startDirectoryWatchers()

        // Keep polling as backup for missed events
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
    }

    /// Stops automatic refresh
    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopDirectoryWatchers()
    }

    /// Starts file system watchers for project directories
    private func startDirectoryWatchers() {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else {
            return
        }

        for entry in entries {
            let projectDir = projectsDir.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue {
                watchProjectDirectory(projectDir.path)
            }
        }
    }

    /// Stops all directory watchers
    private func stopDirectoryWatchers() {
        for (path, source) in directoryWatchers {
            source.cancel()
            if let fd = fileDescriptors[path] {
                close(fd)
            }
        }
        directoryWatchers.removeAll()
        fileDescriptors.removeAll()
    }

    /// Watches a single project directory for file changes
    private func watchProjectDirectory(_ path: String) {
        guard directoryWatchers[path] == nil else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        fileDescriptors[path] = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            // File change detected - refresh statuses immediately
            self?.refreshStatuses()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        directoryWatchers[path] = source
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
        // Trigger async process cache refresh (non-blocking)
        refreshProcessCacheIfNeeded()

        for i in repoGroups.indices {
            for j in repoGroups[i].sessions.indices {
                let session = repoGroups[i].sessions[j]
                if let info = try? FileManager.default.attributesOfItem(atPath: session.filePath),
                   let modDate = info[.modificationDate] as? Date {
                    repoGroups[i].sessions[j].lastActivity = modDate

                    // Use JSONL-based status detection for authoritative state
                    let (newStatus, lastEventType, stopReason) = detectStatusFromJSONL(
                        path: session.filePath,
                        modDate: modDate,
                        repoPath: session.repoPath
                    )
                    repoGroups[i].sessions[j].status = newStatus
                    repoGroups[i].sessions[j].lastEventType = lastEventType
                    repoGroups[i].sessions[j].lastStopReason = stopReason

                    // Detect state transitions and notify
                    let previousStatus = previousSessionStates[session.id]
                    if newStatus == .waiting && previousStatus != .waiting {
                        let updatedSession = repoGroups[i].sessions[j]
                        onSessionBecameWaiting?(updatedSession)
                    }
                    previousSessionStates[session.id] = newStatus
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

    /// Finds a session by its Claude session ID
    func session(byId sessionId: String) -> DiscoveredSession? {
        for group in repoGroups {
            if let session = group.sessions.first(where: { $0.id == sessionId }) {
                return session
            }
        }
        return nil
    }

    /// Finds sessions for a repository path (working directory)
    /// Supports exact match and prefix matching (cwd might be a subdirectory)
    func sessions(forRepoPath repoPath: String) -> [DiscoveredSession] {
        // Try exact match first
        if let group = repoGroups.first(where: { $0.id == repoPath }) {
            return group.sessions
        }

        // Try prefix match (repo might be a parent of the cwd)
        for group in repoGroups {
            if repoPath.hasPrefix(group.id + "/") || repoPath.hasPrefix(group.id) {
                return group.sessions
            }
        }

        return []
    }

    /// Finds the most recent active session for a repository path
    /// Returns the session that was most recently modified and is not idle
    func mostRecentActiveSession(forRepoPath repoPath: String) -> DiscoveredSession? {
        let matchingSessions = sessions(forRepoPath: repoPath)
        return matchingSessions
            .filter { $0.status != .idle }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    /// Finds a session that was created after a specific time for a repository path
    /// Useful for associating newly launched terminals with their Claude session
    func session(forRepoPath repoPath: String, createdAfter: Date) -> DiscoveredSession? {
        let matchingSessions = sessions(forRepoPath: repoPath)
        return matchingSessions
            .filter { $0.lastActivity >= createdAfter }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
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
        let (status, lastEventType, stopReason) = detectStatusFromJSONL(path: path, modDate: modDate, repoPath: repoPath)

        return DiscoveredSession(
            id: sessionId,
            filePath: path,
            repoPath: repoPath,
            title: title ?? String(sessionId.prefix(8)) + "...",
            status: status,
            lastActivity: modDate,
            messageCount: messageCount,
            lastEventType: lastEventType,
            lastStopReason: stopReason
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

    /// Determines session status based on file modification time and process activity
    private func detectStatus(modificationDate: Date, repoPath: String) -> ClaudeSessionStatus {
        // Check cached process info (never blocks - uses last known state)
        if Self.processCache[repoPath] == true {
            return .running
        }

        // Fall back to file modification time
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

    /// Determines session status from JSONL content (authoritative state detection)
    /// Returns (status, lastEventType, stopReason)
    /// Note: Internal for testability
    func detectStatusFromJSONL(path: String, modDate: Date, repoPath: String) -> (ClaudeSessionStatus, String?, String?) {
        // If file is old (>5 minutes), it's idle regardless of content
        let age = Date().timeIntervalSince(modDate)
        if age > 300 {
            return (.idle, nil, nil)
        }

        // Read last few events from JSONL file efficiently (seek to end, read last ~10KB)
        guard let lastEvent = readLastJSONLEvent(path) else {
            // Fallback to time-based detection
            return (detectStatus(modificationDate: modDate, repoPath: repoPath), nil, nil)
        }

        let eventType = lastEvent["type"] as? String

        switch eventType {
        case "user":
            // User just submitted a prompt - Claude is running
            return (.running, eventType, nil)

        case "assistant":
            // Check stop_reason to determine if Claude is done
            if let message = lastEvent["message"] as? [String: Any],
               let stopReason = message["stop_reason"] as? String {
                if stopReason == "end_turn" {
                    // Claude finished responding - waiting for input
                    return (.waiting, eventType, stopReason)
                } else if stopReason == "tool_use" {
                    // Claude is using a tool - still running
                    return (.running, eventType, stopReason)
                }
            }
            // No stop_reason or unknown - likely still streaming
            // Check if file was modified recently (within 30s) to determine if actively streaming
            if age < 30 {
                return (.running, eventType, nil)
            }
            // File is older but not too old - might be waiting
            return (.waiting, eventType, nil)

        case "tool_result":
            // Tool result received - Claude is running (processing result)
            return (.running, eventType, nil)

        case "progress":
            // Progress events indicate Claude is actively working
            // (hook progress, tool execution, thinking, etc.)
            return (.running, eventType, nil)

        case "result":
            // Result events from tool execution - Claude is running
            return (.running, eventType, nil)

        case "summary":
            // Summary event - session is idle or waiting
            return (.waiting, eventType, nil)

        default:
            // For unknown event types, use time-based heuristics
            // If file was modified very recently (within 30s), probably running
            if age < 30 {
                return (.running, eventType, nil)
            }
            // Otherwise fall back to standard time-based detection
            return (detectStatus(modificationDate: modDate, repoPath: repoPath), eventType, nil)
        }
    }

    /// Reads the last JSONL event from a file efficiently
    /// Seeks to end and reads last ~10KB to find the last complete JSON line
    /// Note: Internal for testability
    func readLastJSONLEvent(_ path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        // Get file size
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return nil
        }

        // Read last 10KB (should contain multiple recent events)
        let bytesToRead: UInt64 = min(10240, fileSize)
        let offset = fileSize - bytesToRead

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Split by newlines and find last valid JSON
        let lines = content.components(separatedBy: .newlines)

        // Iterate from end to find last valid JSON object
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            return json
        }

        return nil
    }

    /// Cache for running Claude processes (repo path -> is running)
    private static var processCache: [String: Bool] = [:]
    private static var lastProcessCheck: Date?
    private static var isRefreshing = false

    /// Refreshes the process cache asynchronously (called during status refresh)
    private func refreshProcessCacheIfNeeded() {
        let now = Date()

        // Only refresh every 5 seconds and don't overlap refreshes
        guard !Self.isRefreshing else { return }
        if let lastCheck = Self.lastProcessCheck,
           now.timeIntervalSince(lastCheck) < 5.0 {
            return
        }

        Self.isRefreshing = true
        Self.lastProcessCheck = now

        // Run lsof in background to avoid blocking UI
        DispatchQueue.global(qos: .utility).async {
            let result = self.findRunningClaudeProcesses()

            DispatchQueue.main.async {
                Self.processCache = result
                Self.isRefreshing = false
            }
        }
    }

    /// Finds all running Claude processes and their working directories
    private func findRunningClaudeProcesses() -> [String: Bool] {
        var result: [String: Bool] = [:]

        // Use pgrep + lsof with timeout to find Claude processes
        // pgrep is faster than lsof -c for initial check
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Use timeout to prevent hanging, and only get cwd for claude processes
        task.arguments = ["-c", "for pid in $(pgrep -x claude 2>/dev/null); do lsof -p $pid 2>/dev/null | grep cwd | awk '{print $NF}'; done"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        result[trimmed] = true
                    }
                }
            }
        } catch {
            // Silently fail - fall back to file-based detection
        }

        return result
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
