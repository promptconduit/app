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
    static let accentOrange = Color(red: 1.0, green: 0.6, blue: 0.2)
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
    @State private var isInitializing = true

    // Broadcast mode state
    @State private var isBroadcastEnabled = false

    // Deep link highlight state
    @State private var highlightedSessionId: UUID?
    @State private var highlightOpacity: Double = 0

    /// Grid dimensions based on layout and repo count
    private var dimensions: (rows: Int, cols: Int) {
        layout.dimensions(for: repositories.count)
    }

    /// Count of sessions that have a terminal view registered (meaning they've started rendering)
    private var readySessionCount: Int {
        sessionIds.filter { terminalManager.getTerminalView(for: $0) != nil }.count
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Broadcast header bar
                broadcastHeaderBar

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
                                    isBroadcastEnabled: isBroadcastEnabled,
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
                                        // Check if all terminals are ready
                                        if readySessionCount >= repositories.count {
                                            withAnimation(.easeOut(duration: 0.3)) {
                                                isInitializing = false
                                            }
                                        }
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

            // Loading overlay
            if isInitializing {
                loadingOverlay
            }
        }
        .onAppear {
            setupSessions()
            // Ensure hook service is listening (TerminalSessionManager handles the events)
            HookNotificationService.shared.startListening()
            // Sync broadcast state in case it was already enabled
            isBroadcastEnabled = terminalManager.isBroadcastEnabled(for: groupId)

            // Fallback: dismiss loading overlay after 10 seconds even if terminals haven't all reported ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if isInitializing {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isInitializing = false
                    }
                }
            }
        }
        // NOTE: We do NOT terminate sessions on onDisappear because the user may be
        // switching between groups in the dashboard. Sessions should only be terminated
        // when the user explicitly clicks "Close" (via onClose callback) or when the
        // dashboard window itself is closed.
        .onReceive(NotificationCenter.default.publisher(for: .focusTerminalSession)) { notification in
            handleFocusNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .highlightTerminalSession)) { notification in
            handleHighlightNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .broadcastModeChanged)) { notification in
            handleBroadcastModeNotification(notification)
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

    private func handleBroadcastModeNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let targetGroupId = userInfo["groupId"] as? UUID,
              targetGroupId == groupId,
              let enabled = userInfo["enabled"] as? Bool else {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            isBroadcastEnabled = enabled
        }
    }

    // MARK: - Broadcast Header Bar

    private var broadcastHeaderBar: some View {
        HStack(spacing: 12) {
            // Broadcast toggle button with keyboard shortcut
            Button(action: {
                terminalManager.toggleBroadcast(for: groupId)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isBroadcastEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 12, weight: .medium))

                    Text("Broadcast")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isBroadcastEnabled ? GridTokens.accentCyan.opacity(0.2) : Color.clear)
                .foregroundColor(isBroadcastEnabled ? GridTokens.accentCyan : GridTokens.textSecondary)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isBroadcastEnabled ? GridTokens.accentCyan : GridTokens.textSecondary.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("b", modifiers: .command)
            .help("Toggle broadcast mode (⌘B)")

            // Status text
            if isBroadcastEnabled {
                Text("Typing goes to all terminals")
                    .font(.system(size: 11))
                    .foregroundColor(GridTokens.accentCyan)
            }

            Spacer()

            // Keyboard shortcut hint
            Text("⌘B")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(GridTokens.textSecondary.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(GridTokens.backgroundHeader)
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isBroadcastEnabled ? GridTokens.accentCyan.opacity(0.05) : GridTokens.backgroundHeader)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(isBroadcastEnabled ? GridTokens.accentCyan.opacity(0.3) : GridTokens.backgroundPrimary),
            alignment: .bottom
        )
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: GridTokens.accentCyan))
                .scaleEffect(1.5)

            Text("Starting Claude sessions...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(GridTokens.textPrimary)

            Text("\(readySessionCount) of \(repositories.count) ready")
                .font(.system(size: 12))
                .foregroundColor(GridTokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GridTokens.backgroundPrimary.opacity(0.9))
    }

    // MARK: - Session Management

    private func setupSessions() {
        // Check if sessions already exist for this group (user switched tabs and came back)
        let existingSessions = terminalManager.sessions(for: groupId)
        if !existingSessions.isEmpty {
            // Reuse existing sessions - don't create new ones
            sessionIds = existingSessions.map { $0.id }
            if let first = sessionIds.first {
                focusedSessionId = first
            }
            // Mark as ready since sessions already exist
            withAnimation(.easeOut(duration: 0.3)) {
                isInitializing = false
            }
            return
        }

        // Create sessions for each repository (first time setup)
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

        // Longer delay to ensure Claude's TUI is fully ready for input
        // Claude Code needs time to initialize its input field after showing welcome screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print("[MultiTerminalGrid] Sending prompt with Enter: '\(trimmedPrompt)'")
            // Send prompt text followed by carriage return (Enter)
            // Sending together ensures they arrive as a unit
            terminal.send(txt: trimmedPrompt + "\r")
            print("[MultiTerminalGrid] Prompt with Enter sent")
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
