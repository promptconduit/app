import AppKit
import SwiftUI
import SwiftTerm
import ObjectiveC

/// Manages all agent panel windows - each agent gets its own window
class AgentPanelController {
    /// Tracks all open panels by session ID
    private var panels: [UUID: NSPanel] = [:]

    /// Tracks multi-terminal windows by group ID
    private var multiTerminalWindows: [UUID: NSWindow] = [:]

    /// Panel for creating new agents (separate from session panels)
    private var newAgentPanel: NSPanel?

    /// Panel for browsing repositories
    private var repositoriesPanel: NSPanel?

    /// Panel for sessions dashboard
    private var sessionsDashboardPanel: NSPanel?

    /// Counter for cascading window positions
    private var windowOffset: Int = 0

    init() {
        // Listen for focus session notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFocusSessionNotification(_:)),
            name: .focusTerminalSession,
            object: nil
        )
    }

    @objc private func handleFocusSessionNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        // Try to focus a specific group window
        if let groupId = userInfo["groupId"] as? UUID {
            focusMultiTerminalWindow(groupId)
        }

        // Also focus single terminal windows
        if let sessionId = userInfo["sessionId"] as? UUID,
           let panel = panels[sessionId] {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Focus a multi-terminal window by group ID
    func focusMultiTerminalWindow(_ groupId: UUID) {
        if let window = multiTerminalWindows[groupId] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Panel Creation

    /// Creates a new floating panel with standard configuration
    private func createPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "PromptConduit Agent"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 400, height: 300)

        // Position with cascade offset for multiple windows
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = panel.frame
            let cascadeOffset = CGFloat(windowOffset * 30)
            let x = screenFrame.maxX - panelFrame.width - 20 - cascadeOffset
            let y = screenFrame.maxY - panelFrame.height - 20 - cascadeOffset
            panel.setFrameOrigin(NSPoint(x: x, y: y))

            windowOffset = (windowOffset + 1) % 5  // Reset after 5 windows
        }

        return panel
    }

    // MARK: - Panel Control

    /// Shows a new agent creation window
    func showNewAgentPanel() {
        // Always create a fresh panel for new agent form
        let panel = createPanel()
        panel.title = "Start Session"

        // Use new SessionLauncherView
        let view = SessionLauncherView(
            onStartNew: { [weak self, weak panel] prompt, directory in
                // Close the launcher
                panel?.close()
                // Create and show the agent in a new window
                self?.startNewAgent(prompt: prompt, directory: directory)
            },
            onResume: { [weak self, weak panel] sessionHistory in
                // Close the launcher
                panel?.close()
                // Resume the session
                self?.resumeAgent(from: sessionHistory)
            },
            onLaunchTerminal: { [weak self, weak panel] directory, initialPrompt in
                // Close the launcher
                panel?.close()
                // Launch embedded terminal
                self?.launchTerminal(in: directory, initialPrompt: initialPrompt)
            },
            onLaunchMultiTerminal: { [weak self, weak panel] repositories, layout, initialPrompt in
                // Close the launcher
                panel?.close()
                // Launch multi-terminal grid
                self?.launchMultiTerminal(repositories: repositories, layout: layout, initialPrompt: initialPrompt)
            },
            onCancel: { [weak panel] in
                panel?.close()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        // Make the panel slightly larger for the new UI
        panel.setContentSize(NSSize(width: 620, height: 650))

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        newAgentPanel = panel
    }

    /// Shows the repositories browser panel
    func showRepositoriesPanel() {
        // Close existing repos panel if open
        repositoriesPanel?.close()

        let panel = createPanel()
        panel.title = "Repositories"

        let view = RepositoriesView(
            onSelectRepo: { [weak self, weak panel] repo in
                // Close repos panel and open new session launcher with this repo selected
                panel?.close()
                self?.showNewAgentPanelWithRepo(repo)
            },
            onResumeSession: { [weak self, weak panel] sessionHistory in
                // Close repos panel and resume the session
                panel?.close()
                self?.resumeAgent(from: sessionHistory)
            },
            onNewSession: { [weak self, weak panel] repoPath in
                // Close repos panel and open session launcher with this repo
                panel?.close()
                let repo = RecentRepository(path: repoPath)
                self?.showNewAgentPanelWithRepo(repo)
            },
            onAddRepo: { [weak self, weak panel] in
                // Show file picker to add a new repo
                self?.selectAndAddRepository(parentPanel: panel)
            },
            onClose: { [weak panel] in
                panel?.close()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        // Make the panel larger for the repos browser
        panel.setContentSize(NSSize(width: 900, height: 600))

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        repositoriesPanel = panel
    }

    /// Shows the sessions dashboard panel (unified dashboard view)
    func showSessionsDashboardPanel() {
        // Close existing dashboard panel if open
        sessionsDashboardPanel?.close()

        let panel = createPanel()
        panel.title = "PromptConduit Sessions"

        let view = UnifiedDashboardView(
            onResumeSession: { [weak self, weak panel] session in
                // Launch Claude Code with resume
                self?.resumeClaudeCodeSession(session)
            },
            onClose: { [weak panel] in
                panel?.close()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        // Make the panel larger for the unified dashboard layout
        panel.setContentSize(NSSize(width: 1200, height: 800))
        panel.minSize = NSSize(width: 1000, height: 600)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        sessionsDashboardPanel = panel
    }

    /// Navigate to a specific session group in the dashboard
    func navigateToSessionGroup(_ groupId: UUID, highlightSession sessionId: UUID? = nil) {
        showSessionsDashboardPanel()

        // Post notification to navigate to the group
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(
                name: .navigateToSessionGroup,
                object: nil,
                userInfo: [
                    "groupId": groupId,
                    "highlightSessionId": sessionId as Any
                ]
            )
        }
    }

    /// Navigate to a specific terminal session in the dashboard
    func navigateToTerminalSession(_ sessionId: UUID) {
        showSessionsDashboardPanel()

        // Post notification to navigate to the session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(
                name: .navigateToTerminalSession,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
    }

    /// Resume a Claude Code session by launching claude with --resume flag
    private func resumeClaudeCodeSession(_ session: DiscoveredSession) {
        // Launch Claude Code in terminal with --resume and --cwd flags
        launchTerminal(
            in: session.repoPath,
            initialPrompt: nil,
            additionalArguments: ["--resume", session.id]
        )
    }

    /// Shows a new agent creation window with a pre-selected repository
    private func showNewAgentPanelWithRepo(_ repo: RecentRepository) {
        // Add to recent repos
        SettingsService.shared.addRecentRepository(path: repo.path)

        // Show the normal new agent panel - it will auto-select the most recent repo
        showNewAgentPanel()
    }

    /// Opens a file picker to add a new repository
    private func selectAndAddRepository(parentPanel: NSPanel?) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Select a repository folder"

        if SettingsService.shared.directoryExists(SettingsService.shared.defaultProjectsDirectory) {
            openPanel.directoryURL = URL(fileURLWithPath: SettingsService.shared.defaultProjectsDirectory)
        }

        openPanel.beginSheetModal(for: parentPanel ?? NSPanel()) { response in
            if response == .OK, let url = openPanel.url {
                SettingsService.shared.addRecentRepository(path: url.path)
            }
        }
    }

    /// Shows an existing agent session in its own window
    func showPanel(for session: AgentSession) {
        // Check if this session already has a panel
        if let existingPanel = panels[session.id] {
            existingPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create a new panel for this session
        let panel = createPanel()
        panel.title = "Agent: \(session.repoName)"

        let view = AgentView(session: session)
        panel.contentView = NSHostingView(rootView: view)

        // Track this panel
        panels[session.id] = panel

        // Clean up when panel closes
        panel.delegate = PanelCloseDelegate { [weak self] in
            self?.panels.removeValue(forKey: session.id)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Legacy method for backward compatibility - shows new agent panel if no session
    func showPanel(with session: AgentSession? = nil) {
        if let session = session {
            showPanel(for: session)
        } else {
            showNewAgentPanel()
        }
    }

    func hidePanel() {
        newAgentPanel?.orderOut(nil)
    }

    func closePanel() {
        newAgentPanel?.close()
    }

    /// Closes all panels
    func closeAllPanels() {
        for panel in panels.values {
            panel.close()
        }
        panels.removeAll()
        newAgentPanel?.close()
        newAgentPanel = nil
    }

    /// Hides all agent panels without closing them
    func hideAllPanels() {
        for panel in panels.values {
            panel.orderOut(nil)
        }
    }

    /// Shows all agent panels
    func showAllPanels() {
        for panel in panels.values {
            panel.orderFront(nil)
        }
    }

    /// Toggles visibility of all agent panels, returns true if now hidden
    @discardableResult
    func toggleAllPanelsVisibility() -> Bool {
        let shouldHide = !SettingsService.shared.allAgentsHidden
        if shouldHide {
            hideAllPanels()
        } else {
            showAllPanels()
        }
        SettingsService.shared.allAgentsHidden = shouldHide
        return shouldHide
    }

    // MARK: - Agent Creation

    private func startNewAgent(prompt: String, directory: String) {
        let session = AgentManager.shared.createSession(
            prompt: prompt,
            workingDirectory: directory
        )
        showPanel(for: session)
    }

    private func resumeAgent(from history: SessionHistory) {
        let session = AgentManager.shared.resumeSession(from: history)
        showPanel(for: session)
    }

    // MARK: - Terminal Launch

    /// Creates a panel specifically for terminal use (can receive keyboard input)
    /// Uses TerminalPanel to intercept image paste (Cmd+V)
    private func createTerminalPanel() -> TerminalPanel {
        // Terminal panel needs to be able to become key window for keyboard input
        // So we don't use .nonactivatingPanel style
        let panel = TerminalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "Claude Code"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false  // Don't interfere with terminal mouse events
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 600, height: 400)

        // Critical: Allow panel to become key window for keyboard input
        panel.becomesKeyOnlyIfNeeded = false

        // Position with cascade offset for multiple windows
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = panel.frame
            let cascadeOffset = CGFloat(windowOffset * 30)
            let x = screenFrame.maxX - panelFrame.width - 20 - cascadeOffset
            let y = screenFrame.maxY - panelFrame.height - 20 - cascadeOffset
            panel.setFrameOrigin(NSPoint(x: x, y: y))

            windowOffset = (windowOffset + 1) % 5
        }

        return panel
    }

    /// Launches an embedded terminal with Claude Code
    private func launchTerminal(in directory: String, initialPrompt: String? = nil, additionalArguments: [String] = []) {
        let panel = createTerminalPanel()
        let repoName = URL(fileURLWithPath: directory).lastPathComponent
        panel.title = "Claude Code - \(repoName)"

        // Track this panel with a unique ID
        let terminalId = UUID()

        // Register session early with TerminalSessionManager
        TerminalSessionManager.shared.registerSession(
            id: terminalId,
            repoName: repoName,
            workingDirectory: directory
        )

        // Create terminal session view with callbacks
        let view = TerminalSessionView(
            sessionId: terminalId,
            repoName: repoName,
            workingDirectory: directory,
            initialPrompt: initialPrompt,
            additionalArguments: additionalArguments,
            onClose: { [weak panel] in
                // Terminate session and clean up
                TerminalSessionManager.shared.terminateSession(terminalId)
                panel?.close()
            },
            onTerminated: {
                // Process ended naturally - mark as terminated
                TerminalSessionManager.shared.markTerminated(terminalId)
            }
        )
        let hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView

        panels[terminalId] = panel

        // Clean up when panel closes, and handle window events
        let delegate = TerminalPanelDelegate { [weak self] in
            // Terminate session when window closes (handles window close button)
            TerminalSessionManager.shared.terminateSession(terminalId)
            self?.panels.removeValue(forKey: terminalId)
        }
        panel.delegate = delegate

        // Keep a strong reference to delegate (panels dict keeps panel alive)
        objc_setAssociatedObject(panel, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        // Make panel key and activate app
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // After a short delay, ensure the terminal view has focus and store reference
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            // Find the terminal view and make it first responder
            if let terminalView = self.findTerminalView(in: hostingView) {
                panel.makeFirstResponder(terminalView)
                // Store terminal view reference in panel for paste handling
                if let localTerminalView = terminalView as? LocalProcessTerminalView {
                    panel.terminalView = localTerminalView
                    // Also store in session manager for potential termination
                    TerminalSessionManager.shared.updateTerminalView(terminalId, terminalView: localTerminalView)
                }
            }
        }
    }

    /// Recursively finds the LocalProcessTerminalView in the view hierarchy
    private func findTerminalView(in view: NSView) -> NSView? {
        // Check if this view is a terminal view (SwiftTerm's LocalProcessTerminalView)
        let viewType = String(describing: type(of: view))
        if viewType.contains("LocalProcessTerminalView") || viewType.contains("TerminalView") {
            return view
        }

        // Recursively search subviews
        for subview in view.subviews {
            if let found = findTerminalView(in: subview) {
                return found
            }
        }

        return nil
    }

    // MARK: - Multi-Terminal Launch

    /// Launches a multi-terminal grid window with multiple repositories
    private func launchMultiTerminal(repositories: [String], layout: GridLayout, initialPrompt: String?) {
        // Create session group
        let group = TerminalSessionManager.shared.createSessionGroup(
            repositories: repositories,
            layout: layout
        )

        // Calculate window size based on layout
        let windowSize = layout.windowSize(for: repositories.count)

        // Create window (use TerminalWindow for Cmd+C copy, Cmd+V image paste, and Cmd+B broadcast support)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        // Set groupId for broadcast mode support
        window.groupId = group.id

        window.title = "Claude Code - Multi-Session (\(repositories.count) repos)"

        // Use the layout's minimum window size to ensure terminals have enough columns for Claude Code
        let minSize = layout.minimumWindowSize(for: repositories.count)
        window.minSize = NSSize(width: minSize.width, height: minSize.height)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position window centered on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = (screenFrame.width - windowSize.width) / 2 + screenFrame.origin.x
            let y = (screenFrame.height - windowSize.height) / 2 + screenFrame.origin.y
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Store window reference first (before creating delegate that captures group.id)
        let groupId = group.id
        multiTerminalWindows[groupId] = window

        // Set up window delegate for cleanup on close (single source of truth for cleanup)
        let delegate = MultiTerminalWindowDelegate { [weak self] in
            TerminalSessionManager.shared.terminateGroup(groupId)
            self?.multiTerminalWindows.removeValue(forKey: groupId)
        }
        window.delegate = delegate
        objc_setAssociatedObject(window, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        // Create the multi-terminal grid view
        // onClose just closes the window - cleanup is handled by the window delegate
        let gridView = MultiTerminalGridView(
            groupId: groupId,
            repositories: repositories,
            layout: layout,
            initialPrompt: initialPrompt,
            onClose: { [weak window] in
                window?.close()
            }
        )

        window.contentView = NSHostingView(rootView: gridView)

        // Show window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Multi-Terminal Window Delegate

/// Delegate to handle multi-terminal window close events
private class MultiTerminalWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Panel Close Delegate

/// Helper class to handle panel close events
private class PanelCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - New Agent View

struct NewAgentView: View {
    let onStart: (String, String) -> Void

    @ObservedObject private var settings = SettingsService.shared
    @StateObject private var commandsService = SlashCommandsService.shared

    @State private var prompt: String = ""
    @State private var selectedDirectory: String = ""
    @State private var selectedCommand: SlashCommand?
    @State private var showCommandPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Text("New Agent")
                .font(.title)
                .fontWeight(.semibold)

            // Recent Repositories Section
            if !settings.recentRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent Repositories")
                            .font(.headline)
                        Spacer()
                        if settings.recentRepositories.count > 0 {
                            Button("Clear") {
                                settings.clearRecentRepositories()
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(settings.recentRepositories.prefix(8)) { repo in
                                RepoChip(
                                    repo: repo,
                                    isSelected: selectedDirectory == repo.path,
                                    onTap: {
                                        selectedDirectory = repo.path
                                    }
                                )
                            }
                        }
                    }
                }
            }

            // Working Directory
            VStack(alignment: .leading, spacing: 8) {
                Text("Working Directory")
                    .font(.headline)

                HStack {
                    TextField("Directory path...", text: $selectedDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        selectDirectory()
                    }
                }

                // Quick access to default directory
                if !settings.defaultProjectsDirectory.isEmpty && selectedDirectory != settings.defaultProjectsDirectory {
                    HStack {
                        Text("Default:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(shortenPath(settings.defaultProjectsDirectory)) {
                            selectedDirectory = settings.defaultProjectsDirectory
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            // Slash Commands
            if !commandsService.commands.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Slash Command")
                            .font(.headline)
                        Text("(optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(commandsService.commands.prefix(10)) { command in
                                CommandChip(
                                    command: command,
                                    isSelected: selectedCommand?.id == command.id,
                                    onTap: {
                                        if selectedCommand?.id == command.id {
                                            selectedCommand = nil
                                        } else {
                                            selectedCommand = command
                                            if prompt.isEmpty {
                                                prompt = command.prompt
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }

            // Prompt
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prompt")
                        .font(.headline)

                    Spacer()

                    if selectedCommand != nil {
                        Button("Clear") {
                            selectedCommand = nil
                            prompt = ""
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }

                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }

            // Actions
            HStack {
                Spacer()

                Button("Cancel") {
                    NSApp.sendAction(#selector(NSWindow.close), to: nil, from: nil)
                }
                .keyboardShortcut(.escape)

                Button("Start Agent") {
                    // Save to recent repositories
                    settings.addRecentRepository(path: selectedDirectory)
                    onStart(prompt, selectedDirectory)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(prompt.isEmpty || selectedDirectory.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 550, minHeight: 480)
        .onAppear {
            // Set default directory on appear (prefer most recent repo if available)
            if selectedDirectory.isEmpty {
                if let mostRecent = settings.recentRepositories.first {
                    selectedDirectory = mostRecent.path
                } else {
                    selectedDirectory = settings.defaultProjectsDirectory
                }
            }
        }
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        // Start from current selection or default directory
        if settings.directoryExists(selectedDirectory) {
            panel.directoryURL = URL(fileURLWithPath: selectedDirectory)
        } else if settings.directoryExists(settings.defaultProjectsDirectory) {
            panel.directoryURL = URL(fileURLWithPath: settings.defaultProjectsDirectory)
        }

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url.path
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Repo Chip

struct RepoChip: View {
    let repo: RecentRepository
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                Text(repo.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .help(repo.path)
    }
}

// MARK: - Command Chip

struct CommandChip: View {
    let command: SlashCommand
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("/\(command.name)")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .help(command.description ?? command.name)
    }
}

// MARK: - Design Tokens (shared with TranscriptView)

private enum AgentDesignTokens {
    static let backgroundPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let backgroundSecondary = Color(red: 0.12, green: 0.16, blue: 0.24)
    static let backgroundCard = Color(red: 0.15, green: 0.19, blue: 0.27)
    static let accentCyan = Color(red: 0.0, green: 0.83, blue: 0.67)
    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.58, green: 0.63, blue: 0.73)
    static let textMuted = Color(red: 0.4, green: 0.45, blue: 0.55)
}

// MARK: - Agent View

struct AgentView: View {
    @ObservedObject var session: AgentSession
    @State private var inputText: String = ""

    var body: some View {
        ZStack {
            AgentDesignTokens.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                AgentHeaderView(session: session)

                // Transcript
                TranscriptView(entries: session.transcript, rawOutput: session.rawOutput)

                // Input - allow sending when completed too (for continuing conversation)
                AgentInputBar(
                    text: $inputText,
                    isEnabled: session.status == .waiting || session.status == .running || session.status == .completed,
                    isRunning: session.status == .running,
                    queueCount: session.messageQueue.count,
                    onSend: {
                        session.sendPrompt(inputText)
                        inputText = ""
                    },
                    onInterruptAndSend: {
                        session.interruptAndSend(inputText)
                        inputText = ""
                    },
                    onQueue: {
                        session.queueMessage(inputText)
                        inputText = ""
                    },
                    onClearQueue: {
                        session.clearQueue()
                    }
                )
            }
        }
    }
}

// MARK: - Header View

struct AgentHeaderView: View {
    @ObservedObject var session: AgentSession
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.shortPrompt)
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundColor(AgentDesignTokens.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    // Status pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(session.status.rawValue)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text("•")
                        .foregroundColor(AgentDesignTokens.textMuted)

                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                        Text(session.repoName)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(AgentDesignTokens.textSecondary)

                    // GitHub link button
                    if let gitHubURL = session.gitHubURL {
                        Button(action: { NSWorkspace.shared.open(gitHubURL) }) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(AgentDesignTokens.textSecondary)
                        .help("Open on GitHub")
                    }

                    // Open in editor button
                    if settings.preferredCodeEditor != .none {
                        Button(action: { openInEditor() }) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(AgentDesignTokens.textSecondary)
                        .help("Open in \(settings.preferredCodeEditor.displayName)")
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if session.status == .running || session.status == .waiting {
                    Button(action: { session.stop() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.red.opacity(0.8))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop Agent")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AgentDesignTokens.backgroundSecondary)
    }

    private func openInEditor() {
        let directory = session.workingDirectory
        settings.preferredCodeEditor.open(directory: directory)
    }

    private var statusColor: SwiftUI.Color {
        switch session.status {
        case .idle: return AgentDesignTokens.textMuted
        case .running: return SwiftUI.Color(red: 0.3, green: 0.85, blue: 0.5)
        case .waiting: return SwiftUI.Color(red: 0.95, green: 0.75, blue: 0.3)
        case .completed: return AgentDesignTokens.accentCyan
        case .failed: return SwiftUI.Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }
}
