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
    @State private var focusedSessionId: UUID?
    @State private var sessionIds: [UUID] = []

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
                                    // Store terminal view in the single source of truth
                                    terminalManager.updateTerminalView(sessionId, terminalView: terminal)
                                },
                                onClaudeReady: nil  // Prompt sending is now triggered by hook events via state observation
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
            // Ensure hook service is listening (TerminalSessionManager handles the events)
            HookNotificationService.shared.startListening()
        }
        .onDisappear {
            // Clean up all sessions in this group when the view disappears
            terminalManager.terminateGroup(groupId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTerminalSession)) { notification in
            handleFocusNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightTerminalSession)) { notification in
            handleHighlightNotification(notification)
        }
        // SINGLE SOURCE OF TRUTH: Observe sessions ready for prompt from the manager
        .onReceive(terminalManager.$sessionsReadyForPrompt) { readySessions in
            // Filter to only sessions in this group
            let ourReadySessions = readySessions.filter { sessionIds.contains($0) }
            for sessionId in ourReadySessions {
                sendPromptToSession(sessionId)
            }
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

            // Register with terminal manager (single source of truth)
            // Include the pending prompt so the manager knows what to send when ready
            terminalManager.registerSession(
                id: sessionId,
                repoName: repoName,
                workingDirectory: repoPath,
                groupId: groupId,
                pendingPrompt: initialPrompt
            )

            sessionIds.append(sessionId)
        }

        // Focus the first session
        if let first = sessionIds.first {
            focusedSessionId = first
        }
    }

    private func focusTerminal(_ sessionId: UUID) {
        // Make the terminal the first responder (get terminal from manager)
        if let terminal = terminalManager.getTerminalView(for: sessionId) {
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

    // MARK: - Prompt Sending (Triggered by State Change)

    /// Sends a prompt to a session when the manager marks it as ready
    /// Uses the single source of truth (TerminalSessionManager) for all data
    private func sendPromptToSession(_ sessionId: UUID) {
        print("[MultiTerminalGrid] sendPromptToSession called for session \(sessionId)")

        // Get prompt and terminal from the single source of truth
        guard let prompt = terminalManager.getPendingPrompt(for: sessionId) else {
            print("[MultiTerminalGrid] No pending prompt for session")
            return
        }
        guard let terminal = terminalManager.getTerminalView(for: sessionId) else {
            print("[MultiTerminalGrid] No terminal view for session - will retry on next state update")
            return
        }

        // Trim whitespace/newlines from prompt before sending
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            print("[MultiTerminalGrid] Prompt is empty after trimming, skipping")
            terminalManager.markPromptSent(sessionId)
            return
        }

        print("[MultiTerminalGrid] Sending prompt: \(trimmedPrompt.prefix(50))...")

        // Mark as sent BEFORE sending to prevent re-entry from state updates
        terminalManager.markPromptSent(sessionId)

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
