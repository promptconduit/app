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

    // Deep link highlight state
    @State private var highlightedSessionId: UUID?
    @State private var highlightOpacity: Double = 0

    /// Grid dimensions based on layout and repo count
    private var dimensions: (rows: Int, cols: Int) {
        layout.dimensions(for: repositories.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal grid (header removed - redundant with group header)
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
            // Clean up all sessions in this group when the view disappears
            terminalManager.terminateGroup(groupId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTerminalSession)) { notification in
            handleFocusNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightTerminalSession)) { notification in
            handleHighlightNotification(notification)
        }
    }

    private func handleHighlightNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let targetGroupId = userInfo["groupId"] as? UUID,
              targetGroupId == groupId,
              let sessionId = userInfo["sessionId"] as? UUID else {
            return
        }

        highlightSession(sessionId)
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

        // Check if we should highlight
        if let shouldHighlight = userInfo["highlight"] as? Bool, shouldHighlight {
            highlightSession(sessionId)
        }
    }

    // MARK: - Deep Link Highlighting

    /// Highlights a session with an orange glow that fades after 3 seconds
    func highlightSession(_ sessionId: UUID) {
        highlightedSessionId = sessionId
        withAnimation(.easeIn(duration: 0.3)) {
            highlightOpacity = 1.0
        }

        // Fade after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeOut(duration: 0.5)) {
                highlightOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                highlightedSessionId = nil
            }
        }
    }

    /// Check if a specific session is highlighted
    func isSessionHighlighted(_ sessionId: UUID) -> Bool {
        highlightedSessionId == sessionId && highlightOpacity > 0
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
