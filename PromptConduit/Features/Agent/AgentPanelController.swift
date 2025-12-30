import AppKit
import SwiftUI

/// Controls the floating agent panel window
class AgentPanelController {
    private var panel: NSPanel?
    private var session: AgentSession?

    init() {
        setupPanel()
    }

    // MARK: - Panel Setup

    private func setupPanel() {
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

        // Minimum size
        panel.minSize = NSSize(width: 400, height: 300)

        // Position in top-right quadrant
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = panel.frame
            let x = screenFrame.maxX - panelFrame.width - 20
            let y = screenFrame.maxY - panelFrame.height - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }

    // MARK: - Panel Control

    func showPanel(with session: AgentSession? = nil) {
        if let session = session {
            self.session = session
            updateContent()
        } else {
            showNewAgentView()
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    func closePanel() {
        panel?.close()
    }

    // MARK: - Content Management

    private func showNewAgentView() {
        let view = NewAgentView { [weak self] prompt, directory in
            self?.startNewAgent(prompt: prompt, directory: directory)
        }
        panel?.contentView = NSHostingView(rootView: view)
        panel?.title = "New Agent"
    }

    private func updateContent() {
        guard let session = session else { return }

        let view = AgentView(session: session)
        panel?.contentView = NSHostingView(rootView: view)
        panel?.title = "Agent: \(session.repoName)"
    }

    private func startNewAgent(prompt: String, directory: String) {
        session = AgentManager.shared.createSession(
            prompt: prompt,
            workingDirectory: directory
        )
        updateContent()
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

// MARK: - Agent View

struct AgentView: View {
    @ObservedObject var session: AgentSession
    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            AgentHeaderView(session: session)

            Divider()

            // Transcript
            TranscriptView(entries: session.transcript, rawOutput: session.rawOutput)

            Divider()

            // Input
            AgentInputBar(
                text: $inputText,
                isEnabled: session.status == .waiting || session.status == .running,
                onSend: {
                    session.sendPrompt(inputText)
                    inputText = ""
                }
            )
        }
    }
}

// MARK: - Header View

struct AgentHeaderView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortPrompt)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    // Status pill
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(session.status.rawValue)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .cornerRadius(8)

                    Text("•")
                        .foregroundColor(.secondary)
                    Text(session.repoName)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }

            Spacer()

            HStack(spacing: 8) {
                if session.status == .running || session.status == .waiting {
                    Button(action: { session.interrupt() }) {
                        Image(systemName: "stop.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .help("Stop Agent")
                }

                if session.status == .completed || session.status == .failed {
                    Button("Restart") {
                        // TODO: Implement restart
                    }
                    .buttonStyle(.bordered)
                    .disabled(true) // Not implemented yet
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var statusColor: Color {
        switch session.status {
        case .idle: return .gray
        case .running: return .green
        case .waiting: return .yellow
        case .completed: return .blue
        case .failed: return .red
        }
    }
}
