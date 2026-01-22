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
    var outputMonitor: TerminalOutputMonitor? = nil

    // MARK: - Prompt Management (Single Source of Truth)
    var pendingPrompt: String? = nil  // Prompt to send when session becomes ready
    var isReadyForPrompt: Bool = false  // Set true when SessionStart hook fires
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

    /// Number of sessions waiting for input
    var waitingCount: Int {
        sessions.filter { $0.isWaiting }.count
    }

    /// Number of running sessions
    var runningCount: Int {
        sessions.filter { $0.isRunning }.count
    }

    private init() {
        setupHookListening()
    }

    // MARK: - Hook Event Listening

    private func setupHookListening() {
        let hookService = HookNotificationService.shared
        let logPath = "/tmp/promptconduit-terminal.log"

        func hookLog(_ msg: String) {
            let line = "[HOOK \(Date())] \(msg)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            }
            print("[HOOK] \(msg)")
        }

        // Session started → associate Claude session ID, mark as hook-assisted, set waiting, and mark ready for prompt
        hookService.onSessionStart = { [weak self] event in
            hookLog("onSessionStart: cwd=\(event.cwd), sessionId=\(event.sessionId ?? "nil")")
            hookLog("  Available sessions: \(self?.sessions.map { "[\($0.repoName): wd=\($0.workingDirectory), isWaiting=\($0.isWaiting), hasPendingPrompt=\($0.pendingPrompt != nil)]" } ?? [])")

            self?.associateClaudeSession(cwd: event.cwd, claudeSessionId: event.sessionId)
            if let index = self?.findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) {
                let sessionId = self?.sessions[index].id
                let repoName = self?.sessions[index].repoName ?? "?"
                let hasPendingPrompt = self?.sessions[index].pendingPrompt != nil
                let promptAlreadySent = self?.sessions[index].promptSent ?? false

                hookLog("  MATCHED session index \(index): \(repoName) - setting isWaiting=TRUE, hasPendingPrompt=\(hasPendingPrompt)")

                // Force set waiting state (hooks are authoritative)
                // This also marks the session as hook-assisted
                self?.sessions[index].outputMonitor?.forceSetWaiting(true)

                // Mark session as ready for prompt if it has a pending prompt that hasn't been sent
                if hasPendingPrompt && !promptAlreadySent, let sessionId = sessionId {
                    hookLog("  Session \(repoName) marked READY FOR PROMPT")
                    self?.sessions[index].isReadyForPrompt = true
                    self?.sessionsReadyForPrompt.insert(sessionId)
                }
            } else {
                hookLog("  NO MATCH found for cwd")
            }
        }

        // User submitted prompt → running
        hookService.onUserPromptSubmit = { [weak self] event in
            hookLog("onUserPromptSubmit: cwd=\(event.cwd), sessionId=\(event.sessionId ?? "nil")")
            hookLog("  Available sessions: \(self?.sessions.map { "[\($0.repoName): wd=\($0.workingDirectory), isWaiting=\($0.isWaiting)]" } ?? [])")

            if let index = self?.findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) {
                hookLog("  MATCHED session index \(index): \(self?.sessions[index].repoName ?? "?") - setting isWaiting=FALSE (Running)")
                // Clear the buffer to prevent old prompt patterns from persisting
                self?.sessions[index].outputMonitor?.clearBuffer()
                // Force set running state (hooks are authoritative)
                // This also marks the session as hook-assisted
                self?.sessions[index].outputMonitor?.forceSetWaiting(false)
            } else {
                hookLog("  NO MATCH found for cwd")
            }
        }

        // Claude stopped → waiting
        hookService.onStop = { [weak self] event in
            hookLog("onStop: cwd=\(event.cwd), sessionId=\(event.sessionId ?? "nil")")
            hookLog("  Available sessions: \(self?.sessions.map { "[\($0.repoName): wd=\($0.workingDirectory), isWaiting=\($0.isWaiting)]" } ?? [])")

            if let index = self?.findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) {
                hookLog("  MATCHED session index \(index): \(self?.sessions[index].repoName ?? "?") - setting isWaiting=TRUE (Waiting)")
                // Force set waiting state (hooks are authoritative)
                // This also marks the session as hook-assisted
                self?.sessions[index].outputMonitor?.forceSetWaiting(true)
            } else {
                hookLog("  NO MATCH found for cwd")
            }
        }
    }

    /// Associates Claude's session ID with our app session
    private func associateClaudeSession(cwd: String, claudeSessionId: String?) {
        guard let claudeSessionId = claudeSessionId else { return }
        guard let index = findSessionIndex(cwd: cwd, sessionId: nil) else { return }
        sessions[index].claudeSessionId = claudeSessionId
    }

    /// Finds session by Claude session ID first, then by cwd/directory name
    private func findSessionIndex(cwd: String, sessionId: String?) -> Int? {
        let logPath = "/tmp/promptconduit-terminal.log"
        func findLog(_ msg: String) {
            let line = "[FIND \(Date())] \(msg)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            }
        }

        findLog("findSessionIndex: cwd=\(cwd), sessionId=\(sessionId ?? "nil")")
        findLog("  sessions count: \(sessions.count)")

        // Try Claude session ID first (most reliable)
        // Only match if sessionId is non-empty (empty strings would match all empty claudeSessionIds)
        if let sessionId = sessionId, !sessionId.isEmpty {
            findLog("  Trying Claude sessionId match...")
            for (i, session) in sessions.enumerated() {
                findLog("    [\(i)] \(session.repoName): claudeSessionId=\(session.claudeSessionId ?? "nil")")
            }
            if let index = sessions.firstIndex(where: { $0.claudeSessionId == sessionId }) {
                findLog("  MATCHED by claudeSessionId at index \(index): \(sessions[index].repoName)")
                return index
            }
        }

        // Try exact cwd match - prefer sessions with pending prompts (newer sessions)
        findLog("  Trying exact cwd match (prefer sessions with pending prompt)...")
        for (i, session) in sessions.enumerated() {
            let hasPending = session.pendingPrompt != nil && !session.promptSent
            findLog("    [\(i)] \(session.repoName): wd=\(session.workingDirectory) vs cwd=\(cwd) → match=\(session.workingDirectory == cwd), hasPendingPrompt=\(hasPending)")
        }
        // First try to find session with pending prompt (newly created session)
        if let index = sessions.firstIndex(where: { $0.workingDirectory == cwd && $0.pendingPrompt != nil && !$0.promptSent }) {
            findLog("  MATCHED by exact cwd WITH pending prompt at index \(index): \(sessions[index].repoName)")
            return index
        }
        // Fall back to any session with matching cwd
        if let index = sessions.firstIndex(where: { $0.workingDirectory == cwd }) {
            findLog("  MATCHED by exact cwd at index \(index): \(sessions[index].repoName)")
            return index
        }

        // Try prefix match: hook cwd might be a subdirectory of the repo
        // e.g., session launched for /repo/app but Claude runs in /repo/app/macOS
        findLog("  Trying prefix match (cwd is subdirectory of repo, prefer pending prompt)...")
        for (i, session) in sessions.enumerated() {
            let repoPath = session.workingDirectory
            let isSubdir = cwd.hasPrefix(repoPath + "/") || cwd == repoPath
            let hasPending = session.pendingPrompt != nil && !session.promptSent
            findLog("    [\(i)] \(session.repoName): cwd.hasPrefix(\(repoPath)/) → \(isSubdir), hasPendingPrompt=\(hasPending)")
        }
        // First try to find session with pending prompt
        if let index = sessions.firstIndex(where: { cwd.hasPrefix($0.workingDirectory + "/") && $0.pendingPrompt != nil && !$0.promptSent }) {
            findLog("  MATCHED by prefix WITH pending prompt at index \(index): \(sessions[index].repoName)")
            return index
        }
        // Fall back to any session with matching prefix
        if let index = sessions.firstIndex(where: { cwd.hasPrefix($0.workingDirectory + "/") }) {
            findLog("  MATCHED by prefix (subdirectory) at index \(index): \(sessions[index].repoName)")
            return index
        }

        findLog("  NO MATCH FOUND")
        return nil
    }

    /// Update session state using flexible matching
    private func updateSessionState(cwd: String, sessionId: String?, isWaiting: Bool) {
        guard let index = findSessionIndex(cwd: cwd, sessionId: sessionId) else { return }
        updateWaitingState(sessions[index].id, isWaiting: isWaiting)
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

        // Create output monitor for waiting state detection
        let monitor = TerminalOutputMonitor()

        var session = TerminalSessionInfo(
            id: id,
            repoName: repoName,
            workingDirectory: workingDirectory,
            isRunning: true,
            isWaiting: true,  // Default to waiting (Claude starts ready for input)
            groupId: groupId,
            outputMonitor: monitor
        )
        session.pendingPrompt = pendingPrompt

        // Setup monitoring callback
        monitor.onWaitingStateChanged = { [weak self] isWaiting in
            let cbMsg = "[CALLBACK] onWaitingStateChanged for \(repoName): isWaiting=\(isWaiting)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(cbMsg.data(using: .utf8)!)
                handle.closeFile()
            }
            print("[CALLBACK] \(cbMsg)")
            self?.updateWaitingState(id, isWaiting: isWaiting)
        }

        // NOTE: We no longer auto-set hookManaged for sessions with groupId.
        // The hybrid approach allows output parsing to work as a fallback,
        // while hooks take priority when they fire. This works whether or
        // not hooks are installed.

        sessions.append(session)

        let countMsg = "[REG] Session count now: \(sessions.count). All sessions: \(sessions.map { "[\($0.repoName): \($0.workingDirectory)]" })\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(countMsg.data(using: .utf8)!)
            handle.closeFile()
        }

        // Register working directory to exclude from external detection
        ProcessDetectionService.shared.registerManagedWorkingDirectory(workingDirectory)
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
        sessions[index].outputMonitor?.stopMonitoring()

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

    /// Process terminal output for waiting state detection
    func processOutput(_ id: UUID, text: String) {
        // Log to file for debugging
        let logPath = "/tmp/promptconduit-terminal.log"
        let logMessage = "[TerminalSessionManager] processOutput called for session \(id.uuidString.prefix(8))\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMessage.data(using: .utf8)!)
            handle.closeFile()
        }

        // Ignore callbacks during cleanup to prevent crashes
        guard !isCleaningUp else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            print("[TerminalSessionManager] processOutput: session \(id) not found")
            return
        }

        // Debug: Log output processing
        let cleanText = text.replacingOccurrences(of: "\n", with: "\\n").prefix(100)
        print("[TerminalSessionManager] processOutput for \(sessions[index].repoName): '\(cleanText)'")

        sessions[index].outputMonitor?.processOutput(text)
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

        // Stop monitoring first to prevent callbacks during cleanup
        session.outputMonitor?.stopMonitoring()
        session.outputMonitor?.onWaitingStateChanged = nil

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

        // Stop monitoring first to prevent callbacks during cleanup
        sessions[index].outputMonitor?.stopMonitoring()
        sessions[index].outputMonitor?.onWaitingStateChanged = nil
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

        // Stop monitoring first to prevent callbacks during cleanup
        for session in allSessions {
            session.outputMonitor?.stopMonitoring()
            session.outputMonitor?.onWaitingStateChanged = nil
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

        // First, stop all monitors and clear callbacks to prevent async issues
        for session in groupSessions {
            session.outputMonitor?.stopMonitoring()
            session.outputMonitor?.onWaitingStateChanged = nil
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
