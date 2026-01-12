import Foundation
import Combine
import SwiftTerm

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
}

/// Manages terminal sessions launched from PromptConduit
/// Separate from AgentManager which handles PTY-based print-mode sessions
class TerminalSessionManager: ObservableObject {
    static let shared = TerminalSessionManager()

    @Published private(set) var sessions: [TerminalSessionInfo] = []
    @Published private(set) var sessionGroups: [MultiSessionGroup] = []

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

        // Session started → associate Claude session ID, mark as hook-managed, and set waiting
        hookService.onSessionStart = { [weak self] event in
            self?.associateClaudeSession(cwd: event.cwd, claudeSessionId: event.sessionId)
            if let index = self?.findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) {
                // Mark session as hook-managed - output parsing will no longer change state
                self?.sessions[index].outputMonitor?.setHookManaged()
                // Force set waiting state (hooks are authoritative)
                self?.sessions[index].outputMonitor?.forceSetWaiting(true)
            }
        }

        // User submitted prompt → running
        hookService.onUserPromptSubmit = { [weak self] event in
            if let index = self?.findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) {
                // Mark as hook-managed on any hook event (handles race condition where
                // SessionStart fires before session is registered)
                self?.sessions[index].outputMonitor?.setHookManaged()
                // Clear the buffer to prevent old prompt patterns from persisting
                self?.sessions[index].outputMonitor?.clearBuffer()
                // Force set running state (hooks are authoritative)
                self?.sessions[index].outputMonitor?.forceSetWaiting(false)
            }
        }

        // Claude stopped → waiting
        hookService.onStop = { [weak self] event in
            if let index = self?.findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) {
                // Mark as hook-managed on any hook event (handles race condition where
                // SessionStart fires before session is registered)
                self?.sessions[index].outputMonitor?.setHookManaged()
                // Force set waiting state (hooks are authoritative)
                self?.sessions[index].outputMonitor?.forceSetWaiting(true)
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
        // Try Claude session ID first (most reliable)
        if let sessionId = sessionId,
           let index = sessions.firstIndex(where: { $0.claudeSessionId == sessionId }) {
            return index
        }

        // Try exact cwd match
        if let index = sessions.firstIndex(where: { $0.workingDirectory == cwd }) {
            return index
        }

        // Fallback: match by directory name (handles path differences)
        let eventDirName = URL(fileURLWithPath: cwd).lastPathComponent
        return sessions.firstIndex(where: {
            URL(fileURLWithPath: $0.workingDirectory).lastPathComponent == eventDirName
        })
    }

    /// Update session state using flexible matching
    private func updateSessionState(cwd: String, sessionId: String?, isWaiting: Bool) {
        guard let index = findSessionIndex(cwd: cwd, sessionId: sessionId) else { return }
        updateWaitingState(sessions[index].id, isWaiting: isWaiting)
    }

    // MARK: - Session Management

    /// Registers a new terminal session
    func registerSession(id: UUID, repoName: String, workingDirectory: String, groupId: UUID? = nil) {
        // Create output monitor for waiting state detection
        let monitor = TerminalOutputMonitor()

        let session = TerminalSessionInfo(
            id: id,
            repoName: repoName,
            workingDirectory: workingDirectory,
            isRunning: true,
            isWaiting: true,  // Default to waiting (Claude starts ready for input)
            groupId: groupId,
            outputMonitor: monitor
        )

        // Setup monitoring callback
        monitor.onWaitingStateChanged = { [weak self] isWaiting in
            self?.updateWaitingState(id, isWaiting: isWaiting)
        }

        sessions.append(session)

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

    /// Marks a session as terminated (process ended naturally)
    func markTerminated(_ id: UUID) {
        // Ignore callbacks during cleanup to prevent crashes
        guard !isCleaningUp else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isRunning = false
        sessions[index].isWaiting = false
        sessions[index].outputMonitor?.stopMonitoring()
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

        // Notify observers of state change
        objectWillChange.send()
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
        // Guard against double-cleanup - check if group still exists
        guard sessionGroups.contains(where: { $0.id == groupId }) else {
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
        for session in groupSessions {
            if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
                kill(pid, SIGTERM)
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

    /// Get sessions for a specific group
    func sessions(for groupId: UUID) -> [TerminalSessionInfo] {
        sessions.filter { $0.groupId == groupId }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a terminal session should be focused
    static let focusTerminalSession = Notification.Name("focusTerminalSession")
}
