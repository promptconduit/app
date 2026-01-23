import Foundation
import Combine
import SwiftTerm
import AppKit

/// Information about a terminal session launched from PromptConduit
struct TerminalSessionInfo: Identifiable {
    let id: UUID
    let repoName: String
    let workingDirectory: String
    var isRunning: Bool
    var isWaiting: Bool = true  // Default to waiting (Claude starts ready for input)
    var groupId: UUID? = nil  // For multi-session groups
    var claudeSessionId: String? = nil  // Claude Code's session ID for reliable matching
    weak var terminalView: LocalProcessTerminalView? = nil
    let launchTime: Date  // When this terminal was launched (for session association)

    // MARK: - Prompt Management (Single Source of Truth)
    var pendingPrompt: String? = nil  // Prompt to send when session becomes ready
    var isReadyForPrompt: Bool = false  // Set true when JSONL shows session is waiting
    var promptSent: Bool = false  // Track if we've already sent the prompt
}

/// Manages terminal sessions launched from PromptConduit
/// Separate from AgentManager which handles PTY-based print-mode sessions
class TerminalSessionManager: ObservableObject {
    static let shared = TerminalSessionManager()

    @Published private(set) var sessions: [TerminalSessionInfo] = []
    @Published private(set) var sessionGroups: [MultiSessionGroup] = []

    /// Sessions that are ready to receive their initial prompt
    /// Views observe this to know when to send prompts
    @Published private(set) var sessionsReadyForPrompt: Set<UUID> = []

    /// Groups with broadcast mode enabled - keystrokes go to all terminals in the group
    @Published private(set) var broadcastEnabledGroups: Set<UUID> = []

    /// Flag to prevent callbacks during cleanup
    private var isCleaningUp = false

    /// Combine cancellables for JSONL monitoring subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Number of sessions waiting for input
    var waitingCount: Int {
        sessions.filter { $0.isWaiting }.count
    }

    /// Number of running sessions
    var runningCount: Int {
        sessions.filter { $0.isRunning }.count
    }

    private init() {
        setupJSONLMonitoring()
    }

    // MARK: - JSONL-Based State Monitoring

    private func setupJSONLMonitoring() {
        let logPath = "/tmp/promptconduit-terminal.log"

        func jsonlLog(_ msg: String) {
            let line = "[JSONL \(Date())] \(msg)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            }
            print("[JSONL] \(msg)")
        }

        // Subscribe to ClaudeSessionDiscovery updates
        ClaudeSessionDiscovery.shared.$repoGroups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                self?.reconcileSessionStates(from: groups)
            }
            .store(in: &cancellables)

        // Subscribe to session waiting notifications
        ClaudeSessionDiscovery.shared.onSessionBecameWaiting = { [weak self] discoveredSession in
            jsonlLog("Session became waiting: \(discoveredSession.id) in \(discoveredSession.repoPath)")
            self?.handleSessionBecameWaiting(discoveredSession)
        }

        jsonlLog("JSONL monitoring setup complete")
    }

    /// Reconciles our terminal session states with discovered JSONL sessions
    private func reconcileSessionStates(from groups: [RepoSessionGroup]) {
        guard !isCleaningUp else { return }

        let logPath = "/tmp/promptconduit-terminal.log"

        for i in sessions.indices {
            let session = sessions[i]

            // Find matching discovered session by claudeSessionId or cwd+timing
            if let discovered = findMatchingDiscoveredSession(for: session, in: groups) {
                // Update Claude session ID if we found a match
                if sessions[i].claudeSessionId == nil {
                    sessions[i].claudeSessionId = discovered.id

                    let logMsg = "[JSONL] Associated terminal \(session.repoName) with Claude session \(discovered.id)\n"
                    if let handle = FileHandle(forWritingAtPath: logPath) {
                        handle.seekToEndOfFile()
                        handle.write(logMsg.data(using: .utf8)!)
                        handle.closeFile()
                    }
                }

                // Update waiting state from JSONL-detected status
                let isWaiting = discovered.status == .waiting
                if sessions[i].isWaiting != isWaiting {
                    let logMsg = "[JSONL] Session \(session.repoName): isWaiting changed to \(isWaiting) (status: \(discovered.status))\n"
                    if let handle = FileHandle(forWritingAtPath: logPath) {
                        handle.seekToEndOfFile()
                        handle.write(logMsg.data(using: .utf8)!)
                        handle.closeFile()
                    }
                    updateWaitingState(session.id, isWaiting: isWaiting)
                }

                // Mark session as ready for prompt if waiting and has pending prompt
                if isWaiting && sessions[i].pendingPrompt != nil && !sessions[i].promptSent && !sessions[i].isReadyForPrompt {
                    let logMsg = "[JSONL] Session \(session.repoName) marked READY FOR PROMPT\n"
                    if let handle = FileHandle(forWritingAtPath: logPath) {
                        handle.seekToEndOfFile()
                        handle.write(logMsg.data(using: .utf8)!)
                        handle.closeFile()
                    }
                    sessions[i].isReadyForPrompt = true
                    sessionsReadyForPrompt.insert(session.id)
                }
            }
        }
    }

    /// Finds a matching discovered session for a terminal session
    private func findMatchingDiscoveredSession(for session: TerminalSessionInfo, in groups: [RepoSessionGroup]) -> DiscoveredSession? {
        // Try Claude session ID first (most reliable)
        if let claudeId = session.claudeSessionId {
            for group in groups {
                if let discovered = group.sessions.first(where: { $0.id == claudeId }) {
                    return discovered
                }
            }
        }

        // Try matching by working directory + timing
        // Look for sessions in the same repo that started after our terminal launched
        for group in groups {
            // Check if the terminal's working directory matches this group's repo
            let repoPath = group.id
            guard session.workingDirectory == repoPath ||
                  session.workingDirectory.hasPrefix(repoPath + "/") ||
                  repoPath.hasPrefix(session.workingDirectory + "/") else {
                continue
            }

            // Find sessions that started after our terminal was launched
            // Give a 30-second window for Claude to initialize and write first event
            let matchWindow = session.launchTime.addingTimeInterval(-5) // Small buffer for timing
            let matchingSessions = group.sessions.filter { $0.lastActivity >= matchWindow }

            // Return the most recent one
            if let discovered = matchingSessions.sorted(by: { $0.lastActivity > $1.lastActivity }).first {
                return discovered
            }
        }

        return nil
    }

    /// Handles when a discovered session becomes waiting
    private func handleSessionBecameWaiting(_ discoveredSession: DiscoveredSession) {
        // Find the terminal session associated with this discovered session
        for i in sessions.indices {
            let session = sessions[i]

            // Match by claudeSessionId or by working directory
            let matches = session.claudeSessionId == discoveredSession.id ||
                          session.workingDirectory == discoveredSession.repoPath ||
                          session.workingDirectory.hasPrefix(discoveredSession.repoPath + "/")

            if matches {
                // Mark session as ready for prompt if it has a pending prompt
                if sessions[i].pendingPrompt != nil && !sessions[i].promptSent && !sessions[i].isReadyForPrompt {
                    sessions[i].isReadyForPrompt = true
                    sessionsReadyForPrompt.insert(session.id)
                }
                break
            }
        }
    }

    /// Finds session by Claude session ID first, then by cwd/directory name
    private func findSessionIndex(cwd: String, sessionId: String?) -> Int? {
        // Try Claude session ID first (most reliable)
        if let sessionId = sessionId, !sessionId.isEmpty {
            if let index = sessions.firstIndex(where: { $0.claudeSessionId == sessionId }) {
                return index
            }
        }

        // Try exact cwd match - prefer sessions with pending prompts
        if let index = sessions.firstIndex(where: { $0.workingDirectory == cwd && $0.pendingPrompt != nil && !$0.promptSent }) {
            return index
        }
        if let index = sessions.firstIndex(where: { $0.workingDirectory == cwd }) {
            return index
        }

        // Try prefix match
        if let index = sessions.firstIndex(where: { cwd.hasPrefix($0.workingDirectory + "/") && $0.pendingPrompt != nil && !$0.promptSent }) {
            return index
        }
        if let index = sessions.firstIndex(where: { cwd.hasPrefix($0.workingDirectory + "/") }) {
            return index
        }

        return nil
    }

    // MARK: - Session Management

    /// Registers a new terminal session
    /// - Parameters:
    ///   - id: Unique session ID
    ///   - repoName: Display name for the repository
    ///   - workingDirectory: Full path to the working directory
    ///   - groupId: Optional group ID for multi-session groups
    ///   - pendingPrompt: Optional prompt to send when session becomes ready
    func registerSession(id: UUID, repoName: String, workingDirectory: String, groupId: UUID? = nil, pendingPrompt: String? = nil) {
        // Log registration
        let logPath = "/tmp/promptconduit-terminal.log"
        let regMsg = "[REG] registerSession: id=\(id.uuidString.prefix(8)), repo=\(repoName), wd=\(workingDirectory), groupId=\(groupId?.uuidString.prefix(8) ?? "nil"), hasPrompt=\(pendingPrompt != nil)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(regMsg.data(using: .utf8)!)
            handle.closeFile()
        }
        print("[REG] \(regMsg)")

        var session = TerminalSessionInfo(
            id: id,
            repoName: repoName,
            workingDirectory: workingDirectory,
            isRunning: true,
            isWaiting: true,  // Default to waiting (Claude starts ready for input)
            groupId: groupId,
            launchTime: Date()  // Record launch time for JSONL session association
        )
        session.pendingPrompt = pendingPrompt

        sessions.append(session)

        let countMsg = "[REG] Session count now: \(sessions.count). All sessions: \(sessions.map { "[\($0.repoName): \($0.workingDirectory)]" })\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(countMsg.data(using: .utf8)!)
            handle.closeFile()
        }

        // Register working directory to exclude from external detection
        ProcessDetectionService.shared.registerManagedWorkingDirectory(workingDirectory)

        // Trigger a refresh of ClaudeSessionDiscovery to pick up any existing sessions
        // This helps associate the terminal with an existing Claude session if one exists
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ClaudeSessionDiscovery.shared.refreshStatuses()
        }
    }

    /// Updates the terminal view reference for a session
    func updateTerminalView(_ id: UUID, terminalView: LocalProcessTerminalView?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminalView = terminalView
    }

    /// Gets a session by ID
    func session(for id: UUID) -> TerminalSessionInfo? {
        sessions.first { $0.id == id }
    }

    // MARK: - Prompt Management (Single Source of Truth)

    /// Gets the pending prompt for a session, if any
    /// Returns nil if prompt was already sent to prevent duplicate sends
    func getPendingPrompt(for sessionId: UUID) -> String? {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        // Check promptSent to prevent duplicate sends from race conditions
        guard !session.promptSent else { return nil }
        return session.pendingPrompt
    }

    /// Gets the terminal view for a session
    func getTerminalView(for sessionId: UUID) -> LocalProcessTerminalView? {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        return session.terminalView
    }

    /// Marks that a prompt has been sent to a session
    /// Called by views after successfully sending the prompt
    func markPromptSent(_ sessionId: UUID) {
        let logPath = "/tmp/promptconduit-terminal.log"

        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        let repoName = sessions[index].repoName
        let logMsg = "[PROMPT] markPromptSent for \(repoName)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMsg.data(using: .utf8)!)
            handle.closeFile()
        }

        sessions[index].promptSent = true
        sessions[index].isReadyForPrompt = false
        sessionsReadyForPrompt.remove(sessionId)
    }

    /// Marks a session as terminated (process ended naturally)
    func markTerminated(_ id: UUID) {
        // Ignore callbacks during cleanup to prevent crashes
        guard !isCleaningUp else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let groupId = sessions[index].groupId

        sessions[index].isRunning = false
        sessions[index].isWaiting = false

        // Update SessionGroup status if this session belongs to a group
        if let groupId = groupId {
            updateSessionGroupStatus(groupId)
        }
        // Note: We keep the working directory registered until the session is removed
        // so it doesn't appear in external list while window is still open
    }

    // MARK: - Waiting State Management

    /// Updates the waiting state for a session
    func updateWaitingState(_ id: UUID, isWaiting: Bool) {
        // Log to file for debugging
        let logPath = "/tmp/promptconduit-terminal.log"
        let logMsg = "[TSM] updateWaitingState called: id=\(id.uuidString.prefix(8)), isWaiting=\(isWaiting)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMsg.data(using: .utf8)!)
            handle.closeFile()
        }

        // Ignore callbacks during cleanup to prevent crashes
        guard !isCleaningUp else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            let errMsg = "[TSM] Session not found for id: \(id.uuidString.prefix(8))\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(errMsg.data(using: .utf8)!)
                handle.closeFile()
            }
            return
        }

        let wasWaiting = sessions[index].isWaiting
        sessions[index].isWaiting = isWaiting

        // Send notification when transitioning to waiting state
        if isWaiting && !wasWaiting {
            let session = sessions[index]
            let notifyMsg = "[TSM] SENDING NOTIFICATION for \(session.repoName)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(notifyMsg.data(using: .utf8)!)
                handle.closeFile()
            }
            NotificationService.shared.notifyWaitingForInput(
                sessionId: session.id,
                repoName: session.repoName,
                groupId: session.groupId
            )
        } else if !isWaiting && wasWaiting {
            // Cancel notification when no longer waiting
            NotificationService.shared.cancelNotification(for: id)
        }

        // Update SessionGroup status if this session belongs to a group
        if let groupId = sessions[index].groupId {
            updateSessionGroupStatus(groupId)
        }

        // Notify observers of state change
        objectWillChange.send()
    }

    /// Updates the SessionGroup status based on its terminal sessions' states
    private func updateSessionGroupStatus(_ groupId: UUID) {
        let groupSessions = sessions.filter { $0.groupId == groupId }

        // Count running and waiting sessions
        let runningCount = groupSessions.filter { $0.isRunning && !$0.isWaiting }.count
        let waitingCount = groupSessions.filter { $0.isRunning && $0.isWaiting }.count

        // Log for debugging
        let logPath = "/tmp/promptconduit-terminal.log"
        let logMsg = "[TSM] updateSessionGroupStatus: groupId=\(groupId.uuidString.prefix(8)), running=\(runningCount), waiting=\(waitingCount)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMsg.data(using: .utf8)!)
            handle.closeFile()
        }

        // Update the SessionGroup in SettingsService
        SettingsService.shared.updateSessionGroup(id: groupId) { group in
            group.updateStatus(runningCount: runningCount, waitingCount: waitingCount)
        }
    }

    /// Process terminal output (no longer used for state detection - JSONL handles this)
    /// Kept for backward compatibility but does nothing
    func processOutput(_ id: UUID, text: String) {
        // State detection is now handled by JSONL monitoring
        // This method is kept for API compatibility but no longer does anything
    }

    /// Focus a session window (bring to front)
    func focusSession(_ id: UUID) {
        guard let session = session(for: id) else { return }

        // Post notification to bring the session's window to front
        NotificationCenter.default.post(
            name: .focusTerminalSession,
            object: nil,
            userInfo: ["sessionId": id, "groupId": session.groupId as Any]
        )
    }

    /// Terminates and removes a session (user closed the window)
    func terminateSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        // Set cleanup flag if not already set (for individual session termination)
        let wasCleaningUp = isCleaningUp
        if !wasCleaningUp {
            isCleaningUp = true
        }
        defer {
            if !wasCleaningUp {
                isCleaningUp = false
            }
        }

        // Capture session data before modifying array
        let session = sessions[index]

        // Cancel any pending notifications
        NotificationService.shared.cancelNotification(for: id)

        // Find and kill the process by working directory
        // SwiftTerm's terminate() is internal, so we use POSIX kill
        if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
            kill(pid, SIGTERM)
        }

        // Unregister working directory
        ProcessDetectionService.shared.unregisterManagedWorkingDirectory(session.workingDirectory)

        // Remove from sessions
        sessions.remove(at: index)
    }

    /// Removes a session without terminating (already terminated)
    func unregisterSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        sessions[index].terminalView = nil

        // Cancel any pending notifications
        NotificationService.shared.cancelNotification(for: id)

        // Unregister working directory
        ProcessDetectionService.shared.unregisterManagedWorkingDirectory(sessions[index].workingDirectory)

        sessions.remove(at: index)
    }

    /// Terminates all sessions
    func terminateAllSessions() {
        // Set cleanup flag to prevent callbacks from modifying state during cleanup
        isCleaningUp = true
        defer { isCleaningUp = false }

        // Take a snapshot of sessions to avoid issues during cleanup
        let allSessions = sessions

        // Cancel notifications
        for session in allSessions {
            NotificationService.shared.cancelNotification(for: session.id)
        }

        // Kill all processes
        for session in allSessions {
            if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
                kill(pid, SIGTERM)
            }
            ProcessDetectionService.shared.unregisterManagedWorkingDirectory(session.workingDirectory)
        }

        // Clear all sessions in one batch
        sessions.removeAll()
        sessionGroups.removeAll()
    }

    // MARK: - Process Lookup

    /// Finds the PID of a Claude process running in the specified working directory
    private func findClaudeProcessPID(workingDirectory: String) -> pid_t? {
        // Use ps to find Claude processes
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,command"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Find Claude processes
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      (trimmed.contains("/claude ") || trimmed.hasSuffix("/claude")) else { continue }

                let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let pidString = components.first,
                      let pid = pid_t(pidString) else { continue }

                // Verify this process is running in our working directory
                if getProcessWorkingDirectory(pid) == workingDirectory {
                    return pid
                }
            }
        } catch {
            // Process lookup failed
        }

        return nil
    }

    /// Gets the working directory of a process using lsof
    private func getProcessWorkingDirectory(_ pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", String(pid), "-Fn", "-a", "-d", "cwd"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return nil }

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n") && line.count > 1 {
                    return String(line.dropFirst())
                }
            }
        } catch {
            // lsof failed
        }

        return nil
    }

    // MARK: - Multi-Session Groups

    /// Creates a new session group for multiple repositories
    func createSessionGroup(repositories: [String], layout: GridLayout) -> MultiSessionGroup {
        let group = MultiSessionGroup(
            layout: layout,
            repositories: repositories
        )

        sessionGroups.append(group)

        return group
    }

    /// Gets a session group by ID
    func sessionGroup(for id: UUID) -> MultiSessionGroup? {
        sessionGroups.first { $0.id == id }
    }

    /// Terminates all sessions in a group
    func terminateGroup(_ groupId: UUID) {
        // Guard against double-cleanup - check if any sessions exist with this groupId
        // Note: We check `sessions` not `sessionGroups` because sessions launched from
        // the dashboard use SessionGroup IDs from SettingsService, not MultiSessionGroup IDs
        guard sessions.contains(where: { $0.groupId == groupId }) else {
            // Also try removing from sessionGroups in case it was created via createSessionGroup
            sessionGroups.removeAll { $0.id == groupId }
            return
        }

        // Set cleanup flag to prevent callbacks from modifying state during cleanup
        isCleaningUp = true
        defer { isCleaningUp = false }

        // Remove the group first to prevent re-entry
        sessionGroups.removeAll { $0.id == groupId }

        // Find all sessions in this group and collect their data before modifying the array
        let groupSessions = sessions.filter { $0.groupId == groupId }

        // Cancel notifications
        for session in groupSessions {
            NotificationService.shared.cancelNotification(for: session.id)
        }

        // Kill all processes
        let logPath = "/tmp/promptconduit-terminal.log"
        let logMsg = "[TSM] terminateGroup: groupId=\(groupId.uuidString.prefix(8)), killing \(groupSessions.count) sessions\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMsg.data(using: .utf8)!)
            handle.closeFile()
        }

        for session in groupSessions {
            if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
                let killMsg = "[TSM] Killing PID \(pid) for \(session.repoName) at \(session.workingDirectory)\n"
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(killMsg.data(using: .utf8)!)
                    handle.closeFile()
                }
                kill(pid, SIGTERM)
            } else {
                let noKillMsg = "[TSM] No Claude process found for \(session.repoName) at \(session.workingDirectory)\n"
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(noKillMsg.data(using: .utf8)!)
                    handle.closeFile()
                }
            }
            ProcessDetectionService.shared.unregisterManagedWorkingDirectory(session.workingDirectory)
        }

        // Remove all sessions from the array in one batch
        let idsToRemove = Set(groupSessions.map { $0.id })
        sessions.removeAll { idsToRemove.contains($0.id) }
    }

    /// Broadcast text to all sessions in a group
    func broadcastToGroup(_ groupId: UUID, text: String) {
        let groupSessions = sessions.filter { $0.groupId == groupId && $0.isRunning }

        for session in groupSessions {
            session.terminalView?.send(txt: text)
        }
    }

    /// Broadcast a key event to all sessions in a group
    func broadcastKeyEventToGroup(_ groupId: UUID, event: NSEvent) {
        let groupSessions = sessions.filter { $0.groupId == groupId && $0.isRunning }

        for session in groupSessions {
            session.terminalView?.keyDown(with: event)
        }
    }

    // MARK: - Broadcast Mode

    /// Toggles broadcast mode for a group
    /// Returns the new broadcast state
    @discardableResult
    func toggleBroadcast(for groupId: UUID) -> Bool {
        if broadcastEnabledGroups.contains(groupId) {
            broadcastEnabledGroups.remove(groupId)
            NotificationCenter.default.post(name: .broadcastModeChanged, object: nil, userInfo: ["groupId": groupId, "enabled": false])
            return false
        } else {
            broadcastEnabledGroups.insert(groupId)
            NotificationCenter.default.post(name: .broadcastModeChanged, object: nil, userInfo: ["groupId": groupId, "enabled": true])
            return true
        }
    }

    /// Checks if broadcast mode is enabled for a group
    func isBroadcastEnabled(for groupId: UUID) -> Bool {
        broadcastEnabledGroups.contains(groupId)
    }

    /// Get sessions for a specific group
    func sessions(for groupId: UUID) -> [TerminalSessionInfo] {
        sessions.filter { $0.groupId == groupId }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a terminal session should be focused
    static let focusTerminalSession = Notification.Name("focusTerminalSession")

    /// Posted when a terminal session should be highlighted (for deep linking)
    static let highlightTerminalSession = Notification.Name("highlightTerminalSession")

    /// Posted when the dashboard should navigate to a session group
    static let navigateToSessionGroup = Notification.Name("navigateToSessionGroup")

    /// Posted when the dashboard should navigate to a terminal session
    static let navigateToTerminalSession = Notification.Name("navigateToTerminalSession")

    /// Posted when broadcast mode is toggled for a session group
    static let broadcastModeChanged = Notification.Name("broadcastModeChanged")
}
