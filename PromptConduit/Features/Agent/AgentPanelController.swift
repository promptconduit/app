import AppKit
import SwiftUI

/// Manages all agent panel windows - each agent gets its own window
class AgentPanelController {
    /// Tracks all open panels by session ID
    private var panels: [UUID: NSPanel] = [:]

    /// Panel for creating new agents (separate from session panels)
    private var newAgentPanel: NSPanel?

    /// Counter for cascading window positions
    private var windowOffset: Int = 0

    init() {}

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
        panel.title = "New Agent"

        let view = NewAgentView { [weak self, weak panel] prompt, directory in
            // Close the new agent form
            panel?.close()

            // Create and show the agent in a new window
            self?.startNewAgent(prompt: prompt, directory: directory)
        }
        panel.contentView = NSHostingView(rootView: view)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        newAgentPanel = panel
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

    // MARK: - Agent Creation

    private func startNewAgent(prompt: String, directory: String) {
        let session = AgentManager.shared.createSession(
            prompt: prompt,
            workingDirectory: directory
        )
        showPanel(for: session)
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
                    onSend: {
                        session.sendPrompt(inputText)
                        inputText = ""
                    }
                )
            }
        }
    }
}

// MARK: - Header View

struct AgentHeaderView: View {
    @ObservedObject var session: AgentSession

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

    private var statusColor: Color {
        switch session.status {
        case .idle: return AgentDesignTokens.textMuted
        case .running: return Color(red: 0.3, green: 0.85, blue: 0.5)
        case .waiting: return Color(red: 0.95, green: 0.75, blue: 0.3)
        case .completed: return AgentDesignTokens.accentCyan
        case .failed: return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }
}
