import Foundation
import Combine
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
    weak var terminalView: GhosttyTerminalView? = nil
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

    /// Track which Claude session IDs have been claimed by terminal sessions
    /// This prevents multiple terminals from matching to the same Claude session
    private var claimedClaudeSessionIds = Set<String>()

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

    // MARK: - Hybrid State Monitoring (Hooks + JSONL)

    private func setupJSONLMonitoring() {
        let logPath = "/tmp/promptconduit-terminal.log"

        func hybridLog(_ msg: String) {
            let line = "[HYBRID \(Date())] \(msg)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            }
            print("[HYBRID] \(msg)")
        }

        // === FAST PATH: Hook-based notifications ===
        // Hooks fire immediately when Claude Code events occur
        setupHookListening()

        // === AUTHORITATIVE PATH: JSONL-based state ===
        // JSONL provides accurate state including progress events

        // Subscribe to ClaudeSessionDiscovery updates
        ClaudeSessionDiscovery.shared.$repoGroups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                self?.reconcileSessionStates(from: groups)
            }
            .store(in: &cancellables)

        // Subscribe to session waiting notifications from JSONL
        ClaudeSessionDiscovery.shared.onSessionBecameWaiting = { [weak self] discoveredSession in
            hybridLog("JSONL: Session became waiting: \(discoveredSession.id) in \(discoveredSession.repoPath)")
            self?.handleSessionBecameWaiting(discoveredSession)
        }

        hybridLog("Hybrid monitoring setup complete (hooks + JSONL)")
    }

    /// Sets up hook-based event listening for fast notifications
    private func setupHookListening() {
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

        // Start the hook notification service if not already running
        HookNotificationService.shared.startListening()

        // Listen for Stop events (Claude finished responding → waiting for input)
        HookNotificationService.shared.onStop = { [weak self] event in
            hookLog("Stop event received: cwd=\(event.cwd), sessionId=\(event.sessionId ?? "nil")")
            self?.handleHookStopEvent(event)
        }

        // Listen for UserPromptSubmit events (user sent prompt → running)
        HookNotificationService.shared.onUserPromptSubmit = { [weak self] event in
            hookLog("UserPromptSubmit event received: cwd=\(event.cwd), sessionId=\(event.sessionId ?? "nil")")
            self?.handleHookUserPromptSubmitEvent(event)
        }

        hookLog("Hook listening setup complete")
    }

    /// Handles Stop event from hooks (fast path for waiting state)
    private func handleHookStopEvent(_ event: StopEvent) {
        guard !isCleaningUp else { return }

        let logPath = "/tmp/promptconduit-terminal.log"

        // Find matching session by cwd or sessionId
        guard let index = findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) else {
            let msg = "[HOOK] No matching session for Stop event at \(event.cwd)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(msg.data(using: .utf8)!)
                handle.closeFile()
            }
            return
        }

        let session = sessions[index]
        let msg = "[HOOK] Matched Stop event to session \(session.repoName) - marking waiting\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(msg.data(using: .utf8)!)
            handle.closeFile()
        }

        // Fast path: immediately mark as waiting
        updateWaitingState(session.id, isWaiting: true)

        // Also mark ready for prompt if has pending prompt
        if sessions[index].pendingPrompt != nil && !sessions[index].promptSent && !sessions[index].isReadyForPrompt {
            let readyMsg = "[HOOK] Session \(session.repoName) marked READY FOR PROMPT (via hook)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(readyMsg.data(using: .utf8)!)
                handle.closeFile()
            }
            sessions[index].isReadyForPrompt = true
            sessionsReadyForPrompt.insert(session.id)
        }
    }

    /// Handles UserPromptSubmit event from hooks (fast path for running state)
    private func handleHookUserPromptSubmitEvent(_ event: UserPromptSubmitEvent) {
        guard !isCleaningUp else { return }

        let logPath = "/tmp/promptconduit-terminal.log"

        // Find matching session by cwd or sessionId
        guard let index = findSessionIndex(cwd: event.cwd, sessionId: event.sessionId) else {
            let msg = "[HOOK] No matching session for UserPromptSubmit event at \(event.cwd)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(msg.data(using: .utf8)!)
                handle.closeFile()
            }
            return
        }

        let session = sessions[index]
        let msg = "[HOOK] Matched UserPromptSubmit to session \(session.repoName) - marking running\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(msg.data(using: .utf8)!)
            handle.closeFile()
        }

        // Fast path: immediately mark as not waiting (running)
        updateWaitingState(session.id, isWaiting: false)
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
                    // Claim this session so other terminals don't match to it
                    claimedClaudeSessionIds.insert(discovered.id)

                    let logMsg = "[JSONL] Associated terminal \(session.repoName) with Claude session \(discovered.id) (claimed)\n"
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
        // Try Claude session ID first (most reliable) - this session is already claimed
        if let claudeId = session.claudeSessionId {
            for group in groups {
                if let discovered = group.sessions.first(where: { $0.id == claudeId }) {
                    return discovered
                }
            }
        }

        // Try matching by working directory + file creation time
        for group in groups {
            let repoPath = group.id
            guard session.workingDirectory == repoPath ||
                  session.workingDirectory.hasPrefix(repoPath + "/") ||
                  repoPath.hasPrefix(session.workingDirectory + "/") else {
                continue
            }

            let matchWindow = session.launchTime.addingTimeInterval(-5)
            var candidateSessions: [(session: DiscoveredSession, creationDate: Date)] = []

            for discovered in group.sessions {
                if claimedClaudeSessionIds.contains(discovered.id) {
                    continue
                }

                if let attrs = try? FileManager.default.attributesOfItem(atPath: discovered.filePath),
                   let creationDate = attrs[.creationDate] as? Date {
                    if creationDate >= matchWindow {
                        candidateSessions.append((discovered, creationDate))
                    }
                }
            }

            if let best = candidateSessions.sorted(by: { $0.creationDate < $1.creationDate }).first {
                return best.session
            }
        }

        return nil
    }

    /// Handles when a discovered session becomes waiting
    private func handleSessionBecameWaiting(_ discoveredSession: DiscoveredSession) {
        for i in sessions.indices {
            let session = sessions[i]

            let matches = session.claudeSessionId == discoveredSession.id ||
                          session.workingDirectory == discoveredSession.repoPath ||
                          session.workingDirectory.hasPrefix(discoveredSession.repoPath + "/")

            if matches {
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
        if let sessionId = sessionId, !sessionId.isEmpty {
            if let index = sessions.firstIndex(where: { $0.claudeSessionId == sessionId }) {
                return index
            }
        }

        if let index = sessions.firstIndex(where: { $0.workingDirectory == cwd && $0.pendingPrompt != nil && !$0.promptSent }) {
            return index
        }
        if let index = sessions.firstIndex(where: { $0.workingDirectory == cwd }) {
            return index
        }

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
    func registerSession(id: UUID, repoName: String, workingDirectory: String, groupId: UUID? = nil, pendingPrompt: String? = nil) {
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
            isWaiting: true,
            groupId: groupId,
            launchTime: Date()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ClaudeSessionDiscovery.shared.refreshStatuses()
        }

        // Fallback: If session has a pending prompt and no JSONL association happens,
        // mark it as ready after a delay.
        if pendingPrompt != nil {
            let sessionIdCopy = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.markReadyIfStillPending(sessionIdCopy)
            }
        }
    }

    /// Marks a session as ready for prompt if it still has a pending prompt that hasn't been sent.
    private func markReadyIfStillPending(_ sessionId: UUID) {
        let logPath = "/tmp/promptconduit-terminal.log"

        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = sessions[index]

        guard session.pendingPrompt != nil,
              !session.promptSent,
              !session.isReadyForPrompt,
              session.terminalView != nil else {
            return
        }

        let logMsg = "[FALLBACK] Session \(session.repoName) marked READY FOR PROMPT (no JSONL association after timeout)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMsg.data(using: .utf8)!)
            handle.closeFile()
        }
        print("[FALLBACK] \(logMsg)")

        sessions[index].isReadyForPrompt = true
        sessionsReadyForPrompt.insert(sessionId)
    }

    /// Updates the terminal view reference for a session
    func updateTerminalView(_ id: UUID, terminalView: GhosttyTerminalView?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminalView = terminalView
    }

    /// Gets a session by ID
    func session(for id: UUID) -> TerminalSessionInfo? {
        sessions.first { $0.id == id }
    }

    // MARK: - Prompt Management (Single Source of Truth)

    /// Gets the pending prompt for a session, if any
    func getPendingPrompt(for sessionId: UUID) -> String? {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        guard !session.promptSent else { return nil }
        return session.pendingPrompt
    }

    /// Gets the terminal view for a session
    func getTerminalView(for sessionId: UUID) -> GhosttyTerminalView? {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        return session.terminalView
    }

    /// Marks that a prompt has been sent to a session
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
        guard !isCleaningUp else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let groupId = sessions[index].groupId

        sessions[index].isRunning = false
        sessions[index].isWaiting = false

        if let groupId = groupId {
            updateSessionGroupStatus(groupId)
        }
    }

    // MARK: - Waiting State Management

    /// Updates the waiting state for a session
    func updateWaitingState(_ id: UUID, isWaiting: Bool) {
        let logPath = "/tmp/promptconduit-terminal.log"
        let logMsg = "[TSM] updateWaitingState called: id=\(id.uuidString.prefix(8)), isWaiting=\(isWaiting)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMsg.data(using: .utf8)!)
            handle.closeFile()
        }

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
            NotificationService.shared.cancelNotification(for: id)
        }

        if let groupId = sessions[index].groupId {
            updateSessionGroupStatus(groupId)
        }

        objectWillChange.send()
    }

    /// Updates the SessionGroup status based on its terminal sessions' states
    private func updateSessionGroupStatus(_ groupId: UUID) {
        let groupSessions = sessions.filter { $0.groupId == groupId }

        let runningCount = groupSessions.filter { $0.isRunning && !$0.isWaiting }.count
        let waitingCount = groupSessions.filter { $0.isRunning && $0.isWaiting }.count

        let logPath = "/tmp/promptconduit-terminal.log"
        let logMsg = "[TSM] updateSessionGroupStatus: groupId=\(groupId.uuidString.prefix(8)), running=\(runningCount), waiting=\(waitingCount)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMsg.data(using: .utf8)!)
            handle.closeFile()
        }

        SettingsService.shared.updateSessionGroup(id: groupId) { group in
            group.updateStatus(runningCount: runningCount, waitingCount: waitingCount)
        }
    }

    /// Process terminal output (no longer used for state detection - JSONL handles this)
    /// Kept for backward compatibility but does nothing
    func processOutput(_ id: UUID, text: String) {
        // State detection is now handled by JSONL monitoring
    }

    /// Focus a session window (bring to front)
    func focusSession(_ id: UUID) {
        guard let session = session(for: id) else { return }

        NotificationCenter.default.post(
            name: .focusTerminalSession,
            object: nil,
            userInfo: ["sessionId": id, "groupId": session.groupId as Any]
        )
    }

    /// Terminates and removes a session (user closed the window)
    func terminateSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let wasCleaningUp = isCleaningUp
        if !wasCleaningUp {
            isCleaningUp = true
        }
        defer {
            if !wasCleaningUp {
                isCleaningUp = false
            }
        }

        let session = sessions[index]

        if let claudeId = session.claudeSessionId {
            claimedClaudeSessionIds.remove(claudeId)
        }

        NotificationService.shared.cancelNotification(for: id)

        if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
            kill(pid, SIGTERM)
        }

        ProcessDetectionService.shared.unregisterManagedWorkingDirectory(session.workingDirectory)

        sessions.remove(at: index)
    }

    /// Removes a session without terminating (already terminated)
    func unregisterSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        if let claudeId = sessions[index].claudeSessionId {
            claimedClaudeSessionIds.remove(claudeId)
        }

        sessions[index].terminalView = nil

        NotificationService.shared.cancelNotification(for: id)

        ProcessDetectionService.shared.unregisterManagedWorkingDirectory(sessions[index].workingDirectory)

        sessions.remove(at: index)
    }

    /// Terminates all sessions
    func terminateAllSessions() {
        isCleaningUp = true
        defer { isCleaningUp = false }

        let allSessions = sessions

        for session in allSessions {
            NotificationService.shared.cancelNotification(for: session.id)
        }

        for session in allSessions {
            if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
                kill(pid, SIGTERM)
            }
            ProcessDetectionService.shared.unregisterManagedWorkingDirectory(session.workingDirectory)
        }

        sessions.removeAll()
        sessionGroups.removeAll()
        claimedClaudeSessionIds.removeAll()
    }

    // MARK: - Process Lookup

    /// Finds the PID of a Claude process running in the specified working directory
    private func findClaudeProcessPID(workingDirectory: String) -> pid_t? {
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

            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      (trimmed.contains("/claude ") || trimmed.hasSuffix("/claude")) else { continue }

                let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let pidString = components.first,
                      let pid = pid_t(pidString) else { continue }

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
        guard sessions.contains(where: { $0.groupId == groupId }) else {
            sessionGroups.removeAll { $0.id == groupId }
            return
        }

        isCleaningUp = true
        defer { isCleaningUp = false }

        sessionGroups.removeAll { $0.id == groupId }

        let groupSessions = sessions.filter { $0.groupId == groupId }

        for session in groupSessions {
            NotificationService.shared.cancelNotification(for: session.id)
        }

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

        let idsToRemove = Set(groupSessions.map { $0.id })
        sessions.removeAll { idsToRemove.contains($0.id) }
    }

    /// Broadcast text to all sessions in a group
    func broadcastToGroup(_ groupId: UUID, text: String) {
        let groupSessions = sessions.filter { $0.groupId == groupId && $0.isRunning }

        for session in groupSessions {
            session.terminalView?.sendText(text)
        }
    }

    /// Broadcast a key event to all sessions in a group
    func broadcastKeyEventToGroup(_ groupId: UUID, event: NSEvent) {
        let groupSessions = sessions.filter { $0.groupId == groupId && $0.isRunning }

        for session in groupSessions {
            session.terminalView?.forwardKeyEvent(event)
        }
    }

    // MARK: - Broadcast Mode

    /// Toggles broadcast mode for a group
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
