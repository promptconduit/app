import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Design Tokens

private enum GridTokens {
    static let backgroundPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let backgroundHeader = Color(red: 0.08, green: 0.11, blue: 0.18)
    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.58, green: 0.63, blue: 0.73)
    static let accentCyan = Color(red: 0.0, green: 0.83, blue: 0.67)
    static let gridSpacing: CGFloat = 2
}

/// A grid view containing multiple terminal sessions
struct MultiTerminalGridView: View {
    let groupId: UUID
    let repositories: [String]
    let layout: GridLayout
    let initialPrompt: String?
    let onClose: () -> Void

    @ObservedObject private var terminalManager = TerminalSessionManager.shared
    @ObservedObject private var hookService = HookNotificationService.shared
    @State private var focusedSessionId: UUID?
    @State private var sessionIds: [UUID] = []
    @State private var terminalViews: [UUID: LocalProcessTerminalView] = [:]
    @State private var promptSentToSessions: Set<UUID> = []  // Track which sessions received the prompt
    @State private var repoPathToSessionId: [String: UUID] = [:]  // Map working directory to session ID

    /// Grid dimensions based on layout and repo count
    private var dimensions: (rows: Int, cols: Int) {
        layout.dimensions(for: repositories.count)
    }

    /// Sessions in this group
    private var groupSessions: [TerminalSessionInfo] {
        terminalManager.sessions(for: groupId)
    }

    /// Count of waiting sessions
    private var waitingCount: Int {
        groupSessions.filter { $0.isWaiting }.count
    }

    /// Count of running sessions
    private var runningCount: Int {
        groupSessions.filter { $0.isRunning }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            gridHeader

            Divider()
                .background(Color.gray.opacity(0.3))

            // Terminal grid
            GeometryReader { geometry in
                let cellWidth = (geometry.size.width - GridTokens.gridSpacing * CGFloat(dimensions.cols - 1)) / CGFloat(dimensions.cols)
                let cellHeight = (geometry.size.height - GridTokens.gridSpacing * CGFloat(dimensions.rows - 1)) / CGFloat(dimensions.rows)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: GridTokens.gridSpacing), count: dimensions.cols),
                    spacing: GridTokens.gridSpacing
                ) {
                    ForEach(Array(zip(sessionIds.indices, sessionIds)), id: \.1) { index, sessionId in
                        if index < repositories.count {
                            let repoPath = repositories[index]
                            let repoName = URL(fileURLWithPath: repoPath).lastPathComponent

                            TerminalCellView(
                                sessionId: sessionId,
                                repoName: repoName,
                                workingDirectory: repoPath,
                                isFocused: focusedSessionId == sessionId,
                                onFocus: {
                                    focusedSessionId = sessionId
                                    focusTerminal(sessionId)
                                },
                                onTerminated: {
                                    terminalManager.markTerminated(sessionId)
                                },
                                onTerminalReady: { terminal in
                                    terminalViews[sessionId] = terminal
                                    terminalManager.updateTerminalView(sessionId, terminalView: terminal)
                                },
                                onClaudeReady: {
                                    // Claude has shown its prompt - now safe to send initial prompt
                                    print("[MultiTerminalGrid] onClaudeReady fired for session \(sessionId)")
                                    print("[MultiTerminalGrid] terminalViews has \(terminalViews.count) entries")
                                    if let terminal = terminalViews[sessionId] {
                                        print("[MultiTerminalGrid] Found terminal view, sending prompt")
                                        sendInitialPromptIfNeeded(to: sessionId, terminal: terminal)
                                    } else {
                                        print("[MultiTerminalGrid] ERROR: Terminal view not found for session!")
                                        // Fallback: wait a bit and try again
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            if let terminal = terminalViews[sessionId] {
                                                print("[MultiTerminalGrid] Fallback: Found terminal view after delay")
                                                sendInitialPromptIfNeeded(to: sessionId, terminal: terminal)
                                            }
                                        }
                                    }
                                }
                            )
                            .frame(width: cellWidth, height: cellHeight)
                        }
                    }
                }
            }
        }
        .background(GridTokens.backgroundPrimary)
        .onAppear {
            setupSessions()
            setupHookListener()
        }
        .onDisappear {
            hookService.onSessionStart = nil  // Clean up callback
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTerminalSession)) { notification in
            handleFocusNotification(notification)
        }
    }

    // MARK: - Header

    private var gridHeader: some View {
        HStack(spacing: 16) {
            // Title and status
            VStack(alignment: .leading, spacing: 2) {
                Text("Multi-Session")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(GridTokens.textPrimary)

                HStack(spacing: 12) {
                    // Running count
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("\(runningCount) running")
                            .font(.system(size: 11))
                            .foregroundColor(GridTokens.textSecondary)
                    }

                    // Waiting count (if any)
                    if waitingCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 6, height: 6)
                            Text("\(waitingCount) waiting")
                                .font(.system(size: 11))
                                .foregroundColor(Color.yellow)
                        }
                    }
                }
            }

            Spacer()

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(GridTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Close all terminals")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(GridTokens.backgroundHeader)
    }

    // MARK: - Session Management

    private func setupSessions() {
        // Create sessions for each repository
        for repoPath in repositories {
            let sessionId = UUID()
            let repoName = URL(fileURLWithPath: repoPath).lastPathComponent

            // Register with terminal manager
            terminalManager.registerSession(
                id: sessionId,
                repoName: repoName,
                workingDirectory: repoPath,
                groupId: groupId
            )

            sessionIds.append(sessionId)

            // Map repo path to session ID for hook matching
            repoPathToSessionId[repoPath] = sessionId
        }

        // Focus the first session
        if let first = sessionIds.first {
            focusedSessionId = first
        }
    }

    /// Set up listener for CLI hook events
    private func setupHookListener() {
        print("[MultiTerminalGrid] setupHookListener called")
        print("[MultiTerminalGrid] repoPathToSessionId: \(repoPathToSessionId)")

        // Start the hook service if not already running
        hookService.startListening()

        // Listen for SessionStart events
        hookService.onSessionStart = { [self] event in
            print("[MultiTerminalGrid] Received SessionStart hook for: \(event.cwd)")
            print("[MultiTerminalGrid] repoPathToSessionId keys: \(Array(repoPathToSessionId.keys))")
            print("[MultiTerminalGrid] terminalViews count: \(terminalViews.count)")

            // Find the session ID for this working directory
            if let sessionId = repoPathToSessionId[event.cwd],
               let terminal = terminalViews[sessionId] {
                print("[MultiTerminalGrid] Found exact match, sending prompt")
                sendInitialPromptIfNeeded(to: sessionId, terminal: terminal)
            } else {
                print("[MultiTerminalGrid] No exact match, trying suffix match...")
                // Try matching by suffix (in case paths differ slightly)
                var matched = false
                for (path, sessionId) in repoPathToSessionId {
                    let eventDirName = URL(fileURLWithPath: event.cwd).lastPathComponent
                    let pathDirName = URL(fileURLWithPath: path).lastPathComponent
                    print("[MultiTerminalGrid] Comparing: event='\(eventDirName)' vs path='\(pathDirName)'")

                    if eventDirName == pathDirName {
                        print("[MultiTerminalGrid] Directory name match found!")
                        if let terminal = terminalViews[sessionId] {
                            print("[MultiTerminalGrid] Terminal found, sending prompt")
                            sendInitialPromptIfNeeded(to: sessionId, terminal: terminal)
                            matched = true
                        } else {
                            print("[MultiTerminalGrid] Terminal NOT found for sessionId: \(sessionId)")
                        }
                        break
                    }
                }
                if !matched {
                    print("[MultiTerminalGrid] No match found for path: \(event.cwd)")
                }
            }
        }
    }

    private func focusTerminal(_ sessionId: UUID) {
        // Make the terminal the first responder
        if let terminal = terminalViews[sessionId] {
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    private func handleFocusNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let targetGroupId = userInfo["groupId"] as? UUID,
              targetGroupId == groupId,
              let sessionId = userInfo["sessionId"] as? UUID else {
            return
        }

        focusedSessionId = sessionId
        focusTerminal(sessionId)
    }

    /// Sends the initial prompt to a terminal if one was provided and hasn't been sent yet
    /// Called when Claude is ready (has shown its prompt)
    private func sendInitialPromptIfNeeded(to sessionId: UUID, terminal: LocalProcessTerminalView) {
        print("[MultiTerminalGrid] sendInitialPromptIfNeeded called for session \(sessionId)")
        print("[MultiTerminalGrid] initialPrompt: \(initialPrompt ?? "nil")")

        guard let prompt = initialPrompt, !prompt.isEmpty else {
            print("[MultiTerminalGrid] No prompt to send (nil or empty)")
            return
        }
        guard !promptSentToSessions.contains(sessionId) else {
            print("[MultiTerminalGrid] Prompt already sent to this session")
            return
        }

        // Mark as sent first to avoid double-sending
        promptSentToSessions.insert(sessionId)
        print("[MultiTerminalGrid] Sending prompt: \(prompt.prefix(50))...")

        // Trim whitespace/newlines from prompt before sending
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            print("[MultiTerminalGrid] Prompt is empty after trimming, skipping")
            return
        }

        // Small delay to ensure Claude is fully ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("[MultiTerminalGrid] Sending trimmed prompt: '\(trimmedPrompt)'")
            terminal.send(txt: trimmedPrompt)

            // Simulate actual Enter key press using NSEvent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                print("[MultiTerminalGrid] Simulating Enter key press")
                if let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: terminal.window?.windowNumber ?? 0,
                    context: nil,
                    characters: "\r",
                    charactersIgnoringModifiers: "\r",
                    isARepeat: false,
                    keyCode: 36  // Enter key code
                ) {
                    terminal.keyDown(with: event)
                    print("[MultiTerminalGrid] Enter key event sent")
                } else {
                    print("[MultiTerminalGrid] Failed to create Enter key event, falling back to byte send")
                    terminal.send([13])
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MultiTerminalGridView(
        groupId: UUID(),
        repositories: [
            "/Users/test/project1",
            "/Users/test/project2",
            "/Users/test/project3",
            "/Users/test/project4"
        ],
        layout: .auto,
        initialPrompt: nil,
        onClose: {}
    )
    .frame(width: 1200, height: 800)
}
